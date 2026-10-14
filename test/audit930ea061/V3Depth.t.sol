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
        pool.setLiquidity(21 ether + 100);
        pool.setHistoryLiquidity(21 ether + 100);
        token.mint(address(pool), 21 ether + 100);
        weth.mint(address(pool), 21 ether + 100);
        oracle.setPool(address(token), address(pool));
        uint256 cap = oracle.payoutCap(address(token));
        assertApproxEqAbs(cap, 1 ether, 5);
        token.mint(address(pool), 95 ether);
        weth.mint(address(pool), 95 ether);
        pool.setLiquidity(100 ether + 100);
        assertEq(oracle.payoutCap(address(token)), cap);
        // Narrow JIT liquidity can only tighten the band bound, never lift it.
        pool.setInitializedTick(-60, true);
        pool.setInitializedTick(60, true);
        pool.setLiquidityNet(-60, 100 ether);
        pool.setLiquidityNet(60, -100 ether);
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, address(pool)));
        oracle.payoutCap(address(token));
    }

    function testOutOfRangeWethDoesNotPassMinimumLiquidity() public {
        pool.setLiquidity(30 ether);
        pool.setHistoryLiquidity(30 ether);
        pool.setInitializedTick(-60, true);
        pool.setInitializedTick(60, true);
        pool.setLiquidityNet(-60, 30 ether);
        pool.setLiquidityNet(60, -30 ether);
        // Arbitrarily large parked balances cannot back a one-spacing active position.
        token.mint(address(pool), 1_000_000 ether);
        weth.mint(address(pool), 1_000_000 ether);
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, address(pool)));
        oracle.setPool(address(token), address(pool));
        // The same L across the fixed band is enough: liquidity-equivalent depth ~30 ETH per side, over 1 ETH released.
        pool.setInitializedTick(-60, false);
        pool.setInitializedTick(60, false);
        oracle.setPool(address(token), address(pool));
        assertApproxEqAbs(oracle.payoutCap(address(token)), uint256(30 ether) / 21, 2);
    }

    function testBothTokenOrdersUseTheEthSideOfTheBand() public {
        pool.setLiquidity(100 ether);
        pool.setHistoryLiquidity(100 ether);
        // A tick one spacing away makes one side ~6.3 ETH, the other stays ~100 ETH.
        pool.setInitializedTick(60, true);
        pool.setLiquidityNet(60, -100 ether);
        (uint256 side0, uint256 side1) = depth.balances(address(pool), 1 << 96, 0, 100 ether);
        assertGt(side0, 6 ether);
        assertLt(side0, 7 ether);
        assertApproxEqAbs(side1, 100 ether, 21);
        if (address(weth) < address(token)) {
            vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, address(pool)));
            oracle.setPool(address(token), address(pool));
        } else {
            oracle.setPool(address(token), address(pool));
            assertApproxEqAbs(oracle.payoutCap(address(token)), uint256(100 ether) / 21, 2);
        }
        // Reverse the identities while keeping the canonical pool and its tick ordering.
        MockV3Factory factory = new MockV3Factory();
        factory.setPool(address(token), address(weth), 3000, address(pool));
        TwapOracle reverse = new TwapOracle(
            address(this), address(token), address(factory), address(new MockERC20("G")), address(new MockGoldHook())
        );
        if (address(token) < address(weth)) {
            vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, address(pool)));
            reverse.setPool(address(weth), address(pool));
        } else {
            reverse.setPool(address(weth), address(pool));
            assertApproxEqAbs(reverse.payoutCap(address(weth)), uint256(100 ether) / 21, 2);
        }
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
        // Half a window at 20 L, half at 200 L: harmonic mean ~36.36, arithmetic mean 110.
        uint160 delta = uint160(((uint256(900) << 128) / 20 ether) + ((uint256(900) << 128) / 200 ether));
        pool.setLiquidityDelta(delta, true);
        oracle.setPool(address(token), address(pool));
        uint256 cap = oracle.payoutCap(address(token));
        assertApproxEqAbs(cap, uint256(400 ether) / 231, 2);
        assertLt(cap, 2 ether);
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
        pool.setLiquidityNet(tick - int24(uint24(width)), int128(l));
        pool.setLiquidityNet(tick + int24(uint24(width)), -int128(l));
        (uint256 narrow0, uint256 narrow1) = depth.balances(address(pool), sqrtP, tick, l);
        assertLe(narrow0, full0);
        assertLe(narrow1, full1);
    }

    function testBitmapNegativeTicksAndWordBoundaries() public {
        pool.setTickSpacing(1);
        // Both directions skip an exact-price boundary, including negative bitmap word boundaries.
        pool.setInitializedTick(-256, true);
        pool.setInitializedTick(256, true);
        pool.setLiquidityNet(-256, 100 ether);
        pool.setLiquidityNet(256, -100 ether);
        (uint256 a, uint256 b) = depth.balances(address(pool), 1 << 96, 0, 100 ether);
        assertGt(a, 25 ether);
        assertLt(a, 27 ether);
        assertGt(b, 25 ether);
        assertLt(b, 27 ether);
        pool.setInitializedTick(0, true);
        (, b) = depth.balances(address(pool), 1 << 96, 0, 100 ether);
        assertGt(b, 25 ether, "an already-crossed boundary cannot zero the depth");
        assertLt(b, 27 ether);
    }
}
