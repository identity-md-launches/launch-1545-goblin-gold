// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "./TickMath.sol";
import {V3Depth} from "./v3/V3Depth.sol";

/// @dev Only the leading return values that are used are declared; the ABI decoder ignores the rest.
interface IUniswapV3PoolOracle {
    function fee() external view returns (uint24);
    function liquidity() external view returns (uint128);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16 observationIndex);
    function observations(uint256 index) external view returns (uint32 blockTimestamp);
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128);
}

interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

/// @dev The GoldHook observation ring and pool state reads (Uniswap v4 genesis pool, ETH is currency0).
interface IGoldHookOracle {
    function initialized() external view returns (bool);
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick);
    function liquidity() external view returns (uint128);
    function liquidityAt(uint32 secondsAgo) external view returns (uint128);
    function lastObservationTimestamp() external view returns (uint32);
    function observe(uint32[] calldata secondsAgos) external view returns (int56[] memory tickCumulatives);
}

/// @title TwapOracle
/// @notice Conservative ETH marks for listed tokens: min(30-minute TWAP, 4-hour TWAP) from one Uniswap v3
///         token/WETH pool per token, rejected when conservative depth is under 5 ETH on either side or its
///         latest observation is older than one hour. WETH is valued 1:1. The genesis token (GOLD) is priced only
///         from the GoldHook observation ring of its Uniswap v4 ETH pool, with the same windows and staleness and a
///         1 ETH minimum ETH-side depth computed from the v4 pool's active liquidity; it can never be given a v3 pool.
///         Because such pools are thin, every quote also carries a payout cap: `valueAndCap` returns, beside the TWAP
///         value, 5% of the pool's conservative ETH-side depth, the most a single draw may pay out of that token.
///         Genesis uses full-range liquidity bounded by the hook's 30-minute and 4-hour records, valued at the
///         larger of spot and long-window sqrt prices. Regular pools use min(current, 30-minute harmonic L) and
///         liquidity released in a fixed sqrt-price band, stopping at the nearest initialized tick. No raw pool
///         balance counts. Genesis quotes use the smaller token amount of the two windows; POL floors use the larger.
contract TwapOracle {
    uint32 public constant SHORT_WINDOW = 30 minutes;
    uint32 public constant LONG_WINDOW = 4 hours;
    uint256 public constant MAX_STALENESS = 1 hours;
    /// @notice Regular Uniswap v3 token/WETH pools: each side of the active liquidity must be worth at least this.
    uint256 public constant MIN_LIQUIDITY = 5 ether;
    /// @notice Genesis (GOLD/ETH v4) pool: the ETH virtual reserve of the active liquidity must be at least this.
    uint256 public constant MIN_GENESIS_DEPTH = 1 ether;
    /// @notice A single draw payout of a token, valued at the TWAP, is capped at this share of its pool's ETH-side depth.
    uint256 public constant PAYOUT_CAP_BPS = 500;
    /// @notice Last usable tick of the genesis pool (spacing 60): the ETH the active liquidity holds is counted only
    ///         down to the lowest usable GOLD price, i.e. up to this tick of the ETH-denominated v4 price.
    int24 public constant GENESIS_MAX_USABLE_TICK = 887220;
    uint256 private constant BPS = 10_000;

    address public immutable weth;
    address public immutable curator;
    IUniswapV3Factory public immutable factory;
    address public immutable genesisToken;
    IGoldHookOracle public immutable goldHook;
    mapping(address => bool) public tokenPaused;
    mapping(address => address) public poolOf;

    event TokenPaused(address indexed token, bool paused);
    event PoolSet(address indexed token, address indexed pool);

    error PoolNotConfigured(address token);
    error PoolMismatch();
    error OnlyCurator();
    error BadConfig();
    error PausedToken(address token);
    error StalePool(address pool);
    error ThinPool(address pool);

    constructor(address curator_, address weth_, address factory_, address genesisToken_, address goldHook_) {
        if (
            curator_ == address(0) || weth_ == address(0) || factory_ == address(0) || genesisToken_ == address(0)
                || goldHook_ == address(0) || genesisToken_ == weth_
        ) revert BadConfig();
        curator = curator_;
        weth = weth_;
        factory = IUniswapV3Factory(factory_);
        genesisToken = genesisToken_;
        goldHook = IGoldHookOracle(goldHook_);
    }

    modifier onlyCurator() {
        if (msg.sender != curator) revert OnlyCurator();
        _;
    }

    /// @notice Only the attestation Curator can list or delist a canonical Uniswap v3 pool.
    function setPool(address token, address pool) external onlyCurator {
        if (token == address(0) || token == weth || token == genesisToken) revert PoolMismatch();
        if (pool != address(0)) validatePool(token, pool);
        poolOf[token] = pool;
        emit PoolSet(token, pool);
    }

    function setTokenPaused(address token, bool paused) external onlyCurator {
        if (token == address(0)) revert BadConfig();
        tokenPaused[token] = paused;
        emit TokenPaused(token, paused);
    }

    /// @notice Checks identity, both TWAP histories, freshness and both sides of liquidity.
    function validatePool(address token, address pool) public view {
        if (token == weth || token == genesisToken || token.code.length == 0 || pool.code.length == 0) {
            revert PoolMismatch();
        }
        address t0 = IUniswapV3PoolOracle(pool).token0();
        address t1 = IUniswapV3PoolOracle(pool).token1();
        if (!((t0 == token && t1 == weth) || (t0 == weth && t1 == token))) revert PoolMismatch();
        if (factory.getPool(token, weth, IUniswapV3PoolOracle(pool).fee()) != pool) revert PoolMismatch();
        _checkPool(token, pool);
    }

    function isPriced(address token) public view returns (bool) {
        if (tokenPaused[token]) return false;
        if (token == genesisToken) return goldHook.initialized();
        return token == weth || poolOf[token] != address(0);
    }

    /// @notice ETH value of `amount` of `token` at the lower of the two TWAPs.
    function valueInEth(address token, uint256 amount) public view returns (uint256 value) {
        (value,) = _valueAndCap(token, amount);
    }

    /// @notice ETH value of `amount` of `token` at the lower TWAP, and the payout cap of its pool: PAYOUT_CAP_BPS of
    ///         the pool's conservative ETH-side depth. WETH has no pool and no cap. Reverts exactly as `valueInEth`.
    function valueAndCap(address token, uint256 amount) external view returns (uint256 value, uint256 cap) {
        return _valueAndCap(token, amount);
    }

    /// @notice The largest single draw payout, in ETH at the TWAP, that `token`'s pool currently backs.
    function payoutCap(address token) external view returns (uint256 cap) {
        (, cap) = _valueAndCap(token, 0);
    }

    function _valueAndCap(address token, uint256 amount) internal view returns (uint256 value, uint256 cap) {
        if (tokenPaused[token]) revert PausedToken(token);
        if (token == weth) return (amount, type(uint256).max);
        int24 shortTick;
        int24 longTick;
        uint256 ethDepth;
        address quoteToken = weth;
        if (token == genesisToken) {
            (shortTick, longTick, ethDepth) = _checkGenesisPool();
            quoteToken = address(0);
        } else {
            (shortTick, longTick, ethDepth) = _checkedTicks(token);
        }
        value = Math.min(
            _quoteAtTick(shortTick, amount, token, quoteToken), _quoteAtTick(longTick, amount, token, quoteToken)
        );
        cap = (ethDepth * PAYOUT_CAP_BPS) / BPS;
    }

    /// @notice Tokens bought by `ethAmount`. Regular tokens: at the lower of the two TWAP prices (ETH / min(price),
    ///         the conservative mark used for slippage floors). The genesis token: the **smaller** token amount of the
    ///         two windows, the quote less favourable to the buyer of a Genesis Bag, so a push of one window alone can
    ///         never inflate a Genesis Bag (finding 5).
    function tokensForEth(address token, uint256 ethAmount) external view returns (uint256) {
        if (tokenPaused[token]) revert PausedToken(token);
        if (token == weth) return ethAmount;
        if (token == genesisToken) {
            (int24 s, int24 l,) = _checkGenesisPool();
            return
                Math.min(_quoteAtTick(s, ethAmount, address(0), token), _quoteAtTick(l, ethAmount, address(0), token));
        }
        (int24 shortTick, int24 longTick,) = _checkedTicks(token);
        uint256 a = _quoteAtTick(shortTick, ethAmount, weth, token);
        uint256 b = _quoteAtTick(longTick, ethAmount, weth, token);
        return a > b ? a : b;
    }

    /// @notice GOLD minimum-output reference for POL buys: the larger token quote protects the buyer against
    ///         a pump of either window. GenesisVault continues to use the smaller quote in tokensForEth.
    function polTokensForEth(uint256 ethAmount) external view returns (uint256) {
        if (tokenPaused[genesisToken]) revert PausedToken(genesisToken);
        (int24 s, int24 l,) = _checkGenesisPool();
        return Math.max(
            _quoteAtTick(s, ethAmount, address(0), genesisToken), _quoteAtTick(l, ethAmount, address(0), genesisToken)
        );
    }

    /// @notice ETH value of `amount` of the genesis token at the 4-hour TWAP alone, and the genesis payout cap. The
    ///         gacha caps a Genesis Bag with this value, so the cap can only be loosened by moving the 4-hour window
    ///         while the quote itself already needs both windows moved. Reverts exactly as `valueInEth(GOLD)`.
    function genesisValueAndCap(uint256 amount) external view returns (uint256 value, uint256 cap) {
        if (tokenPaused[genesisToken]) revert PausedToken(genesisToken);
        (, int24 longTick, uint256 ethDepth) = _checkGenesisPool();
        value = _quoteAtTick(longTick, amount, genesisToken, address(0));
        cap = (ethDepth * PAYOUT_CAP_BPS) / BPS;
    }

    function _checkedTicks(address token) internal view returns (int24, int24, uint256) {
        address pool = poolOf[token];
        if (pool == address(0)) revert PoolNotConfigured(token);
        return _checkPool(token, pool);
    }

    /// @dev Returns both TWAP ticks and the pool's ETH-side depth, bounded by sustained active liquidity in a band.
    function _checkPool(address token, address pool)
        internal
        view
        returns (int24 shortTick, int24 longTick, uint256 wethSide)
    {
        (uint160 sqrtPrice, int24 spotTick, uint16 index) = IUniswapV3PoolOracle(pool).slot0();
        if (sqrtPrice < 1 || spotTick > TickMath.MAX_TICK || spotTick < -TickMath.MAX_TICK) revert StalePool(pool);
        uint32 last = IUniswapV3PoolOracle(pool).observations(index);
        if (block.timestamp > uint256(last) + MAX_STALENESS) revert StalePool(pool);
        uint256 tokenSide;
        uint128 meanLiquidity;
        (shortTick, longTick, meanLiquidity) = _ticks(pool);
        (tokenSide, wethSide) = _liquidBalances(token, pool, sqrtPrice, spotTick, meanLiquidity);
        uint256 shortValue = _quoteAtTick(shortTick, tokenSide, token, weth);
        uint256 longValue = _quoteAtTick(longTick, tokenSide, token, weth);
        if (Math.min(shortValue, longValue) < MIN_LIQUIDITY) revert ThinPool(pool);
    }

    /// @dev Genesis pool: ETH is currency0 and the hook admits only full-range positions. Depth uses the minimum of
    ///      current L and the records at both 30 minutes and 4 hours. Removing liquidity lowers depth immediately.
    ///      The valuation price is max(spot sqrtPrice, long-window sqrtPrice), so a spot pump cannot raise depth.
    ///      The ETH side is the ETH that liquidity holds between that valuation price and the
    ///      last usable tick (`L * (sqrtMax - sqrtP) * 2^96 / (sqrtP * sqrtMax)`), never more than the virtual reserve
    ///      `L * 2^96 / sqrtP`. It must be at least MIN_GENESIS_DEPTH; it is also the depth the payout cap is taken from.
    function _checkGenesisPool() internal view returns (int24 shortTick, int24 longTick, uint256 ethSide) {
        address hook = address(goldHook);
        if (!goldHook.initialized()) revert PoolNotConfigured(genesisToken);
        (uint160 sqrtPrice,) = goldHook.slot0();
        if (sqrtPrice < 1) revert StalePool(hook);
        if (block.timestamp > uint256(goldHook.lastObservationTimestamp()) + MAX_STALENESS) revert StalePool(hook);
        uint128 liquidity = goldHook.liquidity();
        if (liquidity == 0) revert ThinPool(hook);
        uint128 recorded = goldHook.liquidityAt(SHORT_WINDOW);
        if (recorded < liquidity) liquidity = recorded;
        recorded = goldHook.liquidityAt(LONG_WINDOW);
        if (recorded < liquidity) liquidity = recorded;
        if (liquidity == 0) revert ThinPool(hook);
        uint32[] memory ago = new uint32[](3);
        ago[0] = SHORT_WINDOW;
        ago[1] = LONG_WINDOW;
        int56[] memory cumulatives = goldHook.observe(ago);
        shortTick = _meanTick(cumulatives[2] - cumulatives[0], SHORT_WINDOW);
        longTick = _meanTick(cumulatives[2] - cumulatives[1], LONG_WINDOW);
        uint160 longPrice = TickMath.sqrtPriceAtTick(longTick);
        ethSide = genesisEthHeld(liquidity, sqrtPrice > longPrice ? sqrtPrice : longPrice);
        if (ethSide < MIN_GENESIS_DEPTH) revert ThinPool(hook);
    }

    /// @notice ETH (currency0) that active liquidity `liquidity` holds at `sqrtPrice` up to the last usable tick of
    ///         the genesis pool, bounded by the virtual reserve `L * 2^96 / sqrtP`.
    function genesisEthHeld(uint128 liquidity, uint160 sqrtPrice) public pure returns (uint256) {
        uint256 virtualReserve = Math.mulDiv(liquidity, 1 << 96, sqrtPrice);
        uint160 sqrtMax = TickMath.sqrtPriceAtTick(GENESIS_MAX_USABLE_TICK);
        if (sqrtPrice >= sqrtMax) return 0;
        // rounded down like Uniswap's amount0: a few wei under the virtual reserve at ordinary prices
        return Math.min(virtualReserve, Math.mulDiv(virtualReserve, sqrtMax - sqrtPrice, sqrtMax));
    }

    function _liquidBalances(address token, address pool, uint160 sqrtPrice, int24 spotTick, uint128 meanLiquidity)
        internal
        view
        returns (uint256 tokenSide, uint256 wethSide)
    {
        uint128 liquidity = IUniswapV3PoolOracle(pool).liquidity();
        if (meanLiquidity < liquidity) liquidity = meanLiquidity;
        if (liquidity == 0) revert ThinPool(pool);
        (uint256 side0, uint256 side1) = V3Depth.balances(pool, sqrtPrice, spotTick, liquidity);
        wethSide = token < weth ? side1 : side0;
        if (wethSide < MIN_LIQUIDITY) revert ThinPool(pool);
        tokenSide = token < weth ? side0 : side1;
    }

    /// @dev Read both TWAP windows and the 30-minute harmonic active liquidity from one observe call.
    function _ticks(address pool) internal view returns (int24 shortTick, int24 longTick, uint128 meanLiquidity) {
        uint32[] memory ago = new uint32[](3);
        ago[0] = SHORT_WINDOW;
        ago[1] = LONG_WINDOW;
        (int56[] memory cumulatives, uint160[] memory secondsPerLiquidity) = IUniswapV3PoolOracle(pool).observe(ago);
        uint160 delta;
        // The canonical v3 cumulative counters intentionally wrap.
        unchecked {
            delta = secondsPerLiquidity[2] - secondsPerLiquidity[0];
            shortTick = _meanTick(cumulatives[2] - cumulatives[0], SHORT_WINDOW);
            longTick = _meanTick(cumulatives[2] - cumulatives[1], LONG_WINDOW);
        }
        if (delta == 0) revert ThinPool(pool);
        // OracleLibrary's harmonic mean formula, with a 192-bit denominator to avoid truncation.
        meanLiquidity = uint128((uint192(SHORT_WINDOW) * type(uint160).max) / (uint192(delta) << 32));
    }

    function _meanTick(int56 delta, uint32 window) internal pure returns (int24 tick) {
        int56 span = int56(uint56(window));
        tick = int24(delta / span);
        if (delta < 0 && (delta % span != 0)) tick--;
    }

    function _quoteAtTick(int24 tick, uint256 amount, address base, address quoteToken)
        internal
        pure
        returns (uint256)
    {
        uint160 sqrtRatio = TickMath.sqrtPriceAtTick(tick);
        if (sqrtRatio <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtRatio) * sqrtRatio;
            return
                base < quoteToken ? Math.mulDiv(ratioX192, amount, 1 << 192) : Math.mulDiv(1 << 192, amount, ratioX192);
        }
        uint256 ratioX128 = Math.mulDiv(sqrtRatio, sqrtRatio, 1 << 64);
        return base < quoteToken ? Math.mulDiv(ratioX128, amount, 1 << 128) : Math.mulDiv(1 << 128, amount, ratioX128);
    }
}
