// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

interface ISwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface INonfungiblePositionManager {
    struct MintParams {
        address token0;
        address token1;
        uint24 fee;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
    }

    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    function refundETH() external payable;
}

interface IPolOracle {
    function tokensForEth(address token, uint256 ethAmount) external view returns (uint256);
}

interface IMintEscrow {
    function polTarget() external view returns (address);
    function polOwed() external view returns (uint256);
    function claimRelease() external returns (uint256);
}

/// @title POLManager
/// @notice Protocol-owned liquidity and buy-and-burn for the platform token. LP positions are minted to this
///         contract and can never leave it (no withdraw or collect-to-anyone path). Code only: not deployed by this job.
contract POLManager is ReentrancyGuard, IERC721Receiver {
    using SafeERC20 for IERC20;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 public constant MAX_SLIPPAGE_BPS = 300;
    uint256 public constant MAX_CHUNK = 1 ether;

    address public immutable weth;
    address public immutable token;
    uint24 public immutable fee;
    int24 public immutable tickSpacing;
    ISwapRouter02 public immutable router;
    INonfungiblePositionManager public immutable positions;
    IPolOracle public immutable oracle;
    IMintEscrow public immutable mintEscrow;

    uint256 public polBudget;
    uint256 public burnBudget;
    uint256 public tokensBurned;
    uint256 public positionsMinted;

    event Received(string bucket, uint256 amount);
    event Burned(uint256 ethIn, uint256 tokensOut);
    event LiquidityAdded(uint256 indexed positionId, uint128 liquidity, uint256 ethUsed);

    error ZeroAmount();
    error BadConfig();
    error TooLarge();
    error NothingOwed();
    error UnexpectedSender();

    constructor(
        address weth_,
        address token_,
        uint24 fee_,
        int24 tickSpacing_,
        address router_,
        address positions_,
        address oracle_,
        address mintEscrow_
    ) {
        if (
            weth_ == address(0) || token_ == address(0) || weth_ == token_ || router_ == address(0)
                || positions_ == address(0) || oracle_ == address(0) || mintEscrow_ == address(0) || fee_ == 0
                || tickSpacing_ <= 0 || tickSpacing_ > 887272
        ) revert BadConfig();
        weth = weth_;
        token = token_;
        fee = fee_;
        tickSpacing = tickSpacing_;
        router = ISwapRouter02(router_);
        positions = INonfungiblePositionManager(positions_);
        oracle = IPolOracle(oracle_);
        mintEscrow = IMintEscrow(mintEscrow_);
    }

    receive() external payable {
        if (msg.sender != address(mintEscrow) && msg.sender != address(positions)) revert UnexpectedSender();
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
        return (oracle.tokensForEth(token, ethIn) * (10_000 - MAX_SLIPPAGE_BPS)) / 10_000;
    }

    /// @notice Permissionless: spends up to 1 ETH of the burn budget buying the token to the dead address, with a
    ///         minimum output 3% under the TWAP quote.
    function buyAndBurn(uint256 ethIn) external nonReentrant returns (uint256 out) {
        if (ethIn < 1) revert ZeroAmount();
        if (ethIn > burnBudget || ethIn > MAX_CHUNK) revert TooLarge();
        burnBudget -= ethIn;
        uint256 minOut = _minOut(ethIn);
        out = router.exactInputSingle{value: ethIn}(
            ISwapRouter02.ExactInputSingleParams(weth, token, fee, DEAD, ethIn, minOut, 0)
        );
        tokensBurned += out;
        emit Burned(ethIn, out);
    }

    /// @notice Permissionless: swaps half of `ethIn` to the token and adds a full-range position held forever.
    ///         Unused leftovers stay in this contract as WETH/token for the next call.
    function addLiquidity(uint256 ethIn) external nonReentrant returns (uint256 positionId) {
        if (ethIn < 2) revert ZeroAmount();
        if (ethIn > polBudget || ethIn > 2 * MAX_CHUNK) revert TooLarge();
        polBudget -= ethIn;
        uint256 half = ethIn / 2;
        uint256 rest = ethIn - half;
        uint256 minOut = _minOut(half);
        uint256 bought = router.exactInputSingle{value: half}(
            ISwapRouter02.ExactInputSingleParams(weth, token, fee, address(this), half, minOut, 0)
        );

        int24 maxTick = 887272 - (887272 % tickSpacing);
        bool wethFirst = weth < token;
        IERC20(token).forceApprove(address(positions), bought);
        INonfungiblePositionManager.MintParams memory p = INonfungiblePositionManager.MintParams({
            token0: wethFirst ? weth : token,
            token1: wethFirst ? token : weth,
            fee: fee,
            tickLower: -maxTick,
            tickUpper: maxTick,
            amount0Desired: wethFirst ? rest : bought,
            amount1Desired: wethFirst ? bought : rest,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp
        });
        // the position manager wraps the ETH it needs; unused ETH comes back through refundETH()
        positionsMinted += 1;
        (uint256 id, uint128 liquidity, uint256 used0, uint256 used1) = positions.mint{value: rest}(p);
        emit LiquidityAdded(id, liquidity, wethFirst ? used0 : used1);
        positionId = id;
        positions.refundETH();
    }

    /// @notice Returns ETH refunded by the position manager to the POL budget. Everything above the burn budget
    ///         is POL money, so this cannot move funds between buckets in anyone's favour.
    function recycle() external nonReentrant {
        polBudget = address(this).balance - burnBudget;
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
