// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "../TickMath.sol";

interface IV3DepthPool {
    function tickSpacing() external view returns (int24);
    function tickBitmap(int16 word) external view returns (uint256);
    // Only the two leading words are needed; canonical v3 returns six more words.
    function ticks(int24 tick) external view returns (uint128 liquidityGross, int128 liquidityNet);
}

/// @notice Conservative liquidity-equivalent depth in a fixed sqrt-price band [sqrtP/1.05, sqrtP*1.05].
/// @dev Walk at most eight initialized crossings per direction. Carry only min(L, L +/- liquidityNet)
///      into each next segment: new liquidity across a crossing cannot raise the bound. Unvisited depth,
///      out-of-range balances and donations never count. All functions are internal, with no linked library.
library V3Depth {
    uint256 private constant Q96 = 1 << 96;
    uint256 internal constant MAX_CROSSINGS = 8;

    function balances(address pool, uint160 sqrtPrice, int24 tick, uint128 liquidity)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        (amount0, amount1,,) = measure(pool, sqrtPrice, tick, liquidity);
    }

    /// @return amount0 Liquidity-equivalent token0 depth, bounded by its virtual reserve.
    /// @return amount1 Liquidity-equivalent token1 depth, bounded by its virtual reserve.
    /// @return released0 Unscaled token0 released inside the walked band.
    /// @return released1 Unscaled token1 released inside the walked band.
    function measure(address pool, uint160 sqrtPrice, int24 tick, uint128 liquidity)
        internal
        view
        returns (uint256 amount0, uint256 amount1, uint256 released0, uint256 released1)
    {
        int24 spacing = IV3DepthPool(pool).tickSpacing();
        require(spacing > 0, "tick spacing");
        {
            uint256 upper = uint256(sqrtPrice) * 105 / 100;
            uint160 limit = uint160(Math.min(upper, TickMath.sqrtPriceAtTick(TickMath.MAX_TICK)));
            released0 = _walk(pool, sqrtPrice, tick, spacing, liquidity, limit, true);
            amount0 = Math.min(Math.mulDiv(liquidity, Q96, sqrtPrice), Math.mulDiv(released0, upper, upper - sqrtPrice));
        }
        {
            uint256 lower = uint256(sqrtPrice) * 100 / 105;
            uint160 limit = uint160(Math.max(lower, TickMath.sqrtPriceAtTick(-TickMath.MAX_TICK)));
            released1 = _walk(pool, sqrtPrice, tick, spacing, liquidity, limit, false);
            amount1 =
                Math.min(Math.mulDiv(liquidity, sqrtPrice, Q96), Math.mulDiv(released1, sqrtPrice, sqrtPrice - lower));
        }
    }

    function _walk(address pool, uint160 price, int24 tick, int24 spacing, uint128 liquidity, uint160 limit, bool up)
        private
        view
        returns (uint256 released)
    {
        // v3 can park at (price(T), T-1) after a downward swap or (price(T), T) after an upward swap.
        // Skip that boundary in the search. When walking back across it, first apply its net change to
        // the current side's liquidity, just as a v3 swap crosses it with a zero-length price step.
        uint256 crossed;
        if (up) {
            if (tick < TickMath.MAX_TICK && TickMath.sqrtPriceAtTick(tick + 1) == price) {
                ++tick;
                bool initialized;
                (liquidity, initialized) = _cross(pool, tick, liquidity, up);
                if (initialized) ++crossed;
            }
        } else if (TickMath.sqrtPriceAtTick(tick) == price) {
            bool initialized;
            (liquidity, initialized) = _cross(pool, tick, liquidity, up);
            if (initialized) ++crossed;
            --tick;
        }
        for (; crossed < MAX_CROSSINGS && liquidity > 0 && (up ? price < limit : price > limit); ++crossed) {
            (uint160 end, int24 next, bool initialized) = _edge(pool, tick, spacing, limit, up);
            released += up
                ? Math.mulDiv(uint256(liquidity) << 96, end - price, end) / price
                : Math.mulDiv(liquidity, price - end, Q96);
            if (!initialized) break;
            (liquidity,) = _cross(pool, next, liquidity, up);
            price = end;
            tick = up ? next : next - 1;
            // At the read budget, discard the tail: no assumption about unseen ticks or liquidity.
        }
    }

    function _cross(address pool, int24 tick, uint128 liquidity, bool up)
        private
        view
        returns (uint128, bool initialized)
    {
        (uint128 gross, int128 net) = IV3DepthPool(pool).ticks(tick);
        initialized = gross > 0;
        // Use int256 so even int128.min is safe to negate, and a drop exceeding the harmonic bound
        // exhausts credited liquidity instead of underflowing. Positive changes never raise the bound.
        int256 afterCross = int256(uint256(liquidity)) + (up ? int256(net) : -int256(net));
        if (afterCross <= 0) return (0, initialized);
        return (uint128(Math.min(liquidity, uint256(afterCross))), initialized);
    }

    function _edge(address pool, int24 tick, int24 spacing, uint160 limit, bool up)
        private
        view
        returns (uint160, int24, bool)
    {
        while (true) {
            int24 compressed = tick / spacing;
            if (tick < 0 && tick % spacing != 0) --compressed;
            if (up) ++compressed;
            int16 word = int16(compressed >> 8);
            uint8 bit = uint8(uint24(compressed));
            uint256 bitmap = IV3DepthPool(pool).tickBitmap(word);
            bitmap &= up ? type(uint256).max << bit : type(uint256).max >> (255 - bit);
            int24 next;
            if (bitmap == 0) {
                next = up
                    ? (compressed + int24(uint24(255 - bit))) * spacing
                    : (compressed - int24(uint24(bit))) * spacing;
            } else {
                uint256 found = up ? Math.log2(bitmap & (~bitmap + 1)) : Math.log2(bitmap);
                next = (compressed - int24(uint24(bit)) + int24(uint24(found))) * spacing;
            }
            if (next <= -TickMath.MAX_TICK || next >= TickMath.MAX_TICK) return (limit, 0, false);
            uint160 price = TickMath.sqrtPriceAtTick(next);
            if (up ? price >= limit : price <= limit) return (limit, 0, false);
            if (bitmap != 0) return (price, next, true);
            tick = up ? next : next - 1;
        }
        revert(); // unreachable
    }
}
