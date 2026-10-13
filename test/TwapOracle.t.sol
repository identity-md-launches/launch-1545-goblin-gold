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

    function testInsufficientWETHSideAndTokenSideAndMissingHistory() public {
        vm.prank(address(pool));
        weth.transfer(address(this), 95 ether + 1);
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, address(pool)));
        oracle.setPool(address(token), address(pool));
        weth.mint(address(pool), 1);
        oracle.setPool(address(token), address(pool));
        vm.prank(address(pool));
        token.transfer(address(this), 95 ether + 1);
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, address(pool)));
        oracle.valueInEth(address(token), 1 ether);
        token.mint(address(pool), 1);
        pool.setNoHistory(true);
        vm.expectRevert(bytes("OLD"));
        oracle.valueInEth(address(token), 1 ether);
    }

    /// @dev v3.1 boundaries: a regular v3 pool needs 5 ETH per side (4.99 fails, 5 passes).
    function testRegularPoolFiveEthBoundary() public {
        assertEq(oracle.MIN_LIQUIDITY(), 5 ether);
        vm.prank(address(pool));
        weth.transfer(address(this), 100 ether - 4.99 ether);
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, address(pool)));
        oracle.setPool(address(token), address(pool));
        weth.mint(address(pool), 0.01 ether); // exactly 5 ETH
        oracle.setPool(address(token), address(pool));
        assertEq(oracle.valueInEth(address(token), 1 ether), 1 ether);
        // the token side is bounded the same way: 4.99 ETH worth of token at the TWAP fails, 5 passes
        vm.prank(address(pool));
        token.transfer(address(this), 100 ether - 4.99 ether);
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, address(pool)));
        oracle.valueInEth(address(token), 1 ether);
        token.mint(address(pool), 0.01 ether);
        assertEq(oracle.valueInEth(address(token), 1 ether), 1 ether);
        // active liquidity, not balances, bounds the depth
        pool.setLiquidity(4.99 ether);
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, address(pool)));
        oracle.valueInEth(address(token), 1 ether);
        pool.setLiquidity(5 ether);
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
        goldHook.setState(uint160(1 << 96), 1 ether);
        assertEq(oracle.valueInEth(address(gold), 1 ether), 1 ether);
        assertEq(oracle.tokensForEth(address(gold), 1 ether), 1 ether);
        // the bound is on the ETH side: at a price of 4 GOLD per ETH, liquidity 2e18 holds 1 ETH and 4 GOLD
        goldHook.setState(uint160(2 << 96), 2 ether);
        goldHook.setTicks(13863, 13863); // tick of price 4 (1.0001^13863 ~= 4)
        assertEq(oracle.payoutCap(address(gold)), 0.05 ether);
        goldHook.setState(uint160(2 << 96), 2 ether - 2);
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, address(goldHook)));
        oracle.valueInEth(address(gold), 1 ether);
        goldHook.setState(uint160(1 << 96), 0);
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, address(goldHook)));
        oracle.valueInEth(address(gold), 1 ether);
    }

    /// @dev The payout cap is 5% of the pool's current ETH-side depth, for regular and genesis pools alike; WETH is
    ///      uncapped. The value returned beside it is the plain TWAP value.
    function testPayoutCapIsFivePercentOfEthSideDepth() public {
        assertEq(oracle.PAYOUT_CAP_BPS(), 500);
        oracle.setPool(address(token), address(pool));
        (uint256 v, uint256 cap) = oracle.valueAndCap(address(token), 3 ether);
        assertEq(v, 3 ether);
        assertEq(cap, 5 ether); // 100 ETH of WETH in the pool
        assertEq(oracle.payoutCap(address(token)), 5 ether);
        // the depth is min(WETH balance, active virtual reserve)
        pool.setLiquidity(20 ether);
        assertEq(oracle.payoutCap(address(token)), 1 ether);
        pool.setLiquidity(100 ether);
        vm.prank(address(pool));
        weth.transfer(address(this), 90 ether);
        assertEq(oracle.payoutCap(address(token)), 0.5 ether);
        // genesis: 5% of L * 2^96 / sqrtP
        (v, cap) = oracle.valueAndCap(address(gold), 2 ether);
        assertEq(v, 2 ether);
        assertEq(cap, 5 ether);
        goldHook.setState(uint160(1 << 96), 7 ether);
        assertEq(oracle.payoutCap(address(gold)), 0.35 ether);
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
        pool.setLiquidity(5 ether);
        oracle.setPool(address(token), address(pool));
    }

    function testFuzzFiveEthBoundary(uint256 left) public {
        left = bound(left, 1, 10 ether);
        vm.prank(address(pool));
        weth.transfer(address(this), 100 ether - left);
        if (left < 5 ether) vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, address(pool)));
        oracle.setPool(address(token), address(pool));
        if (left >= 5 ether) {
            assertEq(oracle.valueInEth(address(token), 1 ether), 1 ether);
            assertEq(oracle.payoutCap(address(token)), left / 20);
        }
    }

    function testFuzzGenesisOneEthBoundary(uint128 liquidity) public {
        liquidity = uint128(bound(liquidity, 1, 3 ether));
        goldHook.setState(uint160(1 << 96), liquidity);
        if (liquidity < 1 ether) {
            vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, address(goldHook)));
            oracle.valueInEth(address(gold), 1 ether);
        } else {
            assertEq(oracle.valueInEth(address(gold), 1 ether), 1 ether);
            assertEq(oracle.payoutCap(address(gold)), uint256(liquidity) / 20);
        }
    }
}
