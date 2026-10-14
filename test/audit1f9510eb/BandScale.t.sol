// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TwapOracle} from "../../src/TwapOracle.sol";
import {V3Depth} from "../../src/v3/V3Depth.sol";
import {TickMath} from "../../src/TickMath.sol";
import {MockERC20, MockGoldHook} from "../mocks/Mocks.sol";
import {MockV3Pool, MockV3Factory} from "../mocks/CuratorMocks.sol";

contract BandMeasure {
    function measure(address pool, uint160 price, int24 tick, uint128 l)
        external
        view
        returns (uint256, uint256, uint256, uint256)
    {
        return V3Depth.measure(pool, price, tick, l);
    }
}

contract BandScaleTest is Test {
    MockERC20 token;
    MockERC20 weth;
    MockV3Pool pool;
    TwapOracle oracle;
    BandMeasure depth;

    function setUp() public {
        vm.warp(100_000);
        token = new MockERC20("TOKEN");
        weth = new MockERC20("WETH");
        pool = new MockV3Pool(address(token), address(weth));
        MockV3Factory factory = new MockV3Factory();
        factory.setPool(address(token), address(weth), 3000, address(pool));
        oracle = new TwapOracle(
            address(this), address(weth), address(factory), address(new MockERC20("GOLD")), address(new MockGoldHook())
        );
        depth = new BandMeasure();
    }

    function _liquidity(uint128 l) internal {
        pool.setLiquidity(l);
        pool.setHistoryLiquidity(l);
        pool.setInitializedTick(-1020, true);
        pool.setInitializedTick(1020, true);
        pool.setLiquidityNet(-1020, int128(l));
        pool.setLiquidityNet(1020, -int128(l));
    }

    function testAuditorBandScaleCannotPassOnQuarterEthOfCapital() public {
        _liquidity(5.0001 ether);
        (uint256 a, uint256 b, uint256 released0, uint256 released1) =
            depth.measure(address(pool), 1 << 96, 0, 5.0001 ether);
        assertGt(a, 5 ether);
        assertGt(b, 5 ether);
        assertLt(released0, 0.25 ether);
        assertLt(released1, 0.25 ether);
        // Parked balances are not a substitute for the unscaled in-band capital floor.
        weth.mint(address(pool), 1000 ether);
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, address(pool)));
        oracle.setPool(address(token), address(pool));
    }

    function testOneEthFloorAndCapBothTokenOrders() public {
        _liquidity(21 ether + 100);
        oracle.setPool(address(token), address(pool));
        (,, uint256 released0, uint256 released1) = depth.measure(address(pool), 1 << 96, 0, 21 ether + 100);
        uint256 released = address(weth) < address(token) ? released0 : released1;
        assertGe(released, 1 ether);
        assertLe(oracle.payoutCap(address(token)), released * oracle.IN_BAND_PAYOUT_MULTIPLE());
        assertApproxEqAbs(oracle.payoutCap(address(token)), 1 ether, 10);
        TwapOracle reverse = new TwapOracle(
            address(this),
            address(token),
            address(oracle.factory()),
            address(new MockERC20("G")),
            address(new MockGoldHook())
        );
        reverse.setPool(address(weth), address(pool));
        assertLe(reverse.payoutCap(address(weth)), address(token) < address(weth) ? released0 : released1);
        // One wei below the true floor fails regardless of the >5 ETH liquidity-equivalent result.
        _liquidity(21 ether - 1);
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, address(pool)));
        oracle.payoutCap(address(token));
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, address(pool)));
        reverse.payoutCap(address(weth));
    }

    function testFuzzPayoutNeverExceedsReleasedCapital(uint128 l) public {
        l = uint128(bound(l, 22 ether, 1e28));
        _liquidity(l);
        oracle.setPool(address(token), address(pool));
        (uint256 a, uint256 b, uint256 r0, uint256 r1) = depth.measure(address(pool), 1 << 96, 0, l);
        uint256 cap = oracle.payoutCap(address(token));
        assertLe(cap, (address(weth) < address(token) ? a : b) / 20);
        assertLe(cap, address(weth) < address(token) ? r0 : r1);
        assertGt(cap, 0);
    }

    function testDustTickCannotBreakOracleQuoteAfterListing() public {
        oracle.setPool(address(token), address(pool));
        uint256 beforeCap = oracle.payoutCap(address(token));
        pool.setInitializedTick(-60, true);
        pool.setInitializedTick(60, true);
        pool.setLiquidityNet(-60, 1);
        pool.setLiquidityNet(60, -1);
        assertApproxEqAbs(oracle.payoutCap(address(token)), beforeCap, 3);
        pool.setSpot(TickMath.sqrtPriceAtTick(60), 59);
        assertGt(oracle.payoutCap(address(token)), beforeCap / 2);
        pool.setInitializedTick(0, true);
        pool.setSpot(1 << 96, 0);
        assertGt(oracle.payoutCap(address(token)), beforeCap / 2);
    }

    function testCrossingShrinksLiquidityAndNeverCreditsAnIncrease() public {
        pool.setInitializedTick(60, true);
        pool.setInitializedTick(120, true);
        pool.setLiquidityNet(60, -40 ether);
        pool.setLiquidityNet(120, 100 ether);
        uint160 p60 = TickMath.sqrtPriceAtTick(60);
        uint160 p120 = TickMath.sqrtPriceAtTick(120);
        uint160 upper = uint160(uint256(1 << 96) * 105 / 100);
        (,, uint256 released,) = depth.measure(address(pool), 1 << 96, 0, 100 ether);
        uint256 expected = Math.mulDiv(uint256(100 ether) << 96, p60 - (1 << 96), p60) / (1 << 96)
            + Math.mulDiv(uint256(60 ether) << 96, p120 - p60, p120) / p60
            + Math.mulDiv(uint256(60 ether) << 96, upper - p120, upper) / p120;
        assertEq(released, expected, "carry reduced L; never restore it with new out-of-range L");
        pool.setLiquidityNet(60, type(int128).min);
        (,, released,) = depth.measure(address(pool), 1 << 96, 0, 100 ether);
        assertEq(released, Math.mulDiv(uint256(100 ether) << 96, p60 - (1 << 96), p60) / (1 << 96));
    }

    function testDownwardCrossingSubtractsLiquidityNet() public {
        pool.setInitializedTick(-60, true);
        pool.setLiquidityNet(-60, 40 ether);
        uint160 p60 = TickMath.sqrtPriceAtTick(-60);
        uint160 lower = uint160(uint256(1 << 96) * 100 / 105);
        (,,, uint256 released) = depth.measure(address(pool), 1 << 96, 0, 100 ether);
        assertEq(
            released, Math.mulDiv(100 ether, (1 << 96) - p60, 1 << 96) + Math.mulDiv(60 ether, p60 - lower, 1 << 96)
        );
    }

    function testTraversalStopsAtEightCrossingsAndDiscardsUnvisitedTail() public {
        for (int24 i = 1; i <= 9; ++i) {
            pool.setInitializedTick(i * 60, true);
            pool.setInitializedTick(-i * 60, true);
        }
        // A ninth liquidityNet read would revert: the ninth tick and its tail must not be visited.
        vm.mockCallRevert(address(pool), abi.encodeWithSelector(pool.ticks.selector, int24(540)), "ninth tick");
        vm.mockCallRevert(address(pool), abi.encodeWithSelector(pool.ticks.selector, int24(-540)), "ninth tick");
        (uint256 a, uint256 b,,) = depth.measure(address(pool), 1 << 96, 0, 100 ether);
        assertGt(a, 40 ether);
        assertLt(a, 60 ether);
        assertGt(b, 40 ether);
        assertLt(b, 60 ether);
    }
}
