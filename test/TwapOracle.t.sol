// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {TwapOracle} from "../src/TwapOracle.sol";
import {MockERC20} from "./mocks/Mocks.sol";
import {MockV3Factory, MockV3Pool} from "./mocks/CuratorMocks.sol";

contract TwapOracleTest is Test {
    TwapOracle oracle;
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
        oracle = new TwapOracle(address(this), address(weth), address(factory));
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
        weth.transfer(address(this), 50 ether + 1);
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, address(pool)));
        oracle.setPool(address(token), address(pool));
        weth.mint(address(pool), 1);
        oracle.setPool(address(token), address(pool));
        vm.prank(address(pool));
        token.transfer(address(this), 50 ether + 1);
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, address(pool)));
        oracle.valueInEth(address(token), 1 ether);
        token.mint(address(pool), 1);
        pool.setNoHistory(true);
        vm.expectRevert(bytes("OLD"));
        oracle.valueInEth(address(token), 1 ether);
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
        pool.setLiquidity(49 ether);
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, address(pool)));
        oracle.setPool(address(token), address(pool));
        pool.setLiquidity(0);
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, address(pool)));
        oracle.setPool(address(token), address(pool));
        pool.setLiquidity(50 ether);
        oracle.setPool(address(token), address(pool));
    }

    function testFuzzFiftyEthBoundary(uint256 left) public {
        left = bound(left, 1, 100 ether);
        vm.prank(address(pool));
        weth.transfer(address(this), 100 ether - left);
        if (left < 50 ether) vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, address(pool)));
        oracle.setPool(address(token), address(pool));
        if (left >= 50 ether) assertEq(oracle.valueInEth(address(token), 1 ether), 1 ether);
    }
}
