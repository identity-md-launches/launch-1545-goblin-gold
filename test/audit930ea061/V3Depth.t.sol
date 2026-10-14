// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TwapOracle} from "../../src/TwapOracle.sol";
import {TickMath} from "../../src/TickMath.sol";
import {V3Depth} from "../../src/v3/V3Depth.sol";
import {MockERC20, MockGoldHook} from "../mocks/Mocks.sol";
import {MockV3Pool, MockV3Factory} from "../mocks/CuratorMocks.sol";

contract V3DepthHarness {
    function balances(address pool, uint160 price, int24 tick, uint128 l) external view returns (uint256, uint256) {
        return V3Depth.balances(pool, price, tick, l);
    }
}

/// @notice Audit 930ea061 finding 3: same-transaction liquidity and parked WETH must not raise payout caps.
contract V3JitCapTest is Test {
    MockERC20 token;
    MockERC20 weth;
    MockV3Pool pool;
    TwapOracle oracle;
    V3DepthHarness depth;

    function setUp() public {
        vm.warp(100_000);
        token = new MockERC20("TOK");
        weth = new MockERC20("WETH");
        pool = new MockV3Pool(address(token), address(weth));
        MockV3Factory factory = new MockV3Factory();
        factory.setPool(address(token), address(weth), 3000, address(pool));
        oracle = new TwapOracle(
            address(this), address(weth), address(factory), address(new MockERC20("GOLD")), address(new MockGoldHook())
        );
        depth = new V3DepthHarness();
    }

    function testV3JitCapCannotMoveInOneTransaction() public {
        pool.setLiquidity(5 ether + 100);
        pool.setHistoryLiquidity(5 ether + 100);
        token.mint(address(pool), 5 ether + 100);
        weth.mint(address(pool), 5 ether + 100);
        oracle.setPool(address(token), address(pool));
        uint256 cap = oracle.payoutCap(address(token));
        assertApproxEqAbs(cap, 0.25 ether, 5);
        token.mint(address(pool), 95 ether);
        weth.mint(address(pool), 95 ether);
        pool.setLiquidity(100 ether + 100);
        assertEq(oracle.payoutCap(address(token)), cap);
        // Narrow JIT liquidity can only tighten the band bound, never lift it.
        pool.setInitializedTick(-60, true);
        pool.setInitializedTick(60, true);
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, address(pool)));
        oracle.payoutCap(address(token));
    }

    function testOutOfRangeWethDoesNotPassMinimumLiquidity() public {
        pool.setLiquidity(10 ether);
        pool.setHistoryLiquidity(10 ether);
        pool.setInitializedTick(-60, true);
        pool.setInitializedTick(60, true);
        // Arbitrarily large parked balances cannot back a one-spacing active position.
        token.mint(address(pool), 1_000_000 ether);
        weth.mint(address(pool), 1_000_000 ether);
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, address(pool)));
        oracle.setPool(address(token), address(pool));
        // The same L across the fixed band is enough: full-range-equivalent depth ~10 ETH per side.
        pool.setInitializedTick(-60, false);
        pool.setInitializedTick(60, false);
        oracle.setPool(address(token), address(pool));
        assertApproxEqAbs(oracle.payoutCap(address(token)), 0.5 ether, 2);
    }

    function testBothTokenOrdersUseTheEthSideOfTheBand() public {
        pool.setLiquidity(100 ether);
        pool.setHistoryLiquidity(100 ether);
        // A tick one spacing away makes one side ~6.3 ETH, the other stays ~100 ETH.
        pool.setInitializedTick(60, true);
        (uint256 side0, uint256 side1) = depth.balances(address(pool), 1 << 96, 0, 100 ether);
        assertGt(side0, 6 ether);
        assertLt(side0, 7 ether);
        assertApproxEqAbs(side1, 100 ether, 21);
        oracle.setPool(address(token), address(pool));
        assertEq(oracle.payoutCap(address(token)), (address(weth) < address(token) ? side0 : side1) / 20);
        // Reverse the identities while keeping the canonical pool and its tick ordering.
        MockV3Factory factory = new MockV3Factory();
        factory.setPool(address(token), address(weth), 3000, address(pool));
        TwapOracle reverse = new TwapOracle(
            address(this), address(token), address(factory), address(new MockERC20("G")), address(new MockGoldHook())
        );
        reverse.setPool(address(weth), address(pool));
        assertEq(reverse.payoutCap(address(weth)), (address(token) < address(weth) ? side0 : side1) / 20);
    }

    function testLiquidityRemovalAndInsufficientHistoryFailImmediately() public {
        oracle.setPool(address(token), address(pool));
        pool.setLiquidity(4 ether);
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, address(pool)));
        oracle.payoutCap(address(token));
        pool.setLiquidity(100 ether);
        pool.setHistoryLiquidity(4 ether);
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, address(pool)));
        oracle.payoutCap(address(token));
        pool.setNoHistory(true);
        vm.expectRevert(bytes("OLD"));
        oracle.payoutCap(address(token));
    }

    function testHarmonicMeanUsesTimeAtEachLiquidityAndHandlesCounterWrap() public {
        // Half a window at 10 L, half at 100 L: harmonic mean ~18.18, arithmetic mean 55.
        uint160 delta = uint160(((uint256(900) << 128) / 10 ether) + ((uint256(900) << 128) / 100 ether));
        pool.setLiquidityDelta(delta, true);
        oracle.setPool(address(token), address(pool));
        uint256 cap = oracle.payoutCap(address(token));
        assertApproxEqAbs(cap, uint256(10 ether) / 11, 2);
        assertLt(cap, 1 ether);
        pool.setLiquidityDelta(0, true);
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, address(pool)));
        oracle.payoutCap(address(token));
    }

    function testFuzzBandDepthIsBoundedAndNarrowerRangesOnlyReduceIt(int24 tick, uint128 l, uint16 width) public {
        tick = int24(bound(int256(tick), -800_000, 800_000));
        l = uint128(bound(l, 1e18, 1e24));
        width = uint16(bound(width, 1, 900));
        pool.setTickSpacing(1);
        uint160 sqrtP = TickMath.sqrtPriceAtTick(tick);
        (uint256 full0, uint256 full1) = depth.balances(address(pool), sqrtP, tick, l);
        assertLe(full0, Math.mulDiv(l, 1 << 96, sqrtP));
        assertLe(full1, Math.mulDiv(l, sqrtP, 1 << 96));
        pool.setInitializedTick(tick - int24(uint24(width)), true);
        pool.setInitializedTick(tick + int24(uint24(width)), true);
        (uint256 narrow0, uint256 narrow1) = depth.balances(address(pool), sqrtP, tick, l);
        assertLe(narrow0, full0);
        assertLe(narrow1, full1);
    }

    function testBitmapNegativeTicksAndWordBoundaries() public {
        pool.setTickSpacing(1);
        // Downward search includes current tick; upward starts at the next compressed tick, as v3 does.
        pool.setInitializedTick(-256, true);
        pool.setInitializedTick(256, true);
        (uint256 a, uint256 b) = depth.balances(address(pool), 1 << 96, 0, 100 ether);
        assertGt(a, 25 ether);
        assertLt(a, 27 ether);
        assertGt(b, 25 ether);
        assertLt(b, 27 ether);
        pool.setInitializedTick(0, true);
        (, b) = depth.balances(address(pool), 1 << 96, 0, 100 ether);
        assertEq(b, 0, "no depth credited across an initialized boundary");
    }
}
