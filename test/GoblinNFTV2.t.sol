// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {GoblinNFT} from "../src/GoblinNFT.sol";
import {DeployGoblinNFT} from "../script/DeployGoblinNFT.s.sol";
import {GoblinNFTTest, ReleaseReceiver} from "./GoblinNFT.t.sol";

contract NFTReenter {
    GoblinNFT public nft;
    bool public reject;
    bool public reentered;

    constructor(GoblinNFT nft_) {
        nft = nft_;
    }

    function setReject(bool value) external {
        reject = value;
    }

    receive() external payable {
        if (reject) revert("reject");
        try nft.refund(1) {
            reentered = true;
        } catch {}
    }
}

contract GoblinNFTV2Test is GoblinNFTTest {
    function testDeploymentOwnerIsExplicit() public {
        DeployGoblinNFT factory = new DeployGoblinNFT();
        GoblinNFT instance = factory.deploy(alice);
        assertEq(instance.owner(), alice);
        vm.expectRevert("owner required");
        factory.deploy(address(0));
    }

    function testRepeatedReviewRestartsFullSevenDaysAndOwnersCanTransfer() public {
        _sellOut();
        vm.prank(owner);
        nft.setLaunchTargets(pol, reserve, vrf);
        vm.warp(vm.getBlockTimestamp() + 7 days - 1);
        vm.prank(owner);
        nft.setLaunchTargets(vrf, reserve, pol);
        vm.warp(vm.getBlockTimestamp() + 7 days - 1);
        assertTrue(nft.refundsOpen());
        vm.prank(nft.ownerOf(1));
        nft.refund(1);
        vm.expectRevert(GoblinNFT.ReviewPending.selector);
        nft.release();
        vm.warp(vm.getBlockTimestamp() + 1);
        nft.release();
        assertFalse(nft.refundsOpen());
    }

    function testTargetsRequireCodeInEverySlotAndRenounceOnlyAfterRelease() public {
        vm.startPrank(owner);
        vm.expectRevert(GoblinNFT.NotReleased.selector);
        nft.renounceOwnership();
        vm.expectRevert(GoblinNFT.TargetNotContract.selector);
        nft.setLaunchTargets(alice, reserve, vrf);
        vm.expectRevert(GoblinNFT.TargetNotContract.selector);
        nft.setLaunchTargets(pol, alice, vrf);
        vm.expectRevert(GoblinNFT.TargetNotContract.selector);
        nft.setLaunchTargets(pol, reserve, alice);
        vm.stopPrank();
        _sellOut();
        vm.prank(owner);
        nft.setLaunchTargets(pol, reserve, vrf);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        nft.release();
        vm.prank(owner);
        nft.renounceOwnership();
        assertEq(nft.owner(), address(0));
    }

    function testSharedReleaseTargetAndRevenueExcludedFromSplit() public {
        _sellOut();
        nft.depositRevenue{value: 3 ether}();
        vm.prank(owner);
        nft.setLaunchTargets(pol, pol, pol);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        nft.release();
        assertEq(nft.releaseOwed(pol), 10 ether);
        vm.prank(pol);
        assertEq(nft.claimRelease(), 10 ether);
        assertEq(address(nft).balance, 3 ether);
        assertEq(nft.pendingRevenue(1), 0.0003 ether);
    }

    function testFuzzMintWalletCap(uint256 quantity, uint256 second) public {
        quantity = bound(quantity, 1, 20);
        second = bound(second, 1, 21);
        vm.startPrank(alice);
        nft.mint{value: quantity * 0.001 ether}(quantity);
        nft.refund(1);
        if (quantity + second > 20) vm.expectRevert(GoblinNFT.WalletLimit.selector);
        nft.mint{value: second * 0.001 ether}(second);
        assertLe(nft.mintedBy(alice), 20);
        vm.stopPrank();
    }
}
