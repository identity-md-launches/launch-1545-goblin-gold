// Adapted from audit 930ea061, published 2026-10-14. See README.md for provenance.
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {PoolManager} from "test/v4-core/PoolManager.sol";
import {IPoolManager} from "test/v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "test/v4-core/interfaces/IHooks.sol";
import {Currency} from "test/v4-core/types/Currency.sol";
import {PoolKey as CoreKey} from "test/v4-core/types/PoolKey.sol";
import {SwapParams as CoreSwap, ModifyLiquidityParams as CoreModify} from "test/v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "test/v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "test/v4-core/test/PoolModifyLiquidityTest.sol";
import {GoldHook} from "src/GoldHook.sol";
import {TwapOracle} from "src/TwapOracle.sol";

contract ScratchGold is ERC20 {
    constructor() ERC20("GOLD", "GOLD") {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

contract ScratchV3Factory {
    function getPool(address, address, uint24) external pure returns (address) {
        return address(0);
    }
}

/// @notice The genesis depth (`TwapOracle._checkGenesisPool` / `genesisEthHeld`) converts the pool's *active*
///         liquidity into ETH as if every unit of it were a full-range position. A narrow position (one tick spacing
///         wide) carries roughly 330x the liquidity per ETH of a full-range one, so 1 ETH parked in a 120-tick range
///         for 30 minutes makes the oracle report hundreds of ETH of depth and lifts the 5% payout cap accordingly.
///         The same trick makes a pool below MIN_GENESIS_DEPTH priceable.
contract ConcentratedDepthTest is Test {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    address constant HOOK_ADDRESS = address((uint160(0x4A) << 152) | 0x38CC);
    address factoryEOA = address(0xFAC7);
    address attacker = address(0xA77);

    PoolManager manager;
    ScratchGold gold;
    GoldHook hook;
    TwapOracle oracle;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;
    CoreKey key;

    receive() external payable {}

    function setUp() public {
        vm.warp(1_800_000_000);
        manager = new PoolManager(address(this));
        gold = new ScratchGold();
        GoldHook impl = new GoldHook(address(manager), address(gold), factoryEOA);
        vm.etch(HOOK_ADDRESS, address(impl).code);
        hook = GoldHook(payable(HOOK_ADDRESS));
        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));
        key = CoreKey(Currency.wrap(address(0)), Currency.wrap(address(gold)), 12500, 60, IHooks(HOOK_ADDRESS));
        oracle = new TwapOracle(
            address(this), address(0x1111), address(new ScratchV3Factory()), address(gold), HOOK_ADDRESS
        );
        vm.deal(address(this), 10_000 ether);
        vm.deal(attacker, 10 ether);
        vm.prank(factoryEOA);
        manager.initialize(key, SQRT_PRICE_1_1);
    }

    /// @dev Returns false when the PoolManager (hook) refuses the position: a fix that only admits full-range
    ///      positions makes the attacker's add revert, which is the fixed behaviour.
    function _addLiquidity(address who, int24 lower, int24 upper, int256 liquidity, uint256 eth, uint256 tokens)
        internal
        returns (bool ok)
    {
        gold.mint(who, tokens);
        vm.startPrank(who);
        gold.approve(address(lpRouter), tokens);
        try lpRouter.modifyLiquidity{value: eth}(key, CoreModify(lower, upper, liquidity, bytes32(0)), "") {
            ok = true;
        } catch {
            ok = false;
        }
        vm.stopPrank();
    }

    function _tinySwap(bool zeroForOne) internal {
        uint160 limit = zeroForOne ? 4295128739 + 1 : 1461446703485210103287273052203988822378723970342 - 1;
        if (!zeroForOne) {
            gold.mint(address(this), 1 ether);
            gold.approve(address(swapRouter), type(uint256).max);
        }
        swapRouter.swap{value: zeroForOne ? 0.0001 ether : 0}(
            key, CoreSwap(zeroForOne, -0.0001 ether, limit), PoolSwapTest.TestSettings(false, false), ""
        );
    }

    /// @dev Honest launch: 2 ETH + 2 GOLD of full-range liquidity (L = 2e18 at 1:1), history older than 4 hours.
    function _honestPool() internal {
        assertTrue(_addLiquidity(address(this), -887220, 887220, 2e18, 2 ether + 1, 2 ether + 1));
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _tinySwap(true);
        vm.warp(vm.getBlockTimestamp() + 4 hours);
        _tinySwap(false);
    }

    function testNarrowPositionInflatesGenesisDepthAndPayoutCap() public {
        _honestPool();
        uint256 honestCap = oracle.payoutCap(address(gold));
        assertApproxEqRel(honestCap, 0.1 ether, 0.02e18, "5% of 2 ETH of full-range depth");

        // Attacker: ~1 ETH + ~1 GOLD in the 120-tick range around the price, liquidity 333e18 (vs 2e18 honest).
        (, int24 tick) = hook.slot0();
        int24 lower = (tick / 60) * 60 - 60;
        assertFalse(_addLiquidity(attacker, lower, lower + 120, 333e18, 1.5 ether, 1.5 ether), "narrow add refused");
        assertEq(oracle.payoutCap(address(gold)), honestCap);
    }

    function testNarrowPositionMakesAPoolBelowMinimumDepthPriceable() public {
        // only 0.5 ETH of full-range depth: below MIN_GENESIS_DEPTH, GOLD must stay unpriceable
        assertTrue(_addLiquidity(address(this), -887220, 887220, 0.5e18, 0.5 ether + 1, 0.5 ether + 1));
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _tinySwap(true);
        vm.warp(vm.getBlockTimestamp() + 4 hours);
        _tinySwap(false);
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, HOOK_ADDRESS));
        oracle.valueInEth(address(gold), 1e18);

        // 0.02 ETH in a 120-tick range is enough liquidity to clear the 1 ETH bound
        (, int24 tick) = hook.slot0();
        int24 lower = (tick / 60) * 60 - 60;
        assertFalse(_addLiquidity(attacker, lower, lower + 120, 5e18, 0.1 ether, 0.1 ether), "narrow add refused");
        // Expected: still ThinPool (the pool holds ~0.55 ETH). Actual: priced, depth reported above 1 ETH.
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, HOOK_ADDRESS));
        oracle.valueInEth(address(gold), 1e18);
    }
}
