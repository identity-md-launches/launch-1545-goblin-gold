// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice sqrt(1.0001^tick) * 2^96, same constants as Uniswap's TickMath. Internal only, so it is inlined.
library TickMath {
    int24 internal constant MAX_TICK = 887272;

    error TickOutOfRange();

    function sqrtPriceAtTick(int24 tick) internal pure returns (uint160) {
        uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
        if (absTick > uint256(int256(MAX_TICK))) revert TickOutOfRange();
        uint256 ratio = absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x100000000000000000000000000000000;
        assembly {
            if iszero(iszero(and(absTick, 0x2))) {
                ratio := shr(128, mul(ratio, 0xfff97272373d413259a46990580e213a))
            }
            if iszero(iszero(and(absTick, 0x4))) {
                ratio := shr(128, mul(ratio, 0xfff2e50f5f656932ef12357cf3c7fdcc))
            }
            if iszero(iszero(and(absTick, 0x8))) {
                ratio := shr(128, mul(ratio, 0xffe5caca7e10e4e61c3624eaa0941cd0))
            }
            if iszero(iszero(and(absTick, 0x10))) {
                ratio := shr(128, mul(ratio, 0xffcb9843d60f6159c9db58835c926644))
            }
            if iszero(iszero(and(absTick, 0x20))) {
                ratio := shr(128, mul(ratio, 0xff973b41fa98c081472e6896dfb254c0))
            }
            if iszero(iszero(and(absTick, 0x40))) {
                ratio := shr(128, mul(ratio, 0xff2ea16466c96a3843ec78b326b52861))
            }
            if iszero(iszero(and(absTick, 0x80))) {
                ratio := shr(128, mul(ratio, 0xfe5dee046a99a2a811c461f1969c3053))
            }
            if iszero(iszero(and(absTick, 0x100))) {
                ratio := shr(128, mul(ratio, 0xfcbe86c7900a88aedcffc83b479aa3a4))
            }
            if iszero(iszero(and(absTick, 0x200))) {
                ratio := shr(128, mul(ratio, 0xf987a7253ac413176f2b074cf7815e54))
            }
            if iszero(iszero(and(absTick, 0x400))) {
                ratio := shr(128, mul(ratio, 0xf3392b0822b70005940c7a398e4b70f3))
            }
            if iszero(iszero(and(absTick, 0x800))) {
                ratio := shr(128, mul(ratio, 0xe7159475a2c29b7443b29c7fa6e889d9))
            }
            if iszero(iszero(and(absTick, 0x1000))) {
                ratio := shr(128, mul(ratio, 0xd097f3bdfd2022b8845ad8f792aa5825))
            }
            if iszero(iszero(and(absTick, 0x2000))) {
                ratio := shr(128, mul(ratio, 0xa9f746462d870fdf8a65dc1f90e061e5))
            }
            if iszero(iszero(and(absTick, 0x4000))) {
                ratio := shr(128, mul(ratio, 0x70d869a156d2a1b890bb3df62baf32f7))
            }
            if iszero(iszero(and(absTick, 0x8000))) {
                ratio := shr(128, mul(ratio, 0x31be135f97d08fd981231505542fcfa6))
            }
            if iszero(iszero(and(absTick, 0x10000))) {
                ratio := shr(128, mul(ratio, 0x9aa508b5b7a84e1c677de54f3e99bc9))
            }
            if iszero(iszero(and(absTick, 0x20000))) {
                ratio := shr(128, mul(ratio, 0x5d6af8dedb81196699c329225ee604))
            }
            if iszero(iszero(and(absTick, 0x40000))) {
                ratio := shr(128, mul(ratio, 0x2216e584f5fa1ea926041bedfe98))
            }
            if iszero(iszero(and(absTick, 0x80000))) {
                ratio := shr(128, mul(ratio, 0x48a170391f7dc42444e8fa2))
            }
            if sgt(tick, 0) { ratio := div(not(0), ratio) }
            ratio := add(shr(32, ratio), iszero(iszero(and(ratio, 0xffffffff))))
        }
        return uint160(ratio);
    }
}
