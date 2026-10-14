// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TickMath} from "./TickMath.sol";
import {
    PoolKey,
    SwapParams,
    ModifyLiquidityParams,
    IPoolManagerMinimal,
    IUnlockCallbackMinimal,
    V4Lib
} from "./v4/V4Minimal.sol";

interface IPolOracle {
    function tokensForEth(address token, uint256 ethAmount) external view returns (uint256);
}

interface IMintEscrow {
    function polTarget() external view returns (address);
    function polOwed() external view returns (uint256);
    function claimRelease() external returns (uint256);
}

/// @title POLManager
/// @notice Protocol-owned liquidity and buy-and-burn for GOLD through the Uniswap v4 PoolManager on the GOLD/ETH
///         pool with GoldHook. Full-range positions are owned by this contract inside the PoolManager and there is no
///         function that removes them: they are held forever. No router, no position manager, no owner.
contract POLManager is ReentrancyGuard, IUnlockCallbackMinimal {
    using SafeERC20 for IERC20;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint24 public constant POOL_FEE = 12500;
    int24 public constant TICK_SPACING = 60;
    int24 public constant TICK_LOWER = -887220; // min usable tick for spacing 60
    int24 public constant TICK_UPPER = 887220;
    /// @dev Allowed shortfall against the TWAP quote after the 1.25% LP fee (125 bps) and 1% hook fee (100 bps): 3% of
    ///      price impact. 9475 bps.
    uint256 public constant MIN_OUT_BPS = 10_000 - 125 - 100 - 300;
    uint256 public constant MAX_CHUNK = 1 ether;
    uint256 private constant Q96 = 1 << 96;

    IPoolManagerMinimal public immutable poolManager;
    address public immutable token;
    address public immutable hook;
    IPolOracle public immutable oracle;
    IMintEscrow public immutable mintEscrow;

    uint256 public polBudget;
    uint256 public burnBudget;
    uint256 public tokensBurned;
    uint256 public liquidityAdded;
    uint256 public positionsMinted;

    enum Action {
        None,
        Burn,
        Liquidity
    }

    Action private _action;

    event Received(string bucket, uint256 amount);
    event Burned(uint256 ethIn, uint256 tokensOut);
    event LiquidityAdded(uint128 liquidity, uint256 ethUsed, uint256 tokensUsed);
    /// @notice LP fees the position had earned that came back as a positive delta while adding: the ETH is recycled
    ///         into the POL budget, the GOLD stays here for the next add.
    event FeesCollected(uint256 eth, uint256 tokens);

    error ZeroAmount();
    error BadConfig();
    error TooLarge();
    error NothingOwed();
    error UnexpectedSender();
    error NotInCallback();
    error Slippage();

    constructor(address poolManager_, address token_, address hook_, address oracle_, address mintEscrow_) {
        if (
            poolManager_ == address(0) || token_ == address(0) || hook_ == address(0) || oracle_ == address(0)
                || mintEscrow_ == address(0)
        ) revert BadConfig();
        poolManager = IPoolManagerMinimal(poolManager_);
        token = token_;
        hook = hook_;
        oracle = IPolOracle(oracle_);
        mintEscrow = IMintEscrow(mintEscrow_);
    }

    receive() external payable {
        if (msg.sender != address(mintEscrow) && msg.sender != address(poolManager)) revert UnexpectedSender();
    }

    function poolKey() public view returns (PoolKey memory) {
        return PoolKey(address(0), token, POOL_FEE, TICK_SPACING, hook);
    }

    function depositPOL() external payable {
        polBudget += msg.value;
        emit Received("pol", msg.value);
    }

    function depositBurn() external payable {
        burnBudget += msg.value;
        emit Received("burn", msg.value);
    }

    /// @notice Pull the 50% POL share of the released GoblinNFT escrow.
    function pullMintEscrow() external nonReentrant {
        uint256 owed = mintEscrow.polTarget() == address(this) ? mintEscrow.polOwed() : 0;
        if (owed < 1) revert NothingOwed();
        polBudget += owed;
        emit Received("mint", owed);
        uint256 got = mintEscrow.claimRelease();
        if (got != owed) revert UnexpectedSender();
    }

    function _minOut(uint256 ethIn) internal view returns (uint256) {
        return (oracle.tokensForEth(token, ethIn) * MIN_OUT_BPS) / 10_000;
    }

    /// @notice Permissionless: spends up to 1 ETH of the burn budget buying GOLD to the dead address, requiring at
    ///         least the TWAP quote net of fees and 3%.
    function buyAndBurn(uint256 ethIn) external nonReentrant returns (uint256 out) {
        if (ethIn < 1) revert ZeroAmount();
        if (ethIn > burnBudget || ethIn > MAX_CHUNK) revert TooLarge();
        burnBudget -= ethIn;
        _action = Action.Burn;
        bytes memory result = poolManager.unlock(abi.encode(ethIn, _minOut(ethIn)));
        _action = Action.None;
        out = abi.decode(result, (uint256));
        tokensBurned += out;
        emit Burned(ethIn, out);
    }

    /// @notice Permissionless: swaps half of `ethIn` to GOLD and adds the pair as full-range liquidity owned by this
    ///         contract forever. Leftover ETH is recycled into the POL budget; leftover GOLD joins the next call.
    function addLiquidity(uint256 ethIn) external nonReentrant returns (uint128 liquidity) {
        if (ethIn < 2) revert ZeroAmount();
        if (ethIn > polBudget || ethIn > 2 * MAX_CHUNK) revert TooLarge();
        polBudget -= ethIn;
        uint256 half = ethIn / 2;
        _action = Action.Liquidity;
        bytes memory result = poolManager.unlock(abi.encode(half, _minOut(half), ethIn - half));
        _action = Action.None;
        uint256 ethUsed;
        uint256 tokensUsed;
        uint256 ethFees;
        uint256 tokenFees;
        (liquidity, ethUsed, tokensUsed, ethFees, tokenFees) =
            abi.decode(result, (uint128, uint256, uint256, uint256, uint256));
        positionsMinted += 1;
        liquidityAdded += liquidity;
        if (ethFees > 0) polBudget += ethFees; // taken ETH is POL money: recycled at once
        if (ethFees > 0 || tokenFees > 0) emit FeesCollected(ethFees, tokenFees);
        emit LiquidityAdded(liquidity, ethUsed, tokensUsed);
    }

    /// @notice Returns ETH left over by liquidity adds to the POL budget. Everything above the burn budget is POL money,
    ///         so this cannot move funds between buckets in anyone's favour.
    function recycle() external nonReentrant {
        polBudget = address(this).balance - burnBudget;
    }

    // ---------------------------------------------------------------- PoolManager callback

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert UnexpectedSender();
        if (_action == Action.Burn) {
            (uint256 ethIn, uint256 minOut) = abi.decode(data, (uint256, uint256));
            uint256 out = _buy(ethIn, minOut, DEAD);
            return abi.encode(out);
        }
        if (_action == Action.Liquidity) {
            (uint256 half, uint256 minOut, uint256 rest) = abi.decode(data, (uint256, uint256, uint256));
            _buy(half, minOut, address(this));
            return _addFullRange(rest, IERC20(token).balanceOf(address(this)));
        }
        revert NotInCallback();
    }

    /// @dev Exact-input ETH -> GOLD swap; the hook's fee is charged on the ETH input inside the PoolManager. The price
    ///      limit is the extreme one: the hook reverts `PartialFill` on a limit-bounded swap, and `minOut` bounds the
    ///      price instead.
    function _buy(uint256 ethIn, uint256 minOut, address to) internal returns (uint256 out) {
        int256 delta = poolManager.swap(poolKey(), SwapParams(true, -int256(ethIn), V4Lib.MIN_SQRT_PRICE + 1), "");
        int128 a0 = V4Lib.amount0(delta);
        int128 a1 = V4Lib.amount1(delta);
        if (a0 >= 0 || a1 <= 0) revert Slippage();
        out = uint256(uint128(a1));
        if (out < minOut) revert Slippage();
        poolManager.settle{value: uint256(uint128(-a0))}();
        poolManager.take(token, to, out);
    }

    function _addFullRange(uint256 ethAvailable, uint256 tokensAvailable) internal returns (bytes memory) {
        (uint160 sqrtPrice,) = V4Lib.slot0(poolManager, V4Lib.poolId(poolKey()));
        uint128 liquidity = _liquidityFor(sqrtPrice, ethAvailable, tokensAvailable);
        if (liquidity == 0) revert ZeroAmount();
        (int256 delta,) = poolManager.modifyLiquidity(
            poolKey(), ModifyLiquidityParams(TICK_LOWER, TICK_UPPER, int256(uint256(liquidity)), bytes32(0)), ""
        );
        // The caller delta nets the position's accrued LP fees against the principal: either side can come back
        // positive once the position has earned more than the add needs. Every delta is settled or taken here so
        // the callback always leaves both currencies at zero (finding 2: a positive delta used to brick every add).
        int128 a0 = V4Lib.amount0(delta);
        int128 a1 = V4Lib.amount1(delta);
        uint256 ethUsed = a0 < 0 ? uint256(uint128(-a0)) : 0;
        uint256 tokensUsed = a1 < 0 ? uint256(uint128(-a1)) : 0;
        uint256 ethFees = a0 > 0 ? uint256(uint128(a0)) : 0;
        uint256 tokenFees = a1 > 0 ? uint256(uint128(a1)) : 0;
        if (ethUsed > ethAvailable || tokensUsed > tokensAvailable) revert Slippage();
        if (ethUsed > 0) poolManager.settle{value: ethUsed}();
        if (tokensUsed > 0) {
            poolManager.sync(token);
            IERC20(token).safeTransfer(address(poolManager), tokensUsed);
            poolManager.settle();
        }
        if (ethFees > 0) poolManager.take(address(0), address(this), ethFees);
        if (tokenFees > 0) poolManager.take(token, address(this), tokenFees);
        return abi.encode(liquidity, ethUsed, tokensUsed, ethFees, tokenFees);
    }

    /// @dev Full-range `getLiquidityForAmounts`: the smaller of the liquidity each side can back at the current price.
    function _liquidityFor(uint160 sqrtPrice, uint256 amount0, uint256 amount1) internal pure returns (uint128) {
        uint160 sqrtA = TickMath.sqrtPriceAtTick(TICK_LOWER);
        uint160 sqrtB = TickMath.sqrtPriceAtTick(TICK_UPPER);
        if (sqrtPrice <= sqrtA) sqrtPrice = sqrtA + 1;
        if (sqrtPrice >= sqrtB) sqrtPrice = sqrtB - 1;
        uint256 intermediate = Math.mulDiv(sqrtPrice, sqrtB, Q96);
        uint256 l0 = Math.mulDiv(amount0, intermediate, sqrtB - sqrtPrice);
        uint256 l1 = Math.mulDiv(amount1, Q96, sqrtPrice - sqrtA);
        uint256 l = Math.min(l0, l1);
        return l > type(uint128).max ? type(uint128).max : uint128(l);
    }
}
