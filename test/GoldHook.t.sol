// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {V4Fixture, GoldHookHarness} from "./mocks/V4Fixture.sol";
import {GoldHook} from "../src/GoldHook.sol";
import {BagGacha} from "../src/BagGacha.sol";
import {GenesisVault} from "../src/GenesisVault.sol";
import {TwapOracle} from "../src/TwapOracle.sol";
import {POLManager} from "../src/POLManager.sol";
import {PoolKey as MinKey} from "../src/v4/V4Minimal.sol";
import {MockERC20, MockOracle, MockVRFWrapper, MockPOL} from "./mocks/Mocks.sol";
import {MockV3Factory} from "./mocks/CuratorMocks.sol";
import {IHooks} from "./v4-core/interfaces/IHooks.sol";
import {Currency} from "./v4-core/types/Currency.sol";
import {PoolKey as CoreKey} from "./v4-core/types/PoolKey.sol";
import {ModifyLiquidityParams as CoreModify} from "./v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "./v4-core/types/BalanceDelta.sol";
import {Hooks} from "./v4-core/libraries/Hooks.sol";

contract GoldHookTest is V4Fixture {
    MockOracle polOracle;
    MockERC20 weth;
    TwapOracle oracle;
    GenesisVault genesis;
    BagGacha gacha;
    POLManager pol;

    function setUp() public {
        _deployV4(keccak256(type(BagGacha).runtimeCode));
        _initialize();
        _seed(100 ether, 100 ether, 100e18);
        polOracle = new MockOracle();
        polOracle.set(address(gold), 1e18);
        weth = new MockERC20("WETH");
        oracle = new TwapOracle(address(this), address(weth), address(new MockV3Factory()), address(gold), HOOK_ADDRESS);
        MockVRFWrapper vrf = new MockVRFWrapper();
        MockPOL mockPol = new MockPOL();
        address predictedGacha = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        genesis = new GenesisVault(
            address(gold), address(oracle), predictedGacha, vm.getBlockTimestamp(), 1e24, 1e22, address(this)
        );
        gacha = new BagGacha(
            address(oracle),
            address(genesis),
            NFT_ADDRESS,
            address(vrf),
            address(mockPol),
            address(this),
            vm.getBlockTimestamp(),
            address(this)
        );
        assertEq(address(gacha), predictedGacha);
        pol = new POLManager(address(manager), address(gold), HOOK_ADDRESS, address(polOracle), NFT_ADDRESS);
    }

    // ------------------------------------------------------------------ initialization

    function testInitializeOnlyByFactoryOnlyPlatformPoolOnlyOnce() public {
        GoldHookHarness other = new GoldHookHarness(address(manager), address(gold), factoryEOA, bytes32(0));
        address otherAddr = address((uint160(0x4B) << 152) | 0x30CC);
        vm.etch(otherAddr, address(other).code);
        CoreKey memory k =
            CoreKey(Currency.wrap(address(0)), Currency.wrap(address(gold)), 12500, 60, IHooks(otherAddr));
        vm.expectRevert(); // wrapped by the PoolManager: OnlyFactory
        manager.initialize(k, SQRT_PRICE_1_1);
        k.fee = 3000;
        vm.prank(factoryEOA);
        vm.expectRevert(); // WrongPool
        manager.initialize(k, SQRT_PRICE_1_1);
        k.fee = 12500;
        k.tickSpacing = 10;
        vm.prank(factoryEOA);
        vm.expectRevert();
        manager.initialize(k, SQRT_PRICE_1_1);
        k.tickSpacing = 60;
        vm.prank(factoryEOA);
        manager.initialize(k, SQRT_PRICE_1_1);
        assertTrue(GoldHook(payable(otherAddr)).initialized());
        assertEq(GoldHook(payable(otherAddr)).launchedAt(), vm.getBlockTimestamp());
        // a second pool with a different fee cannot reuse the hook
        k.fee = 3000;
        vm.prank(factoryEOA);
        vm.expectRevert();
        manager.initialize(k, SQRT_PRICE_1_1);
        // hook entry points are PoolManager-only
        vm.expectRevert(GoldHook.OnlyPoolManager.selector);
        hook.afterInitialize(address(this), MinKey(address(0), address(gold), 12500, 60, HOOK_ADDRESS), 0, 0);
        vm.expectRevert(GoldHook.OnlyPoolManager.selector);
        hook.unlockCallback("");
        vm.expectRevert(GoldHook.UnexpectedSender.selector);
        payable(HOOK_ADDRESS).transfer(1 wei);
    }

    function testConstructorRejectsZeroAndFlagsAreTheRequiredSet() public {
        vm.expectRevert(GoldHook.BadConfig.selector);
        new GoldHook(address(0), address(gold), factoryEOA);
        assertEq(hook.REQUIRED_FLAGS(), uint160(0x30CC));
        assertEq(
            hook.REQUIRED_FLAGS(),
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
        );
        assertFalse(
            GoldHook(payable(address(new GoldHook(address(manager), address(gold), factoryEOA)))).hasRequiredFlags()
        );
    }

    // ------------------------------------------------------------------ fees and anti-snipe tax

    function testExactInputBuyPaysFeeAndLaunchTaxOnTheEthInput() public {
        uint256 before = trader.balance;
        BalanceDelta d = _swap(trader, true, -0.1 ether);
        assertEq(before - trader.balance, 0.1 ether, "swapper pays exactly the specified input");
        assertEq(d.amount0(), -0.1 ether);
        // 1% fee + 90% tax on 0.1 ETH: 0.001 + 0.09; only 0.009 ETH reached the pool
        assertEq(hook.holderAccrued(), 0.0005 ether);
        assertEq(hook.reserveAccrued(), 0.0905 ether);
        assertEq(manager.balanceOf(HOOK_ADDRESS, 0), 0.091 ether);
        assertLt(uint256(uint128(d.amount1())), 0.0095 ether);
        assertGt(uint256(uint128(d.amount1())), 0.0085 ether);
        assertEq(hook.buyTaxBps(), 9000);
    }

    function testTaxScheduleAndBuyCap() public {
        vm.expectRevert();
        _swap(trader, true, -(0.5 ether + 1));
        _swap(trader, true, -0.5 ether);
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        assertEq(hook.buyTaxBps(), 5000);
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        assertEq(hook.buyTaxBps(), 2500);
        uint256 r = hook.reserveAccrued();
        _swap(trader, true, -0.4 ether);
        assertEq(hook.reserveAccrued() - r, 0.1 ether + 0.002 ether);
        vm.warp(vm.getBlockTimestamp() + 10 minutes);
        assertEq(hook.buyTaxBps(), 0);
        vm.expectRevert(); // still inside the first hour
        _swap(trader, true, -0.6 ether);
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        r = hook.reserveAccrued();
        uint256 h = hook.holderAccrued();
        _swap(trader, true, -2 ether);
        assertEq(hook.reserveAccrued() - r, 0.01 ether);
        assertEq(hook.holderAccrued() - h, 0.01 ether);
    }

    /// @dev Finding 7: the 1% fee and the tax are shares of the gross amount paid, exactly as for an exact-input buy:
    ///      gross = ethIn / (1 - 1% - tax), fee = 1% of gross, tax = gross - fee - ethIn.
    function testExactOutputBuyChargesFeeAndTaxOnTopOfTheEthConsumed() public {
        vm.warp(vm.getBlockTimestamp() + 10 minutes); // 50% tax
        uint256 before = trader.balance;
        BalanceDelta d = _swap(trader, true, 0.01 ether);
        assertEq(d.amount1(), 0.01 ether);
        uint256 paid = before - trader.balance;
        uint256 total = uint256(uint128(-d.amount0()));
        uint256 charged = hook.holderAccrued() + hook.reserveAccrued();
        assertEq(paid, total);
        uint256 ethIn = total - charged; // what the pool consumed
        uint256 gross = (ethIn * 10_000) / (10_000 - 100 - 5000);
        uint256 fee = (gross * 100) / 10_000;
        assertEq(total, gross, "swapper pays the gross amount");
        assertEq(hook.holderAccrued(), fee / 2, "fee is 1% of gross");
        assertEq(hook.reserveAccrued(), fee - fee / 2 + (gross - fee - ethIn), "tax is the rest of gross");
        assertApproxEqAbs(gross - fee - ethIn, gross / 2, 2, "tax is 50% of gross");
        assertLe(total, 0.5 ether);
    }

    function testSellsPayOnePercentOfEthOutAndNoTax() public {
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        uint256 before = trader.balance;
        BalanceDelta d = _swap(trader, false, -1 ether);
        uint256 got = trader.balance - before;
        uint256 charged = hook.holderAccrued() + hook.reserveAccrued();
        assertEq(hook.holderAccrued(), charged / 2);
        assertEq(uint256(uint128(d.amount0())), got);
        assertEq(charged, ((got + charged) * 100) / 10_000);
        // exact-output sell: the swapper receives exactly the requested ETH and pays the fee in extra tokens
        uint256 b2 = trader.balance;
        uint256 c2 = hook.holderAccrued() + hook.reserveAccrued();
        _swap(trader, false, 0.5 ether);
        assertEq(trader.balance - b2, 0.5 ether);
        assertEq(hook.holderAccrued() + hook.reserveAccrued() - c2, 0.005 ether);
    }

    function testExactOutputBuyCapCountsFeeAndTax() public {
        vm.expectRevert(); // 0.06 ETH out needs 0.6 ETH under the 90% tax
        _swap(trader, true, 0.06 ether);
    }

    // ------------------------------------------------------------------ bind and flush

    function testFlushBeforeBindPaysHoldersOnlyAndBindRequiresPinnedCode() public {
        _swap(trader, true, -0.1 ether);
        hook.flush();
        assertEq(nft.deferredRevenue(), 0.0005 ether);
        assertEq(hook.holderAccrued(), 0);
        assertEq(hook.reserveAccrued(), 0.0905 ether);
        assertEq(manager.balanceOf(HOOK_ADDRESS, 0), 0.0905 ether);
        vm.expectRevert(GoldHook.NothingToFlush.selector);
        hook.flush();

        vm.expectRevert(GoldHook.CodeMismatch.selector);
        hook.bindGacha(address(pol));
        // right code, but not the gacha the NFT owner named (nothing named yet)
        vm.expectRevert(GoldHook.NotLaunchTarget.selector);
        hook.bindGacha(address(gacha));
        nft.setLaunchTargets(address(gacha.polManager()), address(gacha), address(gacha));
        vm.expectRevert(GoldHook.ReviewPending.selector);
        hook.bindGacha(address(gacha));
        vm.warp(vm.getBlockTimestamp() + 7 days - 1);
        vm.expectRevert(GoldHook.ReviewPending.selector);
        hook.bindGacha(address(gacha));
        vm.warp(vm.getBlockTimestamp() + 1);

        gold.mint(HOOK_ADDRESS, 1e24); // launch remainder parked in the hook
        hook.bindGacha(address(gacha));
        assertEq(hook.gacha(), address(gacha));
        assertEq(gold.balanceOf(address(genesis)), 1e24);
        assertEq(gold.balanceOf(HOOK_ADDRESS), 0);
        vm.expectRevert(GoldHook.AlreadyBound.selector);
        hook.bindGacha(address(gacha));

        hook.flush();
        assertEq(gacha.reserve(), 0.0905 ether);
        assertEq(hook.reserveAccrued(), 0);
        assertEq(manager.balanceOf(HOOK_ADDRESS, 0), 0);
        assertEq(hook.totalFlushedToReserve(), 0.0905 ether);
        assertEq(hook.totalFlushedToHolders(), 0.0005 ether);
        assertEq(HOOK_ADDRESS.balance, 0);
    }

    function testPinnedGachaRuntimeCodeHash() public {
        bytes32 actual = keccak256(type(BagGacha).runtimeCode);
        emit log_named_bytes32("BagGacha runtime code hash (this build)", actual);
        if (actual != hook.GACHA_RUNTIME_CODE_HASH()) {
            emit log("constant differs: expected only outside the FOUNDRY_VIA_IR=false FOUNDRY_BYTECODE_HASH=none profile");
            return;
        }
        GoldHook plain = new GoldHook(address(manager), address(gold), factoryEOA);
        assertEq(plain.gachaRuntimeCodeHash(), actual);
        assertEq(address(gacha).codehash, actual);
    }

    // ------------------------------------------------------------------ observations and genesis pricing

    function testObserveTracksTickCumulativeAndTwapOraclePricesGenesisFromHook() public {
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _swap(trader, true, -1 ether);
        vm.warp(vm.getBlockTimestamp() + 4 hours);
        _swap(trader, false, -1 ether);
        uint32[] memory agos = new uint32[](3);
        agos[0] = 30 minutes;
        agos[1] = 4 hours;
        int56[] memory c = hook.observe(agos);
        (, int24 tick) = hook.slot0();
        // the tick moved slightly below zero after the buy/sell round trip; cumulative is monotone in time
        assertLt(c[2] - c[0], 0);
        assertLt(tick, 50);
        assertGt(tick, -200);
        // buying GOLD pushed the tick below zero: GOLD per ETH fell, so one GOLD is worth slightly more than 1 ETH
        uint256 v = oracle.valueInEth(address(gold), 1 ether);
        assertGt(v, 1 ether);
        assertLt(v, 1.05 ether);
        assertLe(oracle.tokensForEth(address(gold), 1 ether), 1 ether);
        assertTrue(oracle.isPriced(address(gold)));
        // genesis quotes come from the hook: a v3 pool can never be set for GOLD
        vm.expectRevert(TwapOracle.PoolMismatch.selector);
        oracle.setPool(address(gold), address(1));
        agos = new uint32[](1);
        agos[0] = 10 hours;
        vm.expectRevert(GoldHook.OldObservation.selector);
        hook.observe(agos);
    }

    function testGenesisPricingStaleAndThinChecks() public {
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _swap(trader, false, -1 ether); // records the seeded liquidity
        vm.warp(vm.getBlockTimestamp() + 4 hours);
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.StalePool.selector, HOOK_ADDRESS));
        oracle.valueInEth(address(gold), 1 ether);
        _swap(trader, false, -1 ether);
        oracle.valueInEth(address(gold), 1 ether);
        // thin pool: a second hook/pool with no active liquidity fails the depth bound
        GoldHookHarness thinImpl = new GoldHookHarness(address(manager), address(gold), factoryEOA, bytes32(0));
        address thinAddr = address((uint160(0x4C) << 152) | 0x30CC);
        vm.etch(thinAddr, address(thinImpl).code);
        CoreKey memory thinKey =
            CoreKey(Currency.wrap(address(0)), Currency.wrap(address(gold)), 12500, 60, IHooks(thinAddr));
        vm.prank(factoryEOA);
        manager.initialize(thinKey, SQRT_PRICE_1_1);
        TwapOracle thinOracle =
            new TwapOracle(address(this), address(weth), address(new MockV3Factory()), address(gold), thinAddr);
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, thinAddr));
        thinOracle.valueInEth(address(gold), 1 ether);
        // paused genesis token
        oracle.setTokenPaused(address(gold), true);
        assertFalse(oracle.isPriced(address(gold)));
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.PausedToken.selector, address(gold)));
        oracle.valueInEth(address(gold), 1 ether);
    }

    /// @dev v3.1 boundary on the real PoolManager: the genesis pool needs an ETH-side depth of 1 ETH. At price 1:1 a
    ///      full-range position of liquidity L holds L wei of ETH, so 0.99e18 fails and 1e18 passes; the payout cap
    ///      is 5% of that depth.
    function testGenesisOneEthDepthBoundaryAndPayoutCapOnRealPool() public {
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _swap(trader, true, -0.001 ether); // main pool: records the seeded liquidity
        GoldHookHarness thinImpl = new GoldHookHarness(address(manager), address(gold), factoryEOA, bytes32(0));
        address thinAddr = address((uint160(0x4D) << 152) | 0x30CC);
        vm.etch(thinAddr, address(thinImpl).code);
        CoreKey memory thinKey =
            CoreKey(Currency.wrap(address(0)), Currency.wrap(address(gold)), 12500, 60, IHooks(thinAddr));
        vm.prank(factoryEOA);
        manager.initialize(thinKey, SQRT_PRICE_1_1);
        gold.mint(address(this), 10 ether);
        gold.approve(address(lpRouter), 10 ether);
        lpRouter.modifyLiquidity{value: 1 ether}(thinKey, CoreModify(-887220, 887220, 0.99e18, bytes32(0)), "");
        TwapOracle thinOracle =
            new TwapOracle(address(this), address(weth), address(new MockV3Factory()), address(gold), thinAddr);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.prank(trader);
        swapRouter.swap{value: 1e12}(thinKey, _coreSwap(true, -1e12), _settings(), ""); // records 0.99e18
        vm.warp(vm.getBlockTimestamp() + 4 hours);
        // a dust buy refreshes the observation; buying adds ETH, so it cannot lift 0.99 ETH over the bound
        vm.prank(trader);
        swapRouter.swap{value: 1e12}(thinKey, _coreSwap(true, -1e12), _settings(), "");
        assertEq(GoldHook(payable(thinAddr)).liquidity(), 0.99e18);
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, thinAddr));
        thinOracle.valueInEth(address(gold), 1 ether);
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, thinAddr));
        thinOracle.payoutCap(address(gold));
        lpRouter.modifyLiquidity{value: 0.1 ether}(thinKey, CoreModify(-887220, 887220, 0.01e18, bytes32(0)), "");
        assertEq(GoldHook(payable(thinAddr)).liquidity(), 1e18);
        // v3.2: the added liquidity counts only once an observation at least 30 minutes old has recorded it
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, thinAddr));
        thinOracle.valueInEth(address(gold), 1 ether);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(trader);
        swapRouter.swap{value: 1e12}(thinKey, _coreSwap(true, -1e12), _settings(), ""); // records 1e18
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        assertEq(GoldHook(payable(thinAddr)).liquidityAt(30 minutes), 1e18);
        uint256 v = thinOracle.valueInEth(address(gold), 1 ether);
        assertApproxEqRel(v, 1 ether, 0.001e18);
        (uint256 value, uint256 cap) = thinOracle.valueAndCap(address(gold), 0.5 ether);
        assertEq(value, v / 2);
        assertApproxEqRel(cap, 0.05 ether, 0.001e18);
        assertGe(cap, 0.05 ether, "the dust buy left slightly more than 1 ETH in the pool");
        assertEq(thinOracle.payoutCap(address(gold)), cap);
        // the main pool: 100 ETH of depth caps a single GOLD payout at about 5 ETH
        _swap(trader, true, -0.001 ether); // fresh observation
        assertApproxEqRel(oracle.payoutCap(address(gold)), 5 ether, 0.01e18);
    }

    // ------------------------------------------------------------------ POLManager through the PoolManager

    function testPOLManagerBuyAndBurnAndFullRangeLiquidityHeldForever() public {
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        pol.depositBurn{value: 1 ether}();
        pol.depositPOL{value: 2 ether}();
        uint256 deadBefore = gold.balanceOf(pol.DEAD());
        uint256 out = pol.buyAndBurn(0.5 ether);
        assertEq(gold.balanceOf(pol.DEAD()) - deadBefore, out);
        assertGt(out, 0.47 ether);
        assertEq(pol.burnBudget(), 0.5 ether);
        assertEq(pol.tokensBurned(), out);
        // slippage protection: an oracle quote far above the pool price blocks the trade
        polOracle.set(address(gold), 0.5e18);
        vm.expectRevert(POLManager.Slippage.selector);
        pol.buyAndBurn(0.5 ether);
        polOracle.set(address(gold), 1e18);
        vm.expectRevert(POLManager.TooLarge.selector);
        pol.buyAndBurn(0.6 ether);

        uint128 liqBefore = hook.liquidity();
        uint128 added = pol.addLiquidity(2 ether);
        assertGt(added, 0);
        assertEq(hook.liquidity(), liqBefore + added);
        assertEq(pol.polBudget(), 0);
        assertEq(pol.positionsMinted(), 1);
        pol.recycle();
        assertEq(pol.polBudget(), address(pol).balance - pol.burnBudget());
        assertLt(pol.polBudget(), 0.05 ether);
        vm.expectRevert(POLManager.NotInCallback.selector);
        vm.prank(address(manager));
        pol.unlockCallback("");
        vm.expectRevert(POLManager.UnexpectedSender.selector);
        pol.unlockCallback("");
    }

    function testFuzzFeeSplitInvariantOnBuys(uint256 amount, uint256 delay) public {
        amount = bound(amount, 1e9, 0.5 ether);
        delay = bound(delay, 0, 2 hours);
        vm.warp(vm.getBlockTimestamp() + delay);
        uint256 tax = hook.buyTaxBps();
        _swap(trader, true, -int256(amount));
        uint256 fee = (amount * 100) / 10_000;
        assertEq(hook.holderAccrued(), fee / 2);
        assertEq(hook.reserveAccrued(), fee - fee / 2 + (amount * tax) / 10_000);
        assertEq(manager.balanceOf(HOOK_ADDRESS, 0), hook.holderAccrued() + hook.reserveAccrued());
    }
}
