// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {GoblinNFT} from "../src/GoblinNFT.sol";
import {BagGacha} from "../src/BagGacha.sol";
import {GenesisVault} from "../src/GenesisVault.sol";
import {MockERC20, MockOracle, MockVRFWrapper, MockPOL, RejectingReceiver} from "./mocks/Mocks.sol";

contract BagGachaTest is Test {
    GoblinNFT nft;
    BagGacha gacha;
    GenesisVault genesis;
    MockOracle oracle;
    MockVRFWrapper vrf;
    MockPOL pol;
    MockERC20 plat;
    MockERC20 tokA;
    address team = address(0x7EA);
    address dep = address(0xDE9);
    address spinner = address(0x5A1);
    uint256 start;

    function setUp() public {
        oracle = new MockOracle();
        vrf = new MockVRFWrapper();
        pol = new MockPOL();
        plat = new MockERC20("PLAT");
        tokA = new MockERC20("A");
        oracle.set(address(plat), 1e12); // 1 token = 1e-6 ETH
        oracle.set(address(tokA), 1e15); // 1 token = 0.001 ETH
        oracle.setGenesisToken(address(plat));
        nft = new GoblinNFT(address(this));
        start = vm.getBlockTimestamp() + 8 days;
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        genesis = new GenesisVault(
            address(plat), address(oracle), predicted, start, 800_000_000e18, 20_000_000e18, address(this)
        );
        gacha = new BagGacha(
            address(oracle), address(genesis), address(nft), address(vrf), address(pol), team, start, address(this)
        );
        assertEq(address(gacha), predicted);

        for (uint256 i = 0; i < 500; ++i) {
            address m = address(uint160(0x10000 + i));
            vm.deal(m, 0.02 ether);
            vm.prank(m);
            nft.mint{value: 0.02 ether}(20);
        }
        nft.setLaunchTargets(address(pol), address(gacha), address(gacha));
        vm.warp(vm.getBlockTimestamp() + 7 days);
        nft.release();
        gacha.pullMintEscrow();
        assertEq(gacha.reserve(), 4 ether);
        assertEq(gacha.vrfBudget(), 1 ether);

        tokA.mint(dep, 1_000e18);
        vm.prank(dep);
        tokA.approve(address(gacha), type(uint256).max);
        vm.deal(spinner, 10 ether);
    }

    function _conserved() internal view {
        uint256 accounted = gacha.reserve() + gacha.locked() + gacha.vrfBudget() + gacha.holderAccrued()
            + gacha.polAccrued() + gacha.burnAccrued() + gacha.totalCredits() + gacha.heldSpinPayment();
        assertEq(address(gacha).balance, accounted, "ETH conservation");
    }

    function _seal(uint256 amount) internal returns (uint256) {
        address[] memory t = new address[](1);
        t[0] = address(tokA);
        uint256[] memory a = new uint256[](1);
        a[0] = amount;
        vm.prank(dep);
        return gacha.seal(t, a);
    }

    function _spinAndDraw(uint256 word) internal returns (uint256 allocationId) {
        (uint256 total,) = gacha.spinPrice();
        vm.prank(spinner);
        uint256 id = gacha.spin{value: total + 1 wei}();
        _conserved();
        vrf.fulfill(address(gacha), id, word);
        allocationId = gacha.draw();
        _conserved();
    }

    function testRegularSpinKeep() public {
        uint256 bagId = _seal(10e18); // 0.01 ETH = 1P, medium tier
        vm.warp(start + 2 days);
        uint256 allocationId = _spinAndDraw(42);
        (address s, uint256 drawn, uint256 value,,,,,) = gacha.allocations(allocationId);
        assertEq(s, spinner);
        assertEq(drawn, bagId);
        assertEq(value, 0.01 ether);
        vm.prank(spinner);
        gacha.choose(allocationId, true);
        _conserved();
        assertEq(gacha.credits(dep), 0.0095 ether);
        assertEq(gacha.credits(spinner), 1); // overpayment
        vm.prank(spinner);
        gacha.claimBag(bagId);
        assertEq(tokA.balanceOf(spinner), 10e18);
        vm.prank(spinner);
        vm.expectRevert(BagGacha.NotSpinner.selector);
        gacha.claimBag(bagId);
        // fee split of the regular spin: 88 reserve / 4 burn / 3 holders / 2 POL / 3 team
        assertEq(gacha.burnAccrued(), 0.0004 ether);
        assertEq(gacha.holderAccrued(), 0.0003 ether);
        assertEq(gacha.polAccrued(), 0.0002 ether);
        assertEq(gacha.credits(team), 0.0003 ether);
        gacha.flush();
        assertEq(pol.burn(), 0.0004 ether);
        assertEq(pol.pol(), 0.0002 ether);
        assertEq(address(nft).balance, 5 ether + 0.0003 ether); // 5 ETH POL share still unclaimed
        _conserved();
        vm.prank(dep);
        gacha.withdrawCredit();
        assertEq(dep.balance, 0.0095 ether);
        _conserved();
    }

    function testBuybackReturnsBagAndRematures() public {
        uint256 bagId = _seal(10e18);
        vm.warp(start + 2 days);
        uint256 allocationId = _spinAndDraw(7);
        vm.prank(spinner);
        gacha.choose(allocationId, false);
        assertEq(gacha.credits(spinner), 0.0088 ether + 1);
        (, BagGacha.BagStatus st,,,) = gacha.bagInfo(bagId);
        assertEq(uint256(st), uint256(BagGacha.BagStatus.Listed));
        // the returned Bag matures again: an immediate spin has nothing to draw
        (uint256 total,) = gacha.spinPrice();
        vm.prank(spinner);
        vm.expectRevert(BagGacha.NothingToDraw.selector);
        gacha.spin{value: total}();
        vm.prank(spinner);
        vm.expectRevert(BagGacha.AlreadySettled.selector);
        gacha.choose(allocationId, true);
        _conserved();
    }

    function testFinalizeAfterWindowIsKeep() public {
        uint256 bagId = _seal(10e18);
        vm.warp(start + 2 days);
        uint256 allocationId = _spinAndDraw(1);
        vm.expectRevert(BagGacha.WindowOpen.selector);
        gacha.finalize(allocationId);
        vm.warp(vm.getBlockTimestamp() + 5 minutes);
        vm.prank(spinner);
        vm.expectRevert(BagGacha.WindowClosed.selector);
        gacha.choose(allocationId, false);
        gacha.finalize(allocationId);
        assertEq(gacha.bagWinner(bagId), spinner);
        vm.expectRevert(BagGacha.AlreadySettled.selector);
        gacha.finalize(allocationId);
        _conserved();
    }

    function testOneOutstandingDrawAndCallbackRules() public {
        _seal(10e18);
        vm.warp(start + 2 days);
        (uint256 total,) = gacha.spinPrice();
        vm.prank(spinner);
        uint256 id = gacha.spin{value: total}();
        vm.prank(spinner);
        vm.expectRevert(BagGacha.DrawPending.selector);
        gacha.spin{value: total}();
        vm.expectRevert(BagGacha.NotFulfilled.selector);
        gacha.draw();
        uint256[] memory w = new uint256[](1);
        vm.expectRevert(BagGacha.OnlyWrapper.selector);
        gacha.rawFulfillRandomWords(id, w);
        // depositor cannot pull inventory while the draw is pending
        vm.prank(dep);
        vm.expectRevert(BagGacha.DrawPending.selector);
        gacha.withdraw(1);
        vrf.fulfill(address(gacha), id, 5);
        vrf.fulfill(address(gacha), id, 6); // duplicate ignored, no reroll
        gacha.draw();
        vm.expectRevert(BagGacha.NoDrawPending.selector);
        gacha.draw();
    }

    function testSpinRules() public {
        _seal(10e18);
        vm.warp(start + 1 hours);
        (uint256 total,) = gacha.spinPrice();
        vm.prank(spinner);
        vm.expectRevert(BagGacha.HolderWindow.selector);
        gacha.spin{value: total}();
        vm.warp(start + 2 days);
        vm.prank(spinner);
        vm.expectRevert(BagGacha.WrongPayment.selector);
        gacha.spin{value: total - 1}();
    }

    function testImmatureBagsNotDrawable() public {
        vm.warp(start + 3 days);
        _seal(10e18);
        (uint256 total,) = gacha.spinPrice();
        vm.prank(spinner);
        vm.expectRevert(BagGacha.NothingToDraw.selector);
        gacha.spin{value: total}();
    }

    function testAdmissionLimits() public {
        vm.expectRevert(BagGacha.ValueOutOfRange.selector);
        _seal(1e18); // 0.1P, below small tier
        vm.expectRevert(BagGacha.ValueOutOfRange.selector);
        _seal(300e18); // 0.3 ETH > 5% of 4 ETH reserve
        address[] memory t = new address[](2);
        t[0] = address(tokA);
        t[1] = address(tokA);
        uint256[] memory a = new uint256[](2);
        a[0] = 5e18;
        a[1] = 5e18;
        vm.prank(dep);
        vm.expectRevert(BagGacha.BadBag.selector);
        gacha.seal(t, a);
    }

    function testWithdrawExitFeeAndUnpricedExitFree() public {
        vm.warp(1000);
        uint256 bagId = _seal(10e18);
        vm.prank(dep);
        vm.expectRevert(BagGacha.Locked.selector);
        gacha.withdraw(bagId);
        vm.warp(1000 + 1 days);
        vm.deal(dep, 1 ether);
        vm.prank(dep);
        vm.expectRevert(BagGacha.WrongPayment.selector);
        gacha.withdraw(bagId);
        uint256 r = gacha.reserve();
        vm.prank(dep);
        gacha.withdraw{value: 0.00005 ether}(bagId);
        assertEq(gacha.reserve() - r, 0.00005 ether);
        assertEq(tokA.balanceOf(dep), 1_000e18);
        uint256 bag2 = _seal(10e18);
        vm.warp(1000 + 2 days);
        oracle.breakToken(address(tokA), true);
        vm.prank(dep);
        gacha.withdraw(bag2);
        assertEq(tokA.balanceOf(dep), 1_000e18);
        _conserved();
    }

    function testGenesisAndFreeSpins() public {
        plat.mint(address(genesis), 800_000_000e18);
        vm.warp(start + 1 hours);
        // free spin, holder window: Genesis lane forced, keep only
        address holder = nft.ownerOf(1);
        vm.prank(holder);
        uint256 id = gacha.freeSpin(1);
        vrf.fulfill(address(gacha), id, 3);
        uint256 allocationId = gacha.draw();
        (,, uint256 value, uint256 gTokens,,, bool buyback,) = gacha.allocations(allocationId);
        assertFalse(buyback);
        assertGt(gTokens, 0);
        // holder discount 5%: 0.0095 ETH of tokens
        assertEq(value, 0.0095 ether);
        vm.prank(holder);
        vm.expectRevert(BagGacha.NoBuyback.selector);
        gacha.choose(allocationId, false);
        vm.prank(holder);
        gacha.choose(allocationId, true);
        vm.prank(holder);
        genesis.claim();
        assertEq(plat.balanceOf(holder), gTokens);
        _conserved();
        vm.prank(holder);
        gacha.freeSpin(1);
        vrf.fulfill(address(gacha), vrf.lastId(), 9);
        gacha.draw();
        vm.prank(holder);
        vm.expectRevert(BagGacha.SpinLimit.selector);
        gacha.freeSpin(1);
        vm.prank(spinner);
        vm.expectRevert(BagGacha.NotHolder.selector);
        gacha.freeSpin(2);
    }

    function testGenesisPaidSpinSplit() public {
        plat.mint(address(genesis), 800_000_000e18);
        vm.warp(start + 3 days);
        // no regular Bags: lane is Genesis with certainty
        uint256 allocationId = _spinAndDraw(11);
        (,, uint256 value,,,,,) = gacha.allocations(allocationId);
        assertEq(value, 0.0092 ether);
        assertEq(gacha.polAccrued(), 0.004 ether);
        assertEq(gacha.holderAccrued(), 0.0015 ether);
        assertEq(gacha.credits(team), 0.0015 ether);
        vm.prank(spinner);
        gacha.choose(allocationId, false);
        assertEq(gacha.credits(spinner), (0.0092 ether * 88) / 100 + 1);
        _conserved();
    }

    function testReserveTooLowBlocksSpins() public {
        // a fresh gacha with no mint escrow has no reserve
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        GenesisVault g2 = new GenesisVault(address(plat), address(oracle), predicted, start, 1e24, 1e22, address(this));
        BagGacha g = new BagGacha(
            address(oracle), address(g2), address(nft), address(vrf), address(pol), team, start, address(this)
        );
        vm.warp(start + 3 days);
        vm.prank(spinner);
        vm.expectRevert(BagGacha.ReserveTooLow.selector);
        g.spin{value: 1 ether}();
    }

    function testRejectsUnexpectedEthAndEmptyCredit() public {
        RejectingReceiver r = new RejectingReceiver();
        vm.prank(address(r));
        vm.expectRevert(BagGacha.NothingOwed.selector);
        gacha.withdrawCredit();
        vm.expectRevert(BagGacha.UnexpectedSender.selector);
        payable(address(gacha)).transfer(1 ether);
    }
}
