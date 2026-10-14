// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {TwapOracle} from "../src/TwapOracle.sol";
import {MockERC20, MockGoldHook} from "./mocks/Mocks.sol";
import {MockV3Factory, MockV3Pool} from "./mocks/CuratorMocks.sol";

contract TwapOracleTest is Test {
    TwapOracle oracle;
    MockERC20 gold;
    MockGoldHook goldHook;
    MockERC20 token;
    MockERC20 weth;
    MockV3Factory factory;
    MockV3Pool pool;

    function setUp() public {
        vm.warp(100_000);
        token = new MockERC20("T");
        weth = new MockERC20("WETH");
        factory = new MockV3Factory();
        pool = new MockV3Pool(address(token), address(weth));
        factory.setPool(address(token), address(weth), 3000, address(pool));
        gold = new MockERC20("GOLD");
        goldHook = new MockGoldHook();
        oracle = new TwapOracle(address(this), address(weth), address(factory), address(gold), address(goldHook));
        token.mint(address(pool), 100 ether);
        weth.mint(address(pool), 100 ether);
    }

    function testMinOfBothTWAPsAndReverseQuote() public {
        oracle.setPool(address(token), address(pool));
        pool.setTicks(0, 100);
        uint256 a = oracle.valueInEth(address(token), 1 ether);
        uint256 b = oracle.tokensForEth(address(token), 1 ether);
        assertLe(a, 1 ether);
        assertGe(b, 1 ether);
        pool.setTicks(100, 0);
        assertEq(oracle.valueInEth(address(token), 1 ether), a);
        assertEq(oracle.tokensForEth(address(token), 1 ether), b);
    }

    function testInsufficientLiquidityAndMissingHistory() public {
        pool.setLiquidity(4.99 ether);
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, address(pool)));
        oracle.setPool(address(token), address(pool));
        pool.setLiquidity(21 ether + 100); // allowance for conservative integer rounding
        oracle.setPool(address(token), address(pool));
        pool.setNoHistory(true);
        vm.expectRevert(bytes("OLD"));
        oracle.valueInEth(address(token), 1 ether);
    }

    function testRegularPoolEquivalentDepthAndCapitalFloor() public {
        assertEq(oracle.MIN_LIQUIDITY(), 5 ether);
        pool.setLiquidity(4.99 ether);
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, address(pool)));
        oracle.setPool(address(token), address(pool));
        pool.setLiquidity(21 ether + 100);
        oracle.setPool(address(token), address(pool));
        assertEq(oracle.valueInEth(address(token), 1 ether), 1 ether);
        // A removal lowers depth immediately; a large balance cannot hide it.
        pool.setLiquidity(4.99 ether);
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, address(pool)));
        oracle.valueInEth(address(token), 1 ether);
        pool.setLiquidity(30 ether);
        // Historical liquidity also bounds both sides even with plenty of current liquidity.
        pool.setHistoryLiquidity(4.99 ether);
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, address(pool)));
        oracle.valueInEth(address(token), 1 ether);
        pool.setHistoryLiquidity(21 ether + 100);
        assertEq(oracle.valueInEth(address(token), 1 ether), 1 ether);
    }

    /// @dev v3.1 boundaries: the genesis pool needs an ETH-side depth of 1 ETH (0.99 fails, 1 passes); at price 1:1
    ///      the ETH virtual reserve `L * 2^96 / sqrtP` equals the liquidity.
    function testGenesisPoolOneEthBoundary() public {
        assertEq(oracle.MIN_GENESIS_DEPTH(), 1 ether);
        goldHook.setState(uint160(1 << 96), 0.99 ether);
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, address(goldHook)));
        oracle.valueInEth(address(gold), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, address(goldHook)));
        oracle.tokensForEth(address(gold), 1 ether);
        // v3.2: the depth is the ETH the liquidity holds up to the last usable tick, a few wei under L at 1:1
        uint256 held = oracle.genesisEthHeld(1 ether, uint160(1 << 96));
        assertLt(held, 1 ether);
        assertGt(held, 1 ether - 10);
        goldHook.setState(uint160(1 << 96), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, address(goldHook)));
        oracle.valueInEth(address(gold), 1 ether);
        goldHook.setState(uint160(1 << 96), 1 ether + 10);
        assertEq(oracle.valueInEth(address(gold), 1 ether), 1 ether);
        assertEq(oracle.tokensForEth(address(gold), 1 ether), 1 ether);
        // the bound is on the ETH side: at a price of 4 GOLD per ETH, liquidity 2e18 holds 1 ETH and 4 GOLD
        goldHook.setState(uint160(2 << 96), 2 ether + 10);
        goldHook.setTicks(13863, 13863); // tick of price 4 (1.0001^13863 ~= 4)
        assertApproxEqAbs(oracle.payoutCap(address(gold)), 0.05 ether, 1);
        goldHook.setState(uint160(2 << 96), 2 ether - 2);
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, address(goldHook)));
        oracle.valueInEth(address(gold), 1 ether);
        goldHook.setState(uint160(1 << 96), 0);
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, address(goldHook)));
        oracle.valueInEth(address(gold), 1 ether);
    }

    /// @dev The payout cap is min(5% of equivalent depth, released WETH) for regular pools; Genesis uses 5%. WETH is
    ///      uncapped. The value returned beside it is the plain TWAP value.
    function testPayoutCapIsFivePercentOfEthSideDepth() public {
        assertEq(oracle.PAYOUT_CAP_BPS(), 500);
        oracle.setPool(address(token), address(pool));
        (uint256 v, uint256 cap) = oracle.valueAndCap(address(token), 3 ether);
        assertEq(v, 3 ether);
        assertApproxEqAbs(cap, uint256(100 ether) / 21, 2); // 100 ETH of sustained full-range liquidity
        assertApproxEqAbs(oracle.payoutCap(address(token)), uint256(100 ether) / 21, 2);
        // Current removals count immediately; token balances never set depth.
        pool.setLiquidity(42 ether);
        assertApproxEqAbs(oracle.payoutCap(address(token)), 2 ether, 2);
        pool.setLiquidity(100 ether);
        vm.prank(address(pool));
        weth.transfer(address(this), 90 ether);
        assertApproxEqAbs(oracle.payoutCap(address(token)), uint256(100 ether) / 21, 2);
        // genesis: 5% of L * 2^96 / sqrtP
        (v, cap) = oracle.valueAndCap(address(gold), 2 ether);
        assertEq(v, 2 ether);
        assertApproxEqAbs(cap, 5 ether, 1);
        goldHook.setState(uint160(1 << 96), 7 ether);
        assertApproxEqAbs(oracle.payoutCap(address(gold)), 0.35 ether, 1);
        // v3.2: the recorded liquidity of 30 minutes ago bounds the depth; a lower current liquidity counts at once
        goldHook.setRecordedLiquidity(2 ether, true);
        assertApproxEqAbs(oracle.payoutCap(address(gold)), 0.1 ether, 1);
        goldHook.setState(uint160(1 << 96), 1.5 ether);
        assertApproxEqAbs(oracle.payoutCap(address(gold)), 0.075 ether, 1);
        goldHook.setRecordedLiquidity(0.99 ether, true);
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, address(goldHook)));
        oracle.payoutCap(address(gold));
        goldHook.setRecordedLiquidity(0, false);
        goldHook.setState(uint160(1 << 96), 100 ether);
        (v, cap) = oracle.valueAndCap(address(weth), 123 ether);
        assertEq(v, 123 ether);
        assertEq(cap, type(uint256).max);
        // the cap view fails exactly where a quote fails
        vm.warp(vm.getBlockTimestamp() + 3601);
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.StalePool.selector, address(pool)));
        oracle.valueAndCap(address(token), 1 ether);
        oracle.setTokenPaused(address(gold), true);
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.PausedToken.selector, address(gold)));
        oracle.payoutCap(address(gold));
    }

    function testStaleDelistedAndPausedValuesRevertWETHMayPause() public {
        oracle.setPool(address(token), address(pool));
        vm.warp(vm.getBlockTimestamp() + 3601);
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.StalePool.selector, address(pool)));
        oracle.valueInEth(address(token), 1 ether);
        oracle.setPool(address(token), address(0));
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.PoolNotConfigured.selector, address(token)));
        oracle.valueInEth(address(token), 1 ether);
        oracle.setTokenPaused(address(weth), true);
        assertFalse(oracle.isPriced(address(weth)));
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.PausedToken.selector, address(weth)));
        oracle.tokensForEth(address(weth), 1 ether);
    }

    function testDonationsAndInactiveLiquidityCannotSatisfyTheLiquidityBound() public {
        pool.setLiquidity(4.9 ether);
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, address(pool)));
        oracle.setPool(address(token), address(pool));
        pool.setLiquidity(0);
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, address(pool)));
        oracle.setPool(address(token), address(pool));
        pool.setLiquidity(21 ether + 100);
        oracle.setPool(address(token), address(pool));
    }

    function testFuzzInBandCapitalBoundary(uint128 liquidity) public {
        // Test both sides of the threshold outside the <= 21 wei band of conservative rounding.
        liquidity = uint128(bound(liquidity, 1, 30 ether));
        if (liquidity >= 21 ether && liquidity < 21 ether + 100) liquidity = 21 ether + 100;
        pool.setLiquidity(liquidity);
        if (liquidity < 21 ether) vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, address(pool)));
        oracle.setPool(address(token), address(pool));
        if (liquidity >= 21 ether) {
            assertEq(oracle.valueInEth(address(token), 1 ether), 1 ether);
            assertApproxEqAbs(oracle.payoutCap(address(token)), liquidity / 21, 2);
        }
    }

    function testFuzzGenesisOneEthBoundary(uint128 liquidity) public {
        liquidity = uint128(bound(liquidity, 1, 3 ether));
        goldHook.setState(uint160(1 << 96), liquidity);
        uint256 held = oracle.genesisEthHeld(liquidity, uint160(1 << 96));
        assertLe(held, liquidity);
        assertGe(held + 10, liquidity);
        if (held < 1 ether) {
            vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, address(goldHook)));
            oracle.valueInEth(address(gold), 1 ether);
        } else {
            assertEq(oracle.valueInEth(address(gold), 1 ether), 1 ether);
            assertEq(oracle.payoutCap(address(gold)), held / 20);
        }
    }

    function testGenesisFourHourLiquidityAndPriceAreIndependentBounds() public {
        goldHook.setState(uint160(1 << 96), 100 ether);
        goldHook.setRecordedLiquidity(80 ether, true);
        goldHook.setLongLiquidity(20 ether, true);
        assertApproxEqAbs(oracle.payoutCap(address(gold)), 1 ether, 1);
        goldHook.setLongLiquidity(0.5 ether, true);
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, address(goldHook)));
        oracle.payoutCap(address(gold));
        goldHook.setLongLiquidity(20 ether, true);
        // Pumping spot only (half sqrt price) cannot lift the ETH depth above its long-window mark.
        goldHook.setState(uint160(1 << 95), 100 ether);
        assertApproxEqAbs(oracle.payoutCap(address(gold)), 1 ether, 1);
        // Moving spot the other way immediately tightens the depth, even while the TWAP stays unchanged.
        goldHook.setState(uint160(2 << 96), 100 ether);
        assertApproxEqAbs(oracle.payoutCap(address(gold)), 0.5 ether, 1);
    }

    function testPolAndGenesisUseOppositeQuotesAndBothRespectPauses() public {
        goldHook.setTicks(-1000, 0);
        uint256 genesisQuote = oracle.tokensForEth(address(gold), 1 ether);
        uint256 polQuote = oracle.polTokensForEth(1 ether);
        assertLt(genesisQuote, polQuote);
        assertEq(polQuote, 1 ether);
        goldHook.setTicks(0, -1000);
        assertEq(oracle.tokensForEth(address(gold), 1 ether), genesisQuote);
        assertEq(oracle.polTokensForEth(1 ether), polQuote);
        oracle.setTokenPaused(address(gold), true);
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.PausedToken.selector, address(gold)));
        oracle.polTokensForEth(1 ether);
    }
}
