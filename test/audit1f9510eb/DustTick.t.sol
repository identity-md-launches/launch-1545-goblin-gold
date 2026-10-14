// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {V3Depth} from "src/v3/V3Depth.sol";
import {TickMath} from "src/TickMath.sol";

/// @dev A v3 pool's tick bitmap and tick table, enough for V3Depth (and for a fix that walks liquidityNet).
contract DustPool {
    int24 public tickSpacing = 60;
    mapping(int16 => uint256) public tickBitmap;
    mapping(int24 => int128) public liquidityNetOf;

    function initTick(int24 tick, int128 net) external {
        int24 compressed = tick / tickSpacing;
        tickBitmap[int16(compressed >> 8)] |= 1 << uint8(uint24(compressed));
        liquidityNetOf[tick] = net;
    }

    function ticks(int24 tick)
        external
        view
        returns (uint128 liquidityGross, int128 liquidityNet, uint256, uint256, int56, uint160, uint32, bool)
    {
        int128 net = liquidityNetOf[tick];
        return (uint128(net < 0 ? -net : net), net, 0, 0, 0, 0, 0, net != 0);
    }
}

contract DepthHarness {
    function balances(address pool, uint160 price, int24 tick, uint128 l) external view returns (uint256, uint256) {
        return V3Depth.balances(pool, price, tick, l);
    }
}

/// @notice A 1-wei-liquidity position whose tick is within one spacing of the price caps the measured depth at a
///         sliver of the real depth; a swap that stops exactly at an initialized tick measures zero.
contract DustTickDepthTest is Test {
    DustPool pool;
    DepthHarness depth;
    uint160 constant P = 1 << 96; // price 1, tick 0
    uint128 constant L = 100 ether; // 100 ETH virtual reserve on each side

    function setUp() public {
        pool = new DustPool();
        depth = new DepthHarness();
    }

    function testOneDustTickWithinOneSpacingMakesA100EthPoolThin() public {
        (uint256 a0, uint256 a1) = depth.balances(address(pool), P, 0, L);
        assertApproxEqRel(a0, 100 ether, 1e15);
        assertApproxEqRel(a1, 100 ether, 1e15);

        // Attacker: position [60, 120] with 1 wei of liquidity (dust of both tokens, left forever).
        pool.initTick(60, 1);
        pool.initTick(120, -1);
        (a0, a1) = depth.balances(address(pool), P, 0, L);
        emit log_named_decimal_uint("token0 depth seen with one dust tick at +60", a0, 18);
        // A 1-wei position changes the pool's real depth by nothing; the measured ETH side must not drop below
        // half of the 100 ETH the active liquidity really backs across the band.
        assertGe(a0, 50 ether, "one dust tick made the pool unpriceable");
    }

    function testSwapParkedExactlyAtAnInitializedTickMeasuresZero() public {
        pool.initTick(60, 1);
        pool.initTick(120, -1);
        // A zeroForOne swap with sqrtPriceLimitX96 == sqrtPriceAtTick(60) ends with slot0 = (price(60), tick 59).
        uint160 pinned = TickMath.sqrtPriceAtTick(60);
        (uint256 a0,) = depth.balances(address(pool), pinned, 59, L);
        emit log_named_uint("token0 depth seen when parked at tick 60", a0);
        assertGt(a0, 0, "parked at the tick: zero depth, every quote reverts ThinPool");
    }

    function testParkedAtTickAfterUpwardSwapRetainsDownwardDepth() public {
        pool.initTick(0, 1);
        pool.initTick(60, -1);
        (, uint256 b) = depth.balances(address(pool), P, 0, L);
        assertGe(b, 50 ether);
    }

    function testNegativeDustTicksRetainDepthInBothDirections() public {
        pool.initTick(-120, 1);
        pool.initTick(-60, -1);
        uint160 p = TickMath.sqrtPriceAtTick(-60);
        (uint256 a, uint256 b) = depth.balances(address(pool), p, -61, L);
        assertGt(a, 50 ether);
        assertGt(b, 50 ether);
    }

    function testParkedAtLowerBoundaryCannotCreditEmptyLeftSide() public {
        pool.initTick(0, int128(L));
        pool.initTick(1020, -int128(L));
        // After crossing upward, current L is on the right. A downward walk crosses zero immediately.
        (uint256 a, uint256 b) = depth.balances(address(pool), P, 0, L);
        assertGt(a, 50 ether);
        assertEq(b, 0, "all active L ends on the left at the starting price");
    }

    function testParkedAtUpperBoundaryCannotCreditEmptyRightSide() public {
        pool.initTick(-1020, int128(L));
        pool.initTick(0, -int128(L));
        // After crossing downward, current L is on the left. An upward walk crosses zero immediately.
        (uint256 a, uint256 b) = depth.balances(address(pool), P, -1, L);
        assertEq(a, 0, "all active L ends on the right at the starting price");
        assertGt(b, 50 ether);
    }
}
