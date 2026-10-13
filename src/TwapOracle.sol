// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "./TickMath.sol";

/// @dev Only the leading return values that are used are declared; the ABI decoder ignores the rest.
interface IUniswapV3PoolOracle {
    function fee() external view returns (uint24);
    function liquidity() external view returns (uint128);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16 observationIndex);
    function observations(uint256 index) external view returns (uint32 blockTimestamp);
    function observe(uint32[] calldata secondsAgos) external view returns (int56[] memory tickCumulatives);
}

interface IUniswapV3Factory {
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address);
}

interface IERC20Balance {
    function balanceOf(address) external view returns (uint256);
}

/// @title TwapOracle
/// @notice Conservative ETH marks for listed tokens: min(30-minute TWAP, 4-hour TWAP) from one Uniswap v3
///         token/WETH pool per token, rejected when the pool holds under 50 ETH of value on either side or its
///         latest observation is older than one hour. WETH is valued 1:1.
contract TwapOracle {
    uint32 public constant SHORT_WINDOW = 30 minutes;
    uint32 public constant LONG_WINDOW = 4 hours;
    uint256 public constant MAX_STALENESS = 1 hours;
    uint256 public constant MIN_LIQUIDITY = 50 ether;

    address public immutable weth;
    address public immutable curator;
    IUniswapV3Factory public immutable factory;
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

    constructor(address curator_, address weth_, address factory_) {
        if (curator_ == address(0) || weth_ == address(0) || factory_ == address(0)) revert BadConfig();
        curator = curator_;
        weth = weth_;
        factory = IUniswapV3Factory(factory_);
    }

    modifier onlyCurator() {
        if (msg.sender != curator) revert OnlyCurator();
        _;
    }

    /// @notice Only the attestation Curator can list or delist a canonical Uniswap v3 pool.
    function setPool(address token, address pool) external onlyCurator {
        if (token == address(0) || token == weth) revert PoolMismatch();
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
        if (token == weth || token.code.length == 0 || pool.code.length == 0) revert PoolMismatch();
        address t0 = IUniswapV3PoolOracle(pool).token0();
        address t1 = IUniswapV3PoolOracle(pool).token1();
        if (!((t0 == token && t1 == weth) || (t0 == weth && t1 == token))) revert PoolMismatch();
        if (factory.getPool(token, weth, IUniswapV3PoolOracle(pool).fee()) != pool) revert PoolMismatch();
        _checkPool(token, pool);
    }

    function isPriced(address token) public view returns (bool) {
        return !tokenPaused[token] && (token == weth || poolOf[token] != address(0));
    }

    /// @notice ETH value of `amount` of `token` at the lower of the two TWAPs.
    function valueInEth(address token, uint256 amount) public view returns (uint256) {
        if (tokenPaused[token]) revert PausedToken(token);
        if (token == weth) return amount;
        (int24 shortTick, int24 longTick) = _checkedTicks(token);
        uint256 a = _quoteAtTick(shortTick, amount, token, weth);
        uint256 b = _quoteAtTick(longTick, amount, token, weth);
        return a < b ? a : b;
    }

    /// @notice Tokens bought by `ethAmount` at the lower of the two TWAP prices (ETH / min(price)).
    function tokensForEth(address token, uint256 ethAmount) external view returns (uint256) {
        if (tokenPaused[token]) revert PausedToken(token);
        if (token == weth) return ethAmount;
        (int24 shortTick, int24 longTick) = _checkedTicks(token);
        uint256 a = _quoteAtTick(shortTick, ethAmount, weth, token);
        uint256 b = _quoteAtTick(longTick, ethAmount, weth, token);
        return a > b ? a : b;
    }

    function _checkedTicks(address token) internal view returns (int24, int24) {
        address pool = poolOf[token];
        if (pool == address(0)) revert PoolNotConfigured(token);
        return _checkPool(token, pool);
    }

    function _checkPool(address token, address pool) internal view returns (int24 shortTick, int24 longTick) {
        (uint160 sqrtPrice, int24 spotTick, uint16 index) = IUniswapV3PoolOracle(pool).slot0();
        if (sqrtPrice < 1 || spotTick > TickMath.MAX_TICK || spotTick < -TickMath.MAX_TICK) revert StalePool(pool);
        uint32 last = IUniswapV3PoolOracle(pool).observations(index);
        if (block.timestamp > uint256(last) + MAX_STALENESS) revert StalePool(pool);
        uint256 tokenSide = _liquidTokenBalance(token, pool, sqrtPrice);
        (shortTick, longTick) = _ticks(pool);
        uint256 shortValue = _quoteAtTick(shortTick, tokenSide, token, weth);
        uint256 longValue = _quoteAtTick(longTick, tokenSide, token, weth);
        if (Math.min(shortValue, longValue) < MIN_LIQUIDITY) revert ThinPool(pool);
    }

    function _liquidTokenBalance(address token, address pool, uint160 sqrtPrice) internal view returns (uint256) {
        uint128 liquidity = IUniswapV3PoolOracle(pool).liquidity();
        if (liquidity == 0) revert ThinPool(pool);
        uint256 virtual0 = Math.mulDiv(liquidity, 1 << 96, sqrtPrice);
        uint256 virtual1 = Math.mulDiv(liquidity, sqrtPrice, 1 << 96);
        uint256 wethSide = Math.min(IERC20Balance(weth).balanceOf(pool), token < weth ? virtual1 : virtual0);
        if (wethSide < MIN_LIQUIDITY) revert ThinPool(pool);
        return Math.min(IERC20Balance(token).balanceOf(pool), token < weth ? virtual0 : virtual1);
    }

    /// @dev Read both TWAP windows once, reusing them for depth checks and valuation.
    function _ticks(address pool) internal view returns (int24 shortTick, int24 longTick) {
        uint32[] memory ago = new uint32[](3);
        ago[0] = SHORT_WINDOW;
        ago[1] = LONG_WINDOW;
        int56[] memory cumulatives = IUniswapV3PoolOracle(pool).observe(ago);
        shortTick = _meanTick(cumulatives[2] - cumulatives[0], SHORT_WINDOW);
        longTick = _meanTick(cumulatives[2] - cumulatives[1], LONG_WINDOW);
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
