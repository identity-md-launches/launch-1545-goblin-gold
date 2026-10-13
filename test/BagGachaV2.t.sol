// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {TaxToken, CreditReceiver} from "./mocks/AdversarialMocks.sol";
import {BagGachaTest} from "./BagGacha.t.sol";
import {BagGacha} from "../src/BagGacha.sol";
import {GenesisVault} from "../src/GenesisVault.sol";
import {GoblinNFT} from "../src/GoblinNFT.sol";
import {MockERC20, MockOracle, MockPOL, MockVRFWrapper} from "./mocks/Mocks.sol";

contract BagGachaV2Test is BagGachaTest {
    function testOldVRFIdCannotFulfillNewPendingRequest() public {
        _seal(10e18);
        _seal(10e18);
        vm.warp(start + 3 days);
        uint256 first = _spinAndDraw(123);
        uint256 oldId = vrf.lastId();
        vm.prank(spinner);
        gacha.choose(first, true);
        (uint256 total,) = gacha.spinPrice();
        vm.prank(spinner);
        uint256 nextId = gacha.spin{value: total}();
        assertNotEq(nextId, oldId);
        (, uint256 stored,,,,) = gacha.currentRequest();
        assertEq(stored, nextId);
        vrf.fulfill(address(gacha), oldId, 456);
        vm.expectRevert(BagGacha.NotFulfilled.selector);
        gacha.draw();
        vrf.fulfill(address(gacha), nextId, 789);
        gacha.draw();
        _conserved();
    }

    function testFreeSpinAfterRegularSnapshotAlwaysGenesis() public {
        _seal(10e18);
        _seal(10e18);
        vm.warp(start + 3 days);
        _spinAndDraw(50); // leaves the old snapshot in storage
        plat.mint(address(genesis), 800_000_000e18);
        address holder = nft.ownerOf(1);
        vm.prank(holder);
        uint256 req = gacha.freeSpin(1);
        (,,,,, uint256 gBps) = gacha.currentRequest();
        assertEq(gBps, 10_000);
        (uint256[] memory ids,,) = gacha.snapshot();
        assertEq(ids.length, 0);
        vrf.fulfill(address(gacha), req, 500);
        uint256 id = gacha.draw();
        (, uint256 bag,,,,, bool buyback,) = gacha.allocations(id);
        assertEq(bag, 0);
        assertFalse(buyback);
        _conserved();
    }

    function testFreeSpinUnfundedGenesisCannotUseRegularBags() public {
        _seal(10e18);
        _seal(10e18);
        vm.warp(start + 3 days);
        _spinAndDraw(77);
        address holder = nft.ownerOf(1);
        vm.prank(holder);
        vm.expectRevert(BagGacha.NothingToDraw.selector);
        gacha.freeSpin(1);
        assertEq(gacha.freeSpinsUsed(1), 0);
        _conserved();
    }

    function testUnavailableGenesisDoesNotBlockRegularDrawOrWithdrawal() public {
        _seal(10e18);
        plat.mint(address(genesis), 800_000_000e18);
        oracle.breakToken(address(plat), true);
        vm.warp(start + 3 days);
        uint256 id = _spinAndDraw(91);
        (, uint256 bag,,,,,,) = gacha.allocations(id);
        assertEq(bag, 1);
        _conserved();
    }

    function testOddsAndOracleChangesDoNotRewritePendingSnapshot() public {
        _seal(5e18);
        _seal(10e18);
        vm.warp(start + 3 days);
        (uint256 total,) = gacha.spinPrice();
        vm.prank(spinner);
        gacha.spin{value: total}();
        (,,,, uint256[4] memory beforeOdds,) = gacha.currentRequest();
        (, uint256[] memory beforeValues,) = gacha.snapshot();
        gacha.setTierOdds([uint256(7400), 1900, 650, 50]);
        oracle.breakToken(address(tokA), true);
        (,,,, uint256[4] memory afterOdds,) = gacha.currentRequest();
        (, uint256[] memory afterValues,) = gacha.snapshot();
        for (uint256 i; i < 4; ++i) {
            assertEq(beforeOdds[i], afterOdds[i]);
        }
        assertEq(beforeValues, afterValues);
        vrf.fulfill(address(gacha), vrf.lastId(), 21);
        uint256 id = gacha.draw();
        vm.prank(spinner);
        gacha.choose(id, false);
        _conserved();
    }

    function testMissingVRFKeepsSnapshotLockedWithoutRefundOrReroll() public {
        _seal(10e18);
        vm.warp(start + 3 days);
        (uint256 total,) = gacha.spinPrice();
        vm.prank(spinner);
        gacha.spin{value: total}();
        vm.warp(vm.getBlockTimestamp() + 365 days);
        vm.expectRevert(BagGacha.NotFulfilled.selector);
        gacha.draw();
        vm.prank(dep);
        vm.expectRevert(BagGacha.DrawPending.selector);
        gacha.withdraw(1);
        vm.prank(spinner);
        vm.expectRevert(BagGacha.DrawPending.selector);
        gacha.spin{value: total}();
        _conserved();
    }

    function testFeeOnTransferTokenCannotCreateUnderfundedBag() public {
        TaxToken taxed = new TaxToken();
        oracle.set(address(taxed), 1e15);
        taxed.mint(dep, 10 ether);
        vm.prank(dep);
        taxed.approve(address(gacha), 10 ether);
        address[] memory tokens = new address[](1);
        tokens[0] = address(taxed);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 10 ether;
        vm.prank(dep);
        vm.expectRevert(BagGacha.BadBag.selector);
        gacha.seal(tokens, amounts);
        assertEq(gacha.activeCount(), 0);
        assertEq(taxed.balanceOf(dep), 10 ether);
        assertEq(gacha.depositorShares(dep), 0);
        _conserved();
    }

    function testCreditTransferFailureRollsBackAndReentryCannotPayTwice() public {
        CreditReceiver receiver = new CreditReceiver(gacha);
        spinner = address(receiver);
        vm.deal(spinner, 1 ether);
        _seal(10e18);
        vm.warp(start + 3 days);
        uint256 id = _spinAndDraw(19);
        vm.prank(spinner);
        gacha.choose(id, false);
        uint256 credit = gacha.credits(spinner);
        receiver.setReject(true);
        vm.prank(spinner);
        vm.expectRevert(BagGacha.TransferFailed.selector);
        gacha.withdrawCredit();
        assertEq(gacha.credits(spinner), credit);
        _conserved();
        receiver.setReject(false);
        uint256 beforeBalance = spinner.balance;
        vm.prank(spinner);
        gacha.withdrawCredit();
        assertEq(spinner.balance - beforeBalance, credit);
        assertFalse(receiver.reentered());
        assertEq(gacha.credits(spinner), 0);
        _conserved();
    }

    function testFuzzSolventPayoutAndNoDoublePayment(uint256 amount, uint256 word, bool keep) public {
        gacha.fundReserve{value: 10 ether}(); // enable the jackpot tier as well as its reserve cap
        amount = bound(amount, 3e18, 200e18);
        uint256 bag = _seal(amount);
        vm.warp(start + 3 days);
        uint256 id = _spinAndDraw(word);
        uint256 value = (amount * 1e15) / 1e18;
        vm.prank(spinner);
        gacha.choose(id, keep);
        _conserved();
        if (keep) assertEq(gacha.credits(dep), value * 9500 / 10_000);
        else assertEq(gacha.credits(spinner), value * 8800 / 10_000 + 1);
        vm.prank(spinner);
        vm.expectRevert(BagGacha.AlreadySettled.selector);
        gacha.choose(id, keep);
        if (keep) {
            vm.prank(spinner);
            gacha.claimBag(bag);
            assertEq(tokA.balanceOf(spinner), amount);
            vm.prank(spinner);
            vm.expectRevert(BagGacha.NotSpinner.selector);
            gacha.claimBag(bag);
        }
    }
}

contract EarlyGachaTest is Test {
    MockOracle oracle;
    MockVRFWrapper vrf;
    MockPOL pol;
    MockERC20 plat;
    MockERC20 tokA;
    GoblinNFT nft;
    GenesisVault genesis;
    BagGacha gacha;
    uint256 start;
    address team = address(0x7EA);
    address spinner = address(0x5A1);

    function _conserved() internal view {
        assertEq(
            address(gacha).balance,
            gacha.reserve() + gacha.locked() + gacha.vrfBudget() + gacha.holderAccrued() + gacha.polAccrued()
                + gacha.burnAccrued() + gacha.totalCredits() + gacha.heldSpinPayment()
        );
    }

    function setUp() public {
        oracle = new MockOracle();
        vrf = new MockVRFWrapper();
        pol = new MockPOL();
        plat = new MockERC20("PLAT");
        tokA = new MockERC20("A");
        oracle.set(address(plat), 1e12);
        oracle.set(address(tokA), 1e15);
        nft = new GoblinNFT(address(this));
        start = vm.getBlockTimestamp();
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        genesis = new GenesisVault(
            address(plat), address(oracle), predicted, start, 800_000_000e18, 20_000_000e18, address(this)
        );
        gacha = new BagGacha(
            address(oracle), address(genesis), address(nft), address(vrf), address(pol), team, start, address(this)
        );
        vm.deal(spinner, 10 ether);
        vm.prank(spinner);
        nft.mint{value: 0.001 ether}(1);
        gacha.fundReserve{value: 1 ether}();
        gacha.fundVRF{value: 0.01 ether}();
        plat.mint(address(genesis), 800_000_000e18);
    }

    function testPreReleaseRefundCannotRecycleFreeSpinCoupons() public {
        assertGt(gacha.vrfBudget(), 0);
        vm.prank(spinner);
        vm.expectRevert(BagGacha.MintNotReleased.selector);
        gacha.freeSpin(1);
        uint256 beforeBalance = spinner.balance;
        vm.prank(spinner);
        nft.refund(1);
        assertEq(spinner.balance - beforeBalance, 0.001 ether);
        vm.prank(spinner);
        nft.mint{value: 0.001 ether}(1);
        vm.prank(spinner);
        vm.expectRevert(BagGacha.MintNotReleased.selector);
        gacha.freeSpin(2);
        assertEq(genesis.emitted(), 0);
        _conserved();
    }

    function testDayOneRevenueBeforeSelloutAndMintRemainsRefundable() public {
        assertFalse(nft.soldOut());
        assertFalse(nft.released());
        (uint256 total,) = gacha.spinPrice();
        vm.prank(spinner);
        uint256 req = gacha.holderSpin{value: total}(1);
        vrf.fulfill(address(gacha), req, 7);
        uint256 id = gacha.draw();
        vm.prank(spinner);
        gacha.choose(id, true);
        gacha.flush();
        assertEq(nft.pendingRevenue(1), 0.0015 ether);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.prank(spinner);
        nft.claimRevenue(ids);
        assertEq(address(nft).balance, 0.001 ether);
        vm.prank(spinner);
        nft.refund(1);
        assertEq(address(nft).balance, 0);
        _conserved();
    }
}
