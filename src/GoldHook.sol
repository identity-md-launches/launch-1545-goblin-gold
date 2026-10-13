// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PoolKey, SwapParams, IPoolManagerMinimal, IUnlockCallbackMinimal, V4Lib} from "./v4/V4Minimal.sol";

interface IHookNFT {
    function depositRevenue() external payable;
}

interface IHookGacha {
    function nft() external view returns (address);
    function genesis() external view returns (address);
    function fundReserve() external payable;
}

interface IHookGenesisVault {
    function token() external view returns (address);
}

/// @title GoldHook
/// @notice Uniswap v4 hook of the GOLD/ETH genesis pool. No owner. It (1) records a v3-style tick-cumulative
///         observation ring so `TwapOracle` can price GOLD, (2) accepts initialization only from the launch factory
///         and only for the platform pool (ETH / GOLD, fee 12500, spacing 60), (3) takes a 1% hook fee in ETH on
///         every swap, half for GoblinNFT holders and half for the BagGacha reward reserve, (4) taxes buys during the
///         first 30 minutes after launch (90% / 50% / 25%, all to the reserve share) and caps buys at 0.5 ETH in the
///         first hour. Inside the swap path the hook only accounts: the fee ETH is minted as ERC6909 claims to the hook
///         inside the PoolManager and is flushed in batches by anyone through `flush()`.
/// @dev The reserve share accrues until the one-time permissionless `bindGacha`, which accepts only a contract whose
///      runtime code hash is `GACHA_RUNTIME_CODE_HASH` (the imported-launch build of `BagGacha`, which has no
///      immutables) and whose NFT and genesis token match. Any GOLD the hook holds (launch remainder) is forwarded to
///      that gacha's GenesisVault at binding.
contract GoldHook is ReentrancyGuard, IUnlockCallbackMinimal {
    using SafeERC20 for IERC20;

    struct Observation {
        uint32 blockTimestamp;
        int56 tickCumulative;
        bool initialized;
    }

    // ---------------------------------------------------------------- fixed parameters
    address public constant NFT = 0xC5d5F314da6d4a433F9BF897a2cC24A537576cB1;
    uint24 public constant POOL_FEE = 12500;
    int24 public constant TICK_SPACING = 60;
    uint256 public constant HOOK_FEE_BPS = 100;
    uint256 public constant MAX_EARLY_BUY = 0.5 ether;
    uint256 public constant EARLY_WINDOW = 1 hours;
    uint16 public constant MAX_CARDINALITY = 4096;
    uint256 private constant BPS = 10_000;
    /// @dev beforeInitialize | afterInitialize | beforeSwap | afterSwap | beforeSwapReturnsDelta | afterSwapReturnsDelta
    uint160 public constant REQUIRED_FLAGS = (1 << 13) | (1 << 12) | (1 << 7) | (1 << 6) | (1 << 3) | (1 << 2);
    uint160 public constant ALL_FLAGS_MASK = (1 << 14) - 1;
    /// @notice keccak256 of the runtime code of `BagGacha` built with the imported-launch profile (solc 0.8.26,
    ///         optimizer 200 runs, via_ir = false, bytecode_hash = none). Regenerate with `forge test --match-test
    ///         testPinnedGachaRuntimeCodeHash -vv` under that profile whenever BagGacha changes.
    bytes32 public constant GACHA_RUNTIME_CODE_HASH =
        0x070f51e4de5f4c7edad282993b737908a0f2764a64f28a60cd9b454a056fafdc;

    // ---------------------------------------------------------------- wiring
    IPoolManagerMinimal public immutable poolManager;
    address public immutable token;
    address public immutable factory;

    bytes32 public poolId;
    uint64 public launchedAt;
    bool public initialized;
    address public gacha;

    /// @notice ETH owed to GoblinNFT holders / to the gacha reserve, held as currency-0 ERC6909 claims in the PoolManager.
    uint256 public holderAccrued;
    uint256 public reserveAccrued;
    uint256 public totalFlushedToHolders;
    uint256 public totalFlushedToReserve;

    // ---------------------------------------------------------------- observation ring
    mapping(uint256 => Observation) public observations;
    uint16 public observationIndex;
    uint16 public observationCardinality;

    bool private _flushing;

    event PoolInitialized(bytes32 indexed poolId, int24 tick, uint256 launchedAt);
    event HookFeeAccrued(uint256 fee, uint256 tax, bool buy);
    event GachaBound(address indexed gacha, address indexed vault, uint256 tokensForwarded);
    event Flushed(uint256 toHolders, uint256 toReserve);
    event ObservationWritten(uint16 index, uint32 blockTimestamp, int24 tick);

    error OnlyPoolManager();
    error OnlyFactory();
    error WrongPool();
    error AlreadyInitialized();
    error NotInitialized();
    error BadConfig();
    error BuyTooLarge(uint256 ethIn, uint256 max);
    error AlreadyBound();
    error CodeMismatch();
    error GachaMismatch();
    error NothingToFlush();
    error OldObservation();
    error NotFlushing();
    error UnexpectedSender();
    error AmountTooLarge();

    constructor(address poolManager_, address token_, address factory_) {
        if (poolManager_ == address(0) || token_ == address(0) || factory_ == address(0)) revert BadConfig();
        poolManager = IPoolManagerMinimal(poolManager_);
        token = token_;
        factory = factory_;
    }

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();
        _;
    }

    receive() external payable {
        if (msg.sender != address(poolManager)) revert UnexpectedSender();
    }

    // ================================================================ views

    /// @notice True when this contract's address carries exactly the hook-permission bits it needs.
    function hasRequiredFlags() external view returns (bool) {
        return (uint160(address(this)) & ALL_FLAGS_MASK) == REQUIRED_FLAGS;
    }

    function poolKey() public view returns (PoolKey memory) {
        return PoolKey(address(0), token, POOL_FEE, TICK_SPACING, address(this));
    }

    /// @notice Current pool price and tick, read from the PoolManager.
    function slot0() public view returns (uint160 sqrtPriceX96, int24 tick) {
        if (!initialized) revert NotInitialized();
        return V4Lib.slot0(poolManager, poolId);
    }

    function liquidity() external view returns (uint128) {
        if (!initialized) revert NotInitialized();
        return V4Lib.liquidity(poolManager, poolId);
    }

    function lastObservationTimestamp() external view returns (uint32) {
        return observations[observationIndex].blockTimestamp;
    }

    /// @notice Buy tax in basis points for the current time since launch.
    function buyTaxBps() public view returns (uint256) {
        if (!initialized) return 0;
        uint256 elapsed = block.timestamp - launchedAt;
        if (elapsed < 10 minutes) return 9000;
        if (elapsed < 20 minutes) return 5000;
        if (elapsed < 30 minutes) return 2500;
        return 0;
    }

    /// @notice The hash a candidate gacha's runtime code must match. Virtual only so tests can harness it.
    function gachaRuntimeCodeHash() public view virtual returns (bytes32) {
        return GACHA_RUNTIME_CODE_HASH;
    }

    // ================================================================ hook callbacks (PoolManager only)

    function beforeInitialize(address sender, PoolKey calldata key, uint160)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        if (sender != factory) revert OnlyFactory();
        if (initialized) revert AlreadyInitialized();
        if (
            key.currency0 != address(0) || key.currency1 != token || key.fee != POOL_FEE
                || key.tickSpacing != TICK_SPACING || key.hooks != address(this)
        ) revert WrongPool();
        return this.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24 tick)
        external
        onlyPoolManager
        returns (bytes4)
    {
        if (initialized) revert AlreadyInitialized();
        initialized = true;
        poolId = V4Lib.poolId(key);
        launchedAt = uint64(block.timestamp);
        observations[0] = Observation(uint32(block.timestamp), 0, true);
        observationCardinality = 1;
        emit PoolInitialized(poolId, tick, block.timestamp);
        return this.afterInitialize.selector;
    }

    /// @dev Writes the pre-swap observation and, when ETH is the specified currency, charges the fee/tax on it.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int256, uint24)
    {
        _checkKey(key);
        (, int24 tick) = V4Lib.slot0(poolManager, poolId);
        _write(tick);
        int256 delta;
        if (_specifiedIsEth(params)) {
            (uint256 fee, uint256 tax) = _specifiedCharge(params);
            delta = V4Lib.beforeSwapDelta(_toInt128(fee + tax), 0);
        }
        return (this.beforeSwap.selector, delta, 0);
    }

    /// @dev Charges on the unspecified side when that is ETH, then mints the whole charge as claims to this hook.
    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, int256 swapDelta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        _checkKey(key);
        uint256 fee;
        uint256 tax;
        int128 unspecified;
        if (_specifiedIsEth(params)) {
            (fee, tax) = _specifiedCharge(params);
        } else {
            int128 a0 = V4Lib.amount0(swapDelta);
            if (params.zeroForOne) {
                // exact-output buy: the pool consumed `ethIn`; the swapper pays fee and tax on top
                uint256 ethIn = uint256(uint128(-a0));
                fee = (ethIn * HOOK_FEE_BPS) / BPS;
                uint256 taxBps = buyTaxBps();
                tax = taxBps == 0 ? 0 : (ethIn * taxBps) / (BPS - taxBps);
                _checkBuyCap(ethIn + fee + tax);
            } else {
                // exact-input sell: the swapper receives `ethOut` minus the fee
                fee = (uint256(uint128(a0)) * HOOK_FEE_BPS) / BPS;
            }
            unspecified = _toInt128(fee + tax);
        }
        uint256 total = fee + tax;
        if (total > 0) {
            uint256 holders = fee / 2;
            holderAccrued += holders;
            reserveAccrued += total - holders;
            poolManager.mint(address(this), 0, total);
            emit HookFeeAccrued(fee, tax, params.zeroForOne);
        }
        return (this.afterSwap.selector, unspecified);
    }

    // ================================================================ binding and flushing

    /// @notice One-time, permissionless. Accepts only a BagGacha built from the pinned code whose NFT is GoblinNFT and
    ///         whose GenesisVault token is this pool's token. Forwards any GOLD this hook holds to that vault.
    function bindGacha(address gacha_) external nonReentrant {
        if (gacha != address(0)) revert AlreadyBound();
        if (gacha_.codehash != gachaRuntimeCodeHash()) revert CodeMismatch();
        if (IHookGacha(gacha_).nft() != NFT) revert GachaMismatch();
        address vault = IHookGacha(gacha_).genesis();
        if (vault == address(0) || IHookGenesisVault(vault).token() != token) revert GachaMismatch();
        gacha = gacha_;
        uint256 held = IERC20(token).balanceOf(address(this));
        emit GachaBound(gacha_, vault, held);
        if (held > 0) IERC20(token).safeTransfer(vault, held);
    }

    /// @notice Permissionless batch flush: pulls the accrued ETH claims out of the PoolManager, pays GoblinNFT holders
    ///         through `depositRevenue()` and, once bound, the gacha reserve through `fundReserve()`.
    function flush() external nonReentrant {
        uint256 holders = holderAccrued;
        uint256 reserveShare = gacha == address(0) ? 0 : reserveAccrued;
        uint256 total = holders + reserveShare;
        if (total == 0) revert NothingToFlush();
        holderAccrued = 0;
        reserveAccrued -= reserveShare;
        totalFlushedToHolders += holders;
        totalFlushedToReserve += reserveShare;
        _flushing = true;
        poolManager.unlock(abi.encode(total));
        _flushing = false;
        emit Flushed(holders, reserveShare);
        if (holders > 0) IHookNFT(NFT).depositRevenue{value: holders}();
        if (reserveShare > 0) IHookGacha(gacha).fundReserve{value: reserveShare}();
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        if (!_flushing) revert NotFlushing();
        uint256 amount = abi.decode(data, (uint256));
        poolManager.burn(address(this), 0, amount);
        poolManager.take(address(0), address(this), amount);
        return "";
    }

    // ================================================================ observations (Uniswap v3 semantics)

    /// @notice Cumulative tick at each `secondsAgo` (0 = now), as Uniswap v3 `observe`.
    function observe(uint32[] calldata secondsAgos) external view returns (int56[] memory tickCumulatives) {
        if (!initialized) revert NotInitialized();
        (, int24 tick) = V4Lib.slot0(poolManager, poolId);
        tickCumulatives = new int56[](secondsAgos.length);
        for (uint256 i = 0; i < secondsAgos.length; ++i) {
            tickCumulatives[i] = _observeSingle(uint32(block.timestamp), secondsAgos[i], tick);
        }
    }

    function _write(int24 tick) internal {
        uint16 index = observationIndex;
        Observation memory last = observations[index];
        uint32 now32 = uint32(block.timestamp);
        if (last.blockTimestamp == now32) return;
        uint16 cardinality = observationCardinality;
        uint16 next = cardinality < MAX_CARDINALITY ? cardinality : (index + 1) % MAX_CARDINALITY;
        if (cardinality < MAX_CARDINALITY) observationCardinality = cardinality + 1;
        observations[next] = _transform(last, now32, tick);
        observationIndex = next;
        emit ObservationWritten(next, now32, tick);
    }

    function _transform(Observation memory last, uint32 blockTimestamp, int24 tick)
        internal
        pure
        returns (Observation memory)
    {
        uint32 delta = blockTimestamp - last.blockTimestamp;
        return Observation(blockTimestamp, last.tickCumulative + int56(tick) * int56(uint56(delta)), true);
    }

    function _observeSingle(uint32 time, uint32 secondsAgo, int24 tick) internal view returns (int56) {
        Observation memory last = observations[observationIndex];
        if (secondsAgo == 0) {
            if (last.blockTimestamp != time) last = _transform(last, time, tick);
            return last.tickCumulative;
        }
        uint32 target = time - secondsAgo;
        if (last.blockTimestamp <= target) return _transform(last, target, tick).tickCumulative;
        (Observation memory beforeOrAt, Observation memory atOrAfter) = _surroundings(target);
        if (target == beforeOrAt.blockTimestamp) return beforeOrAt.tickCumulative;
        if (target == atOrAfter.blockTimestamp) return atOrAfter.tickCumulative;
        uint32 span = atOrAfter.blockTimestamp - beforeOrAt.blockTimestamp;
        uint32 targetDelta = target - beforeOrAt.blockTimestamp;
        return beforeOrAt.tickCumulative
            + ((atOrAfter.tickCumulative - beforeOrAt.tickCumulative) / int56(uint56(span)))
            * int56(uint56(targetDelta));
    }

    /// @dev Binary search over the ring, exactly as Uniswap v3 `Oracle.binarySearch`.
    function _surroundings(uint32 target)
        internal
        view
        returns (Observation memory beforeOrAt, Observation memory atOrAfter)
    {
        uint256 cardinality = observationCardinality;
        uint256 l = (uint256(observationIndex) + 1) % cardinality;
        uint256 r = l + cardinality - 1;
        beforeOrAt = observations[l];
        if (beforeOrAt.blockTimestamp > target) revert OldObservation();
        uint256 i;
        while (true) {
            i = (l + r) / 2;
            beforeOrAt = observations[i % cardinality];
            if (!beforeOrAt.initialized) {
                l = i + 1;
                continue;
            }
            atOrAfter = observations[(i + 1) % cardinality];
            bool targetAtOrAfter = beforeOrAt.blockTimestamp <= target;
            if (targetAtOrAfter && target <= atOrAfter.blockTimestamp) break;
            if (!targetAtOrAfter) r = i - 1;
            else l = i + 1;
        }
    }

    // ================================================================ internals

    function _checkKey(PoolKey calldata key) internal view {
        if (!initialized || V4Lib.poolId(key) != poolId) revert WrongPool();
    }

    /// @dev ETH (currency0) is the specified currency for exact-input buys and exact-output sells.
    function _specifiedIsEth(SwapParams calldata params) internal pure returns (bool) {
        return params.zeroForOne == (params.amountSpecified < 0);
    }

    function _specifiedCharge(SwapParams calldata params) internal view returns (uint256 fee, uint256 tax) {
        uint256 amount = params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        fee = (amount * HOOK_FEE_BPS) / BPS;
        if (params.zeroForOne) {
            tax = (amount * buyTaxBps()) / BPS;
            _checkBuyCap(amount);
        }
    }

    function _checkBuyCap(uint256 ethIn) internal view {
        if (block.timestamp < launchedAt + EARLY_WINDOW && ethIn > MAX_EARLY_BUY) {
            revert BuyTooLarge(ethIn, MAX_EARLY_BUY);
        }
    }

    function _toInt128(uint256 x) internal pure returns (int128) {
        if (x > uint256(uint128(type(int128).max))) revert AmountTooLarge();
        return int128(uint128(x));
    }
}
