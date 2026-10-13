// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "./TickMath.sol";

/// @dev Only the leading return values that are used are declared; the ABI decoder ignores the rest.
interface IUniswapV3PoolOracle {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint16 observationIndex);
    function observations(uint256 index) external view returns (uint32 blockTimestamp);
    function observe(uint32[] calldata secondsAgos) external view returns (int56[] memory tickCumulatives);
}

interface IERC20Balance {
    function balanceOf(address) external view returns (uint256);
}

/// @title TwapOracle
/// @notice Conservative ETH marks for listed tokens: min(30-minute TWAP, 4-hour TWAP) from one Uniswap v3
///         token/WETH pool per token, rejected when the pool holds under 50 ETH of value on either side or its
///         latest observation is older than one hour. WETH is valued 1:1.
contract TwapOracle is Ownable {
    uint32 public constant SHORT_WINDOW = 30 minutes;
    uint32 public constant LONG_WINDOW = 4 hours;
    uint256 public constant MAX_STALENESS = 1 hours;
    uint256 public constant MIN_LIQUIDITY = 50 ether;

    address public immutable weth;
    mapping(address => address) public poolOf;

    event PoolSet(address indexed token, address indexed pool);

    error PoolNotConfigured(address token);
    error PoolMismatch();
    error StalePool(address pool);
    error ThinPool(address pool);

    constructor(address owner_, address weth_) Ownable(owner_) {
        weth = weth_;
    }

    /// @notice Owner lists (or with address(0) delists) the canonical v3 pool for a token.
    function setPool(address token, address pool) external onlyOwner {
        if (pool != address(0)) {
            address t0 = IUniswapV3PoolOracle(pool).token0();
            address t1 = IUniswapV3PoolOracle(pool).token1();
            bool ok = (t0 == token && t1 == weth) || (t0 == weth && t1 == token);
            if (!ok) revert PoolMismatch();
        }
        poolOf[token] = pool;
        emit PoolSet(token, pool);
    }

    function isPriced(address token) public view returns (bool) {
        return token == weth || poolOf[token] != address(0);
    }

    /// @notice ETH value of `amount` of `token` at the lower of the two TWAPs.
    function valueInEth(address token, uint256 amount) public view returns (uint256) {
        if (token == weth) return amount;
        address pool = _checkedPool(token);
        uint256 a = _quote(pool, token, weth, amount, SHORT_WINDOW);
        uint256 b = _quote(pool, token, weth, amount, LONG_WINDOW);
        return a < b ? a : b;
    }

    /// @notice Tokens bought by `ethAmount` at the lower of the two TWAP prices (ETH / min(price)).
    function tokensForEth(address token, uint256 ethAmount) external view returns (uint256) {
        if (token == weth) return ethAmount;
        address pool = _checkedPool(token);
        uint256 a = _quote(pool, weth, token, ethAmount, SHORT_WINDOW);
        uint256 b = _quote(pool, weth, token, ethAmount, LONG_WINDOW);
        return a > b ? a : b;
    }

    function _checkedPool(address token) internal view returns (address pool) {
        pool = poolOf[token];
        if (pool == address(0)) revert PoolNotConfigured(token);
        (uint160 sqrtPrice, int24 spotTick, uint16 index) = IUniswapV3PoolOracle(pool).slot0();
        if (sqrtPrice < 1 || spotTick > TickMath.MAX_TICK || spotTick < -TickMath.MAX_TICK) revert StalePool(pool);
        uint32 last = IUniswapV3PoolOracle(pool).observations(index);
        if (block.timestamp > uint256(last) + MAX_STALENESS) revert StalePool(pool);
        uint256 wethSide = IERC20Balance(weth).balanceOf(pool);
        if (wethSide < MIN_LIQUIDITY) revert ThinPool(pool);
        uint256 tokenSide = IERC20Balance(token).balanceOf(pool);
        uint256 tokenSideEth = _quote(pool, token, weth, tokenSide, LONG_WINDOW);
        if (tokenSideEth < MIN_LIQUIDITY) revert ThinPool(pool);
    }

    function _quote(address pool, address base, address quoteToken, uint256 amount, uint32 window)
        internal
        view
        returns (uint256)
    {
        uint32[] memory ago = new uint32[](2);
        ago[0] = window;
        ago[1] = 0;
        int56[] memory cumulatives = IUniswapV3PoolOracle(pool).observe(ago);
        int56 delta = cumulatives[1] - cumulatives[0];
        int56 span = int56(uint56(window));
        int24 tick = int24(delta / span);
        if (delta < 0 && (delta % span != 0)) tick--;
        return _quoteAtTick(tick, amount, base, quoteToken);
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
