// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {GoblinNFT} from "../src/GoblinNFT.sol";
import {GoblinArt} from "../src/GoblinArt.sol";

contract ReleaseReceiver {
    receive() external payable {}
}

contract GoblinNFTTest is Test {
    GoblinNFT nft;
    address owner = address(0xA11CE);
    address alice = address(0xA1);
    address pol = address(0x901);
    address reserve = address(0x902);
    address vrf = address(0x903);

    function setUp() public {
        nft = new GoblinNFT(owner);
        pol = address(new ReleaseReceiver());
        reserve = address(new ReleaseReceiver());
        vrf = address(new ReleaseReceiver());
        vm.deal(alice, 1 ether);
    }

    function _sellOut() internal {
        for (uint256 i = 0; i < 500; ++i) {
            address m = address(uint160(0x10000 + i));
            vm.deal(m, 0.02 ether);
            vm.prank(m);
            nft.mint{value: 0.02 ether}(20);
        }
    }

    function testMintAndLimits() public {
        vm.prank(alice);
        nft.mint{value: 0.003 ether}(3);
        assertEq(nft.ownerOf(1), alice);
        assertEq(nft.liveSupply(), 3);
        vm.prank(alice);
        vm.expectRevert(GoblinNFT.WrongPayment.selector);
        nft.mint{value: 0.001 ether}(2);
        vm.prank(alice);
        vm.expectRevert(GoblinNFT.WalletLimit.selector);
        nft.mint{value: 0.018 ether}(18);
        vm.prank(alice);
        vm.expectRevert(GoblinNFT.BadQuantity.selector);
        nft.mint{value: 0}(0);
    }

    function testRefundBeforeSellout() public {
        vm.prank(alice);
        nft.mint{value: 0.002 ether}(2);
        vm.prank(address(0xB0B));
        vm.expectRevert(GoblinNFT.NotHolder.selector);
        nft.refund(1);
        uint256 before = alice.balance;
        vm.prank(alice);
        nft.refund(1);
        assertEq(alice.balance - before, 0.001 ether);
        assertEq(nft.liveSupply(), 1);
        vm.prank(alice);
        vm.expectRevert(GoblinNFT.NotHolder.selector);
        nft.refund(1); // burned: no double refund
    }

    function testSelloutLocksRefundsAndRelease() public {
        _sellOut();
        assertTrue(nft.soldOut());
        assertEq(address(nft).balance, 10 ether);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(GoblinNFT.MintClosed.selector);
        nft.mint{value: 0.001 ether}(1);
        address holder = nft.ownerOf(1);
        vm.prank(holder);
        vm.expectRevert(GoblinNFT.RefundsClosed.selector);
        nft.refund(1);

        // unset targets: release refuses
        vm.expectRevert(GoblinNFT.TargetsNotSet.selector);
        nft.release();
        vm.prank(alice);
        vm.expectRevert();
        nft.setLaunchTargets(pol, reserve, vrf);
        vm.prank(owner);
        vm.expectRevert(GoblinNFT.ZeroAddress.selector);
        nft.setLaunchTargets(address(0), reserve, vrf);

        vm.prank(owner);
        nft.setLaunchTargets(pol, reserve, vrf);
        // review window: refunds open, release blocked
        assertTrue(nft.refundsOpen());
        vm.prank(holder);
        nft.refund(1);
        vm.expectRevert(GoblinNFT.ReviewPending.selector);
        nft.release();

        vm.warp(vm.getBlockTimestamp() + 7 days);
        assertFalse(nft.refundsOpen());
        nft.release();
        uint256 amount = 9999 * 0.001 ether;
        assertEq(nft.polOwed(), amount / 2);
        assertEq(nft.reserveOwed(), (amount * 40) / 100);
        assertEq(nft.polOwed() + nft.reserveOwed() + nft.vrfOwed(), amount);
        vm.expectRevert(GoblinNFT.AlreadyReleased.selector);
        nft.release();
        vm.prank(owner);
        vm.expectRevert(GoblinNFT.AlreadyReleased.selector);
        nft.setLaunchTargets(pol, reserve, vrf);

        vm.prank(pol);
        nft.claimRelease();
        vm.prank(reserve);
        nft.claimRelease();
        vm.prank(vrf);
        nft.claimRelease();
        assertEq(pol.balance + reserve.balance + vrf.balance, amount);
        assertEq(address(nft).balance, 0);
        vm.prank(pol);
        vm.expectRevert(GoblinNFT.NothingOwed.selector);
        nft.claimRelease();
        vm.warp(vm.getBlockTimestamp() + 365 days);
        vm.prank(nft.ownerOf(2));
        vm.expectRevert(GoblinNFT.RefundsClosed.selector);
        nft.refund(2);
    }

    function testRefundsReopenAfter90Days() public {
        _sellOut();
        vm.warp(vm.getBlockTimestamp() + 90 days);
        address holder = nft.ownerOf(5);
        uint256 b = holder.balance;
        vm.prank(holder);
        nft.refund(5);
        assertEq(holder.balance - b, 0.001 ether);
    }

    function testRevealAndTokenURI() public {
        vm.prank(alice);
        nft.mint{value: 0.001 ether}(1);
        string memory hidden = nft.tokenURI(1);
        assertGt(bytes(hidden).length, 100);
        vm.expectRevert(GoblinNFT.RevealNotReady.selector);
        nft.reveal();
        _sellOut2();
        vm.roll(vm.getBlockNumber() + 2);
        nft.reveal();
        assertTrue(nft.revealed());
        GoblinArt.Traits memory t = nft.traitsOf(1);
        assertLt(t.skin, 6);
        assertLt(t.rarity, 5);
        assertGt(bytes(nft.tokenURI(1)).length, bytes(hidden).length);
        vm.expectRevert(GoblinNFT.AlreadyRevealed.selector);
        nft.reveal();
    }

    function testRevealRearmsAfter256Blocks() public {
        _sellOut();
        vm.roll(vm.getBlockNumber() + 400);
        nft.reveal();
        assertFalse(nft.revealed());
        vm.roll(vm.getBlockNumber() + 2);
        nft.reveal();
        assertTrue(nft.revealed());
    }

    function _sellOut2() internal {
        // alice holds 1; fill the remaining 9,999
        for (uint256 i = 0; i < 500; ++i) {
            address m = address(uint160(0x20000 + i));
            uint256 q = i == 499 ? 19 : 20;
            vm.deal(m, q * 0.001 ether);
            vm.prank(m);
            nft.mint{value: q * 0.001 ether}(q);
        }
        assertTrue(nft.soldOut());
    }

    function testRevenue() public {
        _sellOut();
        nft.depositRevenue{value: 1 ether}();
        vm.prank(owner);
        nft.setLaunchTargets(pol, reserve, vrf);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        nft.release();
        vm.deal(address(this), 10 ether);
        nft.depositRevenue{value: 10 ether}();
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        address holder = nft.ownerOf(1);
        uint256 b = holder.balance;
        vm.prank(holder);
        nft.claimRevenue(ids);
        assertEq(holder.balance - b, 0.0011 ether);
        vm.prank(holder);
        vm.expectRevert(GoblinNFT.NothingOwed.selector);
        nft.claimRevenue(ids);
        vm.prank(alice);
        vm.expectRevert(GoblinNFT.NotHolder.selector);
        nft.claimRevenue(ids);
    }
}
