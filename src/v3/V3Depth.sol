// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "../TickMath.sol";

interface IV3DepthPool {
    function tickSpacing() external view returns (int24);
    function tickBitmap(int16 word) external view returns (uint256);
}

/// @notice Conservative full-range-equivalent depth in a fixed +/-5% sqrt-price band (about 10% price).
/// @dev Count only liquidity released before the first initialized tick in each direction. Stopping there,
///      even if liquidity increases across it, deliberately underestimates depth. Out-of-range positions and
///      donated balances cannot increase it. Empty bitmap words are skipped; at spacing >= 1 each search reads
///      at most six words. All functions are internal: no linked library or external dependency is needed.
library V3Depth {
    uint256 private constant Q96 = 1 << 96;

    function balances(address pool, uint160 sqrtPrice, int24 tick, uint128 liquidity)
        internal
        view
        returns (uint256 amount0, uint256 amount1)
    {
        int24 spacing = IV3DepthPool(pool).tickSpacing();
        require(spacing > 0, "tick spacing");
        // Uniswap amount0/amount1 deltas, rounded down. Scale the released amounts by the fixed band's
        // fraction of a full-range reserve. If a position ends early, the missing part stays missing.
        {
            uint256 upper = uint256(sqrtPrice) * 105 / 100;
            uint160 end0 =
                _edge(pool, tick, spacing, uint160(Math.min(upper, TickMath.sqrtPriceAtTick(TickMath.MAX_TICK))), true);
            if (end0 > sqrtPrice) {
                uint256 released = Math.mulDiv(uint256(liquidity) << 96, end0 - sqrtPrice, end0) / sqrtPrice;
                amount0 =
                    Math.min(Math.mulDiv(liquidity, Q96, sqrtPrice), Math.mulDiv(released, upper, upper - sqrtPrice));
            }
        }
        {
            uint256 lower = uint256(sqrtPrice) * 100 / 105;
            uint160 end1 = _edge(
                pool, tick, spacing, uint160(Math.max(lower, TickMath.sqrtPriceAtTick(-TickMath.MAX_TICK))), false
            );
            if (end1 < sqrtPrice) {
                uint256 released = Math.mulDiv(liquidity, sqrtPrice - end1, Q96);
                amount1 = Math.min(
                    Math.mulDiv(liquidity, sqrtPrice, Q96), Math.mulDiv(released, sqrtPrice, sqrtPrice - lower)
                );
            }
        }
    }

    function _edge(address pool, int24 tick, int24 spacing, uint160 limit, bool up) private view returns (uint160) {
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
            if (next <= -TickMath.MAX_TICK || next >= TickMath.MAX_TICK) return limit;
            uint160 price = TickMath.sqrtPriceAtTick(next);
            if (up ? price >= limit : price <= limit) return limit;
            if (bitmap != 0) return price;
            tick = up ? next : next - 1;
        }
        revert(); // unreachable
    }
}
