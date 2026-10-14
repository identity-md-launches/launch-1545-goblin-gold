// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {GoldHook} from "../../src/GoldHook.sol";
import {POLManager} from "../../src/POLManager.sol";
import {TwapOracle} from "../../src/TwapOracle.sol";
import {GoblinNFT} from "../../src/GoblinNFT.sol";
import {IPoolManagerMinimal, PoolKey, SwapParams, ModifyLiquidityParams, V4Lib} from "../../src/v4/V4Minimal.sol";
import {MockERC20, MockOracle} from "../mocks/Mocks.sol";

/// @dev Minimal unlock router against the live PoolManager: seeds full-range liquidity and swaps exact-input ETH.
contract ForkRouter {
    IPoolManagerMinimal immutable pm;
    MockERC20 immutable gold;

    constructor(address pm_, MockERC20 gold_) {
        pm = IPoolManagerMinimal(pm_);
        gold = gold_;
    }

    receive() external payable {}

    function seed(PoolKey memory key, int256 liquidity) external payable {
        pm.unlock(abi.encode(uint8(0), key, liquidity));
    }

    function buy(PoolKey memory key, uint256 ethIn) external payable {
        pm.unlock(abi.encode(uint8(1), key, int256(ethIn)));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm));
        (uint8 action, PoolKey memory key, int256 amount) = abi.decode(data, (uint8, PoolKey, int256));
        int256 delta;
        if (action == 0) {
            (delta,) = pm.modifyLiquidity(key, ModifyLiquidityParams(-887220, 887220, amount, bytes32(0)), "");
        } else {
            delta = pm.swap(key, SwapParams(true, -amount, V4Lib.MIN_SQRT_PRICE + 1), "");
        }
        int128 a0 = V4Lib.amount0(delta);
        int128 a1 = V4Lib.amount1(delta);
        if (a0 < 0) pm.settle{value: uint256(uint128(-a0))}();
        if (a1 < 0) {
            pm.sync(address(gold));
            gold.mint(address(pm), uint256(uint128(-a1)));
            pm.settle();
        }
        if (a1 > 0) pm.take(address(gold), address(this), uint256(uint128(a1)));
        return "";
    }
}

/// @notice Opt in with `forge test --fork-url URL --match-path test/fork/MainnetV4Fork.t.sol`. Uses the live Uniswap
///         v4 PoolManager and the deployed GoblinNFT; the hook is etched at a flagged address. No broadcast.
contract MainnetV4ForkTest is Test {
    address constant POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address constant NFT = 0xC5d5F314da6d4a433F9BF897a2cC24A537576cB1;
    address constant HOOK_ADDRESS = address((uint160(0x4A) << 152) | 0x30CC);
    address factoryEOA = address(0xFAC7);

    MockERC20 gold;
    GoldHook hook;
    ForkRouter router;
    PoolKey key;

    function setUp() public {
        if (block.chainid != 1) vm.skip(true);
        assertGt(POOL_MANAGER.code.length, 0, "PoolManager absent on fork");
        assertGt(NFT.code.length, 0, "GoblinNFT absent on fork");
        gold = new MockERC20("GOLD");
        GoldHook impl = new GoldHook(POOL_MANAGER, address(gold), factoryEOA);
        vm.etch(HOOK_ADDRESS, address(impl).code);
        hook = GoldHook(payable(HOOK_ADDRESS));
        router = new ForkRouter(POOL_MANAGER, gold);
        key = PoolKey(address(0), address(gold), 12500, 60, HOOK_ADDRESS);
        vm.deal(address(this), 1000 ether);
    }

    function testLivePoolManagerInitializeSwapFeeAndFlushToDeployedNFT() public {
        vm.expectRevert();
        IPoolManagerMinimal(POOL_MANAGER).initialize(key, 1 << 96); // not the factory
        vm.prank(factoryEOA);
        IPoolManagerMinimal(POOL_MANAGER).initialize(key, 1 << 96);
        assertTrue(hook.initialized());
        router.seed{value: 100 ether}(key, 100e18);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        router.buy{value: 1 ether}(key, 1 ether);
        assertEq(hook.holderAccrued(), 0.005 ether);
        assertEq(hook.reserveAccrued(), 0.005 ether);
        assertEq(IPoolManagerMinimal(POOL_MANAGER).balanceOf(HOOK_ADDRESS, 0), 0.01 ether);
        uint256 deferredBefore = GoblinNFT(NFT).deferredRevenue();
        hook.flush();
        assertEq(GoblinNFT(NFT).deferredRevenue() - deferredBefore, 0.005 ether);
        assertEq(hook.reserveAccrued(), 0.005 ether, "reserve share waits for bindGacha");

        // POLManager through the live PoolManager; the stand-in oracle quotes the pool's own spot price, so the
        // v3.2 floor (TWAP quote net of 1.25% + 1% fees and 3% impact) is exercised for real
        MockOracle o = new MockOracle();
        o.set(address(gold), _ethPerGold());
        POLManager pol = new POLManager(POOL_MANAGER, address(gold), HOOK_ADDRESS, address(o), NFT);
        assertEq(pol.MIN_OUT_BPS(), 9475);
        pol.depositPOL{value: 1 ether}();
        pol.depositBurn{value: 0.5 ether}();
        uint128 before = hook.liquidity();
        assertGt(pol.addLiquidity(1 ether), 0);
        assertGt(hook.liquidity(), before);
        o.set(address(gold), _ethPerGold());
        assertGt(pol.buyAndBurn(0.5 ether), 0.4 ether);
        // a second add after fees accrued on the position settles the positive fee delta (finding 2)
        router.buy{value: 1 ether}(key, 1 ether);
        o.set(address(gold), _ethPerGold());
        pol.depositPOL{value: 0.01 ether}();
        assertGt(pol.addLiquidity(0.001 ether), 0);

        // genesis pricing from the hook ring after a 4-hour history
        vm.warp(vm.getBlockTimestamp() + 4 hours);
        router.buy{value: 0.01 ether}(key, 0.01 ether);
        TwapOracle oracle = new TwapOracle(
            address(this),
            0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,
            0x1F98431c8aD98523631AE4a59f267346ea31F984,
            address(gold),
            HOOK_ADDRESS
        );
        uint256 v = oracle.valueInEth(address(gold), 1 ether);
        assertGt(v, 0.9 ether);
        assertLt(v, 1.2 ether);
        // v3.2: the genesis depth follows the liquidity recorded 30 minutes ago, so a JIT add changes no cap
        uint256 cap = oracle.payoutCap(address(gold));
        router.seed{value: 600 ether}(key, 500e18); // the price moved: 500e18 of liquidity needs over 500 ETH
        assertEq(oracle.payoutCap(address(gold)), cap);
    }

    /// @dev ETH per GOLD at the pool's spot price (ETH is currency0): 2^192 / sqrtP^2, 1e18-scaled.
    function _ethPerGold() internal view returns (uint256) {
        (uint160 sqrtP,) = hook.slot0();
        return Math.mulDiv(1 << 192, 1e18, uint256(sqrtP) * sqrtP);
    }
}
