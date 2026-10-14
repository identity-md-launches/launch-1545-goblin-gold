// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {V4Fixture} from "./mocks/V4Fixture.sol";
import {BagGachaTest} from "./BagGacha.t.sol";
import {GoldHook} from "../src/GoldHook.sol";
import {BagGacha} from "../src/BagGacha.sol";
import {GenesisVault} from "../src/GenesisVault.sol";
import {TwapOracle} from "../src/TwapOracle.sol";
import {POLManager} from "../src/POLManager.sol";
import {TickMath} from "../src/TickMath.sol";
import {MockERC20, MockOracle, MockVRFWrapper, MockPOL} from "./mocks/Mocks.sol";
import {MockV3Factory} from "./mocks/CuratorMocks.sol";
import {IHooks} from "./v4-core/interfaces/IHooks.sol";
import {SwapParams as CoreSwap, ModifyLiquidityParams as CoreModify} from "./v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "./v4-core/types/BalanceDelta.sol";
import {CustomRevert} from "./v4-core/libraries/CustomRevert.sol";

/// @notice Permanent regression tests for audit 85083c05 (Goblin Gold v3.2), one per finding, named after the audit's
///         proofs of concept. Hook, oracle and POLManager findings run on the real vendored PoolManager.
contract Audit85083c05HookTest is V4Fixture {
    MockOracle polOracle;
    MockERC20 weth;
    TwapOracle oracle;
    GenesisVault genesis;
    BagGacha gacha;
    POLManager pol;
    MockPOL mockPol;
    MockVRFWrapper vrf;

    function setUp() public {
        _deployV4(keccak256(type(BagGacha).runtimeCode));
        _initialize();
        _seed(100 ether, 100 ether, 100e18);
        polOracle = new MockOracle();
        polOracle.set(address(gold), 1e18);
        weth = new MockERC20("WETH");
        oracle = new TwapOracle(address(this), address(weth), address(new MockV3Factory()), address(gold), HOOK_ADDRESS);
        vrf = new MockVRFWrapper();
        mockPol = new MockPOL();
        (gacha, genesis) = _gachaPair(address(gold), address(oracle), address(0));
        pol = new POLManager(address(manager), address(gold), HOOK_ADDRESS, address(polOracle), NFT_ADDRESS);
    }

    /// @dev A BagGacha + GenesisVault pair built from the pinned code. `vaultGacha` zero wires the vault to the gacha.
    function _gachaPair(address token, address oracle_, address vaultGacha)
        internal
        returns (BagGacha g, GenesisVault v)
    {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        v = new GenesisVault(
            token,
            oracle_,
            vaultGacha == address(0) ? predicted : vaultGacha,
            vm.getBlockTimestamp(),
            1e24,
            1e22,
            address(this)
        );
        g = new BagGacha(
            address(oracle), address(v), NFT_ADDRESS, address(vrf), address(mockPol), address(this), 1, address(this)
        );
        assertEq(address(g), predicted);
    }

    function _name(BagGacha g) internal {
        nft.setLaunchTargets(address(g.polManager()), address(g), address(g));
        vm.warp(vm.getBlockTimestamp() + nft.TARGET_REVIEW_PERIOD());
    }

    function _charged() internal view returns (uint256) {
        return hook.holderAccrued() + hook.reserveAccrued();
    }

    // ------------------------------------------------------------------ 1. CRITICAL: BindGachaLookalike

    /// @dev A gacha with the pinned code, the right NFT and a vault of the right token, that the NFT owner never
    ///      named through the holder-reviewed `setLaunchTargets`, can no longer capture the reserve share.
    function testBindGachaLookalike() public {
        (BagGacha fake,) = _gachaPair(address(gold), address(oracle), address(0));
        assertTrue(address(fake).codehash == address(gacha).codehash, "same runtime code");
        assertEq(address(fake.nft()), NFT_ADDRESS);
        vm.expectRevert(GoldHook.NotLaunchTarget.selector);
        hook.bindGacha(address(fake));

        // the owner names the real gacha: the look-alike stays refused before and after the review
        nft.setLaunchTargets(address(mockPol), address(gacha), address(gacha));
        vm.expectRevert(GoldHook.ReviewPending.selector);
        hook.bindGacha(address(gacha));
        vm.expectRevert(GoldHook.NotLaunchTarget.selector);
        hook.bindGacha(address(fake));
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.expectRevert(GoldHook.NotLaunchTarget.selector);
        hook.bindGacha(address(fake));

        // every one of the three targets must point at the candidate (or its POLManager)
        nft.setLaunchTargets(address(mockPol), address(fake), address(gacha));
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.expectRevert(GoldHook.NotLaunchTarget.selector);
        hook.bindGacha(address(fake));
        vm.expectRevert(GoldHook.NotLaunchTarget.selector);
        hook.bindGacha(address(gacha));
        nft.setLaunchTargets(address(mockPol), address(gacha), address(fake));
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.expectRevert(GoldHook.NotLaunchTarget.selector);
        hook.bindGacha(address(gacha));
        nft.setLaunchTargets(address(oracle), address(gacha), address(gacha)); // POL target is not its POLManager
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.expectRevert(GoldHook.NotLaunchTarget.selector);
        hook.bindGacha(address(gacha));

        // even a named candidate must be wired consistently: vault token, vault.gacha(), vault oracle, NFT
        (BagGacha wrongToken,) = _gachaPair(address(new MockERC20("X")), address(oracle), address(0));
        _name(wrongToken);
        vm.expectRevert(GoldHook.GachaMismatch.selector);
        hook.bindGacha(address(wrongToken));
        (BagGacha vaultElsewhere,) = _gachaPair(address(gold), address(oracle), address(gacha));
        _name(vaultElsewhere);
        vm.expectRevert(GoldHook.GachaMismatch.selector);
        hook.bindGacha(address(vaultElsewhere));
        (BagGacha otherOracle,) = _gachaPair(address(gold), address(new MockOracle()), address(0));
        _name(otherOracle);
        vm.expectRevert(GoldHook.GachaMismatch.selector);
        hook.bindGacha(address(otherOracle));
        BagGacha wrongNft = new BagGacha(
            address(oracle), address(genesis), address(this), address(vrf), address(mockPol), address(1), 1, address(2)
        );
        _name(wrongNft);
        vm.expectRevert(GoldHook.GachaMismatch.selector);
        hook.bindGacha(address(wrongNft));

        // the named, consistently wired gacha binds once the review has run out
        _name(gacha);
        hook.bindGacha(address(gacha));
        assertEq(hook.gacha(), address(gacha));
        vm.expectRevert(GoldHook.AlreadyBound.selector);
        hook.bindGacha(address(fake));
    }

    // ------------------------------------------------------------------ 2. HIGH: PolFeeBrick

    /// @dev Once the POL position has earned more LP fees than a new add needs, the caller delta comes back positive.
    ///      The callback now takes it: the ETH is recycled into the POL budget, the GOLD waits for the next add.
    function testPolFeeBrick() public {
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        polOracle.set(address(gold), 1.2e18); // loose floor: the pool drifts a little under the volume below
        pol.depositPOL{value: 3 ether}();
        assertGt(pol.addLiquidity(2 ether), 0);
        for (uint256 i = 0; i < 5; ++i) {
            _swap(trader, true, -5 ether);
            _swap(trader, false, -5 ether);
        }
        uint256 budgetBefore = pol.polBudget();
        uint256 goldBefore = gold.balanceOf(address(pol));
        vm.expectEmit(false, false, false, false, address(pol));
        emit POLManager.FeesCollected(0, 0);
        uint128 added = pol.addLiquidity(10_000 wei); // principal far below the accrued fees
        assertGt(added, 0);
        assertGt(pol.polBudget(), budgetBefore, "the ETH fees taken exceed the 10_000 wei spent and are recycled");
        assertGt(gold.balanceOf(address(pol)), goldBefore, "the GOLD fees taken wait for the next add");
        assertEq(manager.balanceOf(address(pol), 0), 0);
        // adds keep working afterwards, in both sizes
        assertGt(pol.addLiquidity(0.5 ether), 0);
        assertGt(pol.addLiquidity(1000 wei), 0);
        pol.recycle();
        assertEq(pol.polBudget(), address(pol).balance - pol.burnBudget());
    }

    // ------------------------------------------------------------------ 3. HIGH: PartialFillFee

    function _expectPartialFill(bool zeroForOne, int256 amountSpecified, uint160 limit) internal {
        uint256 value;
        if (zeroForOne) {
            value = 2 ether;
        } else {
            gold.mint(trader, 100 ether);
            vm.prank(trader);
            gold.approve(address(swapRouter), type(uint256).max);
        }
        bytes memory data =
            abi.encodeCall(swapRouter.swap, (key, CoreSwap(zeroForOne, amountSpecified, limit), _settings(), ""));
        vm.prank(trader);
        (bool ok, bytes memory ret) = address(swapRouter).call{value: value}(data);
        assertFalse(ok, "a limit-bounded swap with ETH specified must revert");
        assertTrue(bytes4(ret) == CustomRevert.WrappedError.selector, "wrapped hook revert");
        bytes memory body = new bytes(ret.length - 4);
        for (uint256 i = 0; i < body.length; ++i) {
            body[i] = ret[i + 4];
        }
        (address target, bytes4 selector, bytes memory reason,) = abi.decode(body, (address, bytes4, bytes, bytes));
        assertEq(target, HOOK_ADDRESS);
        assertTrue(selector == IHooks.afterSwap.selector, "raised in afterSwap");
        assertTrue(bytes4(reason) == GoldHook.PartialFill.selector, "PartialFill");
    }

    /// @dev With ETH specified the charge is taken in `beforeSwap` on the whole amount, so a price-limit-bounded fill
    ///      reverts instead of charging fee and tax on ETH the pool never consumed. With ETH unspecified the charge is
    ///      computed from the realised leg, so partial fills there are charged correctly and go through.
    function testPartialFillFee() public {
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _expectPartialFill(true, -1 ether, TickMath.sqrtPriceAtTick(-60)); // exact-input buy, limit just below
        _expectPartialFill(false, 1 ether, TickMath.sqrtPriceAtTick(60)); // exact-output sell, limit just above
        assertEq(_charged(), 0, "a reverted swap charges nothing");
        // the same swaps with the extreme limit fill fully and are charged exactly on the amount
        _swap(trader, true, -1 ether);
        assertEq(_charged(), 0.01 ether);
        _swap(trader, false, 1 ether);
        assertEq(_charged(), 0.02 ether);
        // exact-output buy bounded by a limit: charged on the ETH the pool realised, not on the request
        (, int24 tick) = hook.slot0();
        uint256 before = _charged();
        vm.prank(trader);
        BalanceDelta d = swapRouter.swap{value: 20 ether}(
            key, CoreSwap(true, 5 ether, TickMath.sqrtPriceAtTick(tick - 120)), _settings(), ""
        );
        assertLt(uint256(uint128(d.amount1())), 5 ether, "partial fill");
        uint256 charge = _charged() - before;
        uint256 ethIn = uint256(uint128(-d.amount0())) - charge;
        assertEq(charge, ((ethIn * 10_000) / 9900) / 100, "fee is 1% of the gross of the realised leg");
        // exact-input sell bounded by a limit: charged 1% of the ETH the pool realised
        (, tick) = hook.slot0();
        before = _charged();
        gold.mint(trader, 100 ether);
        vm.prank(trader);
        gold.approve(address(swapRouter), type(uint256).max);
        vm.prank(trader);
        d = swapRouter.swap(key, CoreSwap(false, -50 ether, TickMath.sqrtPriceAtTick(tick + 120)), _settings(), "");
        assertLt(uint256(uint128(-d.amount1())), 50 ether, "partial fill");
        charge = _charged() - before;
        uint256 realised = uint256(uint128(d.amount0())) + charge;
        assertEq(charge, (realised * 100) / 10_000);
        // POLManager's internal swaps use the extreme limit and keep working
        polOracle.set(address(gold), 2e18); // loose floor: the price moved under the swaps above
        pol.depositBurn{value: 1 ether}();
        assertGt(pol.buyAndBurn(0.1 ether), 0);
    }

    // ------------------------------------------------------------------ 4. HIGH: JitPayoutCap

    /// @dev Liquidity added inside one transaction raises neither the genesis depth nor the 5% payout cap: the oracle
    ///      takes min(current L, L recorded by the observation 30 minutes ago). Removing liquidity counts at once.
    function testJitPayoutCap() public {
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _swap(trader, true, -0.001 ether); // records the seeded 100e18
        vm.warp(vm.getBlockTimestamp() + 4 hours);
        _swap(trader, false, -0.001 ether);
        uint256 cap0 = oracle.payoutCap(address(gold));
        assertApproxEqRel(cap0, 5 ether, 0.01e18);
        (, uint256 gcap0) = oracle.genesisValueAndCap(1e18);
        assertEq(gcap0, cap0);

        // JIT: ten times the liquidity, same block
        gold.mint(address(this), 10_000e18);
        gold.approve(address(lpRouter), type(uint256).max);
        lpRouter.modifyLiquidity{value: 1000 ether}(key, CoreModify(-887220, 887220, 1000e18, bytes32(0)), "");
        assertEq(hook.liquidity(), 1100e18);
        assertEq(hook.liquidityAt(30 minutes), 100e18);
        assertEq(oracle.payoutCap(address(gold)), cap0, "JIT liquidity does not move the cap");
        (, uint256 gcap) = oracle.genesisValueAndCap(1e18);
        assertEq(gcap, cap0);
        // a swap in the same block writes no observation, so nothing changes
        _swap(trader, true, -0.001 ether);
        assertEq(hook.liquidityAt(30 minutes), 100e18);
        assertApproxEqRel(oracle.payoutCap(address(gold)), cap0, 1e13);
        // the next block records it, and it only counts once that observation is 30 minutes old
        vm.warp(vm.getBlockTimestamp() + 1);
        _swap(trader, false, -0.001 ether);
        assertEq(hook.liquidityAt(30 minutes), 100e18);
        assertApproxEqRel(oracle.payoutCap(address(gold)), cap0, 1e13);
        vm.warp(vm.getBlockTimestamp() + 30 minutes - 1);
        assertEq(hook.liquidityAt(30 minutes), 100e18);
        vm.warp(vm.getBlockTimestamp() + 1);
        assertEq(hook.liquidityAt(30 minutes), 1100e18);
        assertApproxEqRel(oracle.payoutCap(address(gold)), 55 ether, 0.01e18);
        // removing liquidity lowers the cap in the same transaction
        lpRouter.modifyLiquidity(key, CoreModify(-887220, 887220, -1000e18, bytes32(0)), "");
        assertEq(hook.liquidity(), 100e18);
        assertApproxEqRel(oracle.payoutCap(address(gold)), cap0, 1e13);
        // and a JIT re-add after the removal still only counts the recorded liquidity
        lpRouter.modifyLiquidity{value: 5000 ether}(key, CoreModify(-887220, 887220, 5000e18, bytes32(0)), "");
        assertEq(hook.liquidity(), 5100e18);
        assertApproxEqRel(oracle.payoutCap(address(gold)), 55 ether, 0.01e18);
    }

    /// @dev The ETH-side depth is the ETH the active liquidity holds up to the last usable tick, never above the
    ///      virtual reserve; at a price near that tick the virtual reserve overstates it.
    function testGenesisDepthIsBoundedByTheEthTheLiquidityHolds() public view {
        uint160 sqrtMax = TickMath.sqrtPriceAtTick(oracle.GENESIS_MAX_USABLE_TICK());
        assertApproxEqAbs(oracle.genesisEthHeld(100e18, uint160(1 << 96)), 100e18, 10); // 1:1: a few wei
        assertEq(oracle.genesisEthHeld(100e18, sqrtMax), 0);
        uint160 half = sqrtMax / 2;
        uint256 virtualReserve = Math.mulDiv(100e18, 1 << 96, half);
        assertApproxEqAbs(oracle.genesisEthHeld(100e18, half), virtualReserve / 2, 1);
        assertLt(oracle.genesisEthHeld(100e18, half), virtualReserve);
    }

    // ------------------------------------------------------------------ 5. MEDIUM: one-window push

    function _tokensAtTick(int24 tick, uint256 ethAmount) internal pure returns (uint256) {
        uint160 sqrtRatio = TickMath.sqrtPriceAtTick(tick);
        return Math.mulDiv(uint256(sqrtRatio) * sqrtRatio, ethAmount, 1 << 192);
    }

    function _meanTicks() internal view returns (int24 shortTick, int24 longTick) {
        uint32[] memory agos = new uint32[](3);
        agos[0] = 30 minutes;
        agos[1] = 4 hours;
        int56[] memory c = hook.observe(agos);
        shortTick = int24((c[2] - c[0]) / int56(uint56(30 minutes)));
        longTick = int24((c[2] - c[1]) / int56(uint56(4 hours)));
    }

    /// @dev Dumping GOLD for 30 minutes used to make the Genesis quote follow the cheap window (more tokens per ETH)
    ///      while its value was marked at the same cheap window. Now the quote is the smaller token amount and the
    ///      genesis cap values it at the 4-hour TWAP.
    function testShortWindowPushNoLongerInflatesGenesisBags() public {
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _swap(trader, true, -0.001 ether);
        vm.warp(vm.getBlockTimestamp() + 4 hours);
        _swap(trader, false, -0.001 ether);
        uint256 spend = 0.0092 ether; // (1 - 8%) of the spin price
        uint256 q0 = oracle.tokensForEth(address(gold), spend);
        assertApproxEqRel(q0, spend, 0.001e18);

        _swap(trader, false, -50 ether); // GOLD dumped: 1.5x more GOLD per ETH at spot
        vm.warp(vm.getBlockTimestamp() + 31 minutes);
        _swap(trader, false, -0.001 ether);
        (int24 s, int24 l) = _meanTicks();
        uint256 shortQuote = _tokensAtTick(s, spend);
        uint256 longQuote = _tokensAtTick(l, spend);
        assertGt(shortQuote, 2 * q0, "the 30-minute window alone would hand out over twice the tokens");
        assertLt(longQuote, (q0 * 115) / 100, "the 4-hour window moved by the push's 31 of 240 minutes only");
        uint256 q = oracle.tokensForEth(address(gold), spend);
        assertEq(q, Math.min(shortQuote, longQuote), "the Genesis quote is the smaller token amount");
        assertEq(q, longQuote);
        // the genesis cap values the quote at the 4-hour TWAP: the spend, not the cheap-window mark
        (uint256 value, uint256 cap) = oracle.genesisValueAndCap(q);
        assertApproxEqRel(value, spend, 1e12);
        assertLt(oracle.valueInEth(address(gold), q), value, "the conservative mark still uses the cheaper window");
        assertEq(cap, oracle.payoutCap(address(gold)));
        // pushing the other way (GOLD pumped for 30 minutes) is no better: fewer tokens, valued at 4 hours
        _swap(trader, true, -60 ether);
        vm.warp(vm.getBlockTimestamp() + 31 minutes);
        _swap(trader, true, -0.001 ether);
        (s, l) = _meanTicks();
        uint256 q2 = oracle.tokensForEth(address(gold), spend);
        assertEq(q2, Math.min(_tokensAtTick(s, spend), _tokensAtTick(l, spend)));
        assertLt(q2, q0);
        (value,) = oracle.genesisValueAndCap(q2);
        assertLe(value, spend + 1);
    }

    // ------------------------------------------------------------------ 6. MEDIUM: MIN_OUT_BPS

    function testMinOutBpsMatchesTheFeeSchedule() public view {
        assertEq(pol.MIN_OUT_BPS(), 9475);
        assertEq(pol.MIN_OUT_BPS(), 10_000 - 125 - 100 - 300);
    }

    /// @dev With the corrected floor a fair quote passes and a 6% shortfall fails.
    function testMinOutFloorBehaviour() public {
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        pol.depositBurn{value: 2 ether}();
        uint256 out = pol.buyAndBurn(0.1 ether);
        assertGe(out, (0.1 ether * 9475) / 10_000, "a fair quote clears the floor");
        polOracle.set(address(gold), 0.94e18); // the pool now pays ~6% less than this quote implies
        vm.expectRevert(POLManager.Slippage.selector);
        pol.buyAndBurn(0.1 ether);
    }
}

/// @notice Finding 8: an unfulfilled VRF request no longer locks the gacha forever.
contract Audit85083c05GachaTest is BagGachaTest {
    function testUnfulfilledRequestCanBeCancelledAfterADay() public {
        plat.mint(address(genesis), 800_000_000e18);
        uint256 bagId = _seal(10e18);
        vm.warp(start + 2 days);
        (uint256 total,) = gacha.spinPrice();
        vm.prank(spinner);
        uint256 id = gacha.spin{value: total + 5}();
        assertTrue(gacha.pending());
        assertGt(genesis.emitted(), 0, "the Genesis lane is committed");
        (,,, uint256 liability,,) = gacha.currentRequest();
        assertGt(liability, 0);
        assertEq(gacha.locked(), liability);
        uint256 reserveBefore = gacha.reserve();
        uint256 vrfBudgetBefore = gacha.vrfBudget();

        vm.expectRevert(BagGacha.CancelNotDue.selector);
        gacha.cancelRequest();
        vm.warp(vm.getBlockTimestamp() + 24 hours - 1);
        vm.expectRevert(BagGacha.CancelNotDue.selector);
        gacha.cancelRequest();
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.expectEmit(true, true, false, true, address(gacha));
        emit BagGacha.SpinCancelled(id, spinner, 0.01 ether, liability);
        vm.prank(address(0xBEEF)); // anyone
        gacha.cancelRequest();

        assertFalse(gacha.pending());
        assertEq(gacha.locked(), 0);
        assertEq(gacha.reserve(), reserveBefore + liability, "the earmark is released");
        assertEq(gacha.heldSpinPayment(), 0);
        assertEq(gacha.credits(spinner), 0.01 ether + 5, "spin price refunded, plus the overpayment");
        assertEq(genesis.emitted(), 0, "the Genesis tokens are uncommitted");
        assertEq(gacha.vrfBudget(), vrfBudgetBefore, "the VRF fee was spent, not refunded from the budget");
        _conserved();

        // the late word is ignored and nothing can be drawn or cancelled twice
        vrf.fulfill(address(gacha), id, 1);
        assertFalse(gacha.pending());
        vm.expectRevert(BagGacha.NoDrawPending.selector);
        gacha.draw();
        vm.expectRevert(BagGacha.NoDrawPending.selector);
        gacha.cancelRequest();
        (,, bool fulfilled,,,) = gacha.currentRequest();
        assertFalse(fulfilled);

        // the refund is pullable, the depositor can withdraw again and a new spin works
        uint256 balBefore = spinner.balance;
        vm.prank(spinner);
        gacha.withdrawCredit();
        assertEq(spinner.balance - balBefore, 0.01 ether + 5);
        uint256 fee = (0.01 ether * 50) / 10_000;
        vm.deal(dep, fee);
        vm.prank(dep);
        gacha.withdraw{value: fee}(bagId);
        uint256 bagId2 = _seal(10e18);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        vm.prank(spinner);
        uint256 id2 = gacha.spin{value: total}();
        assertTrue(id2 != id);
        vrf.fulfill(address(gacha), id, 2); // the stale id does nothing
        (,, fulfilled,,,) = gacha.currentRequest();
        assertFalse(fulfilled);
        vrf.fulfill(address(gacha), id2, 2);
        // a fulfilled request cannot be cancelled, however old: it is drawn
        vm.warp(vm.getBlockTimestamp() + 3 days);
        vm.expectRevert(BagGacha.AlreadyFulfilled.selector);
        gacha.cancelRequest();
        uint256 allocationId = gacha.draw();
        (, uint256 drawn,,,,,,) = gacha.allocations(allocationId);
        assertTrue(drawn == bagId2 || drawn == 0);
        _conserved();
    }

    function testCancelledFreeSpinRefundsNothingButReleasesTheGenesisTokens() public {
        plat.mint(address(genesis), 800_000_000e18);
        vm.warp(start + 1);
        address holder = address(0x10000); // owns tokens 1-20 from setUp
        uint256 vrfBudgetBefore = gacha.vrfBudget();
        vm.prank(holder);
        gacha.freeSpin(1);
        uint256 committed = genesis.emitted();
        assertGt(committed, 0);
        assertEq(gacha.heldSpinPayment(), 0);
        assertEq(gacha.locked(), 0, "free spins earmark nothing");
        vm.warp(vm.getBlockTimestamp() + gacha.CANCEL_DELAY());
        gacha.cancelRequest();
        assertFalse(gacha.pending());
        assertEq(gacha.credits(holder), 0, "nothing was paid, nothing is refunded");
        assertEq(genesis.emitted(), 0);
        assertLt(gacha.vrfBudget(), vrfBudgetBefore, "the VRF fee stays spent");
        assertEq(gacha.freeSpinsUsed(1), 1, "the coupon stays used");
        _conserved();
        // the holder's other coupon still works
        vm.prank(holder);
        gacha.freeSpin(1);
        assertTrue(gacha.pending());
    }
}
