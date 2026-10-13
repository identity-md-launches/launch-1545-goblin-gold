// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {GoblinNFT} from "../src/GoblinNFT.sol";
import {GoblinNFTTest} from "./GoblinNFT.t.sol";

/// @notice Behaviour of the deployed GoblinNFT (launch-1616 commit dbd66796): revenue arriving before `release()`
///         is pooled and split equally across the tokens live at release; afterwards it accrues immediately.
contract GoblinNFTDeployedTest is GoblinNFTTest {
    function testPreReleaseRevenueIsDeferredAndNotClaimable() public {
        vm.prank(alice);
        nft.mint{value: 0.003 ether}(3);
        nft.depositRevenue{value: 10 wei}();
        assertEq(nft.deferredRevenue(), 10);
        assertEq(nft.revenuePerToken(), 0);
        assertEq(nft.retainedRevenue(), 0);
        assertEq(nft.pendingRevenue(1), 3); // provisional equal share only
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.prank(alice);
        assertEq(nft.claimRevenue(ids), 0);
        assertEq(nft.totalRevenueClaimed(), 0);
        // a refund forfeits nothing and leaves the pool for the remaining holders
        vm.prank(alice);
        nft.refund(1);
        assertEq(nft.deferredRevenue(), 10);
        assertEq(nft.pendingRevenue(2), 5);
        assertEq(address(nft).balance, 2 * 0.001 ether + 10);
    }

    function testReleaseSplitsDeferredPoolAcrossLiveTokensThenAccruesImmediately() public {
        _sellOut();
        nft.depositRevenue{value: 20_003 wei}();
        vm.prank(owner);
        nft.setLaunchTargets(pol, reserve, vrf);
        // one holder exits during the review: 9,999 live tokens share the pool at release
        vm.prank(address(uint160(0x10000)));
        nft.refund(1);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        nft.release();
        assertEq(nft.deferredRevenue(), 0);
        assertEq(nft.revenuePerToken(), 2);
        assertEq(nft.retainedRevenue(), 20_003 - 2 * 9_999);
        assertEq(nft.pendingRevenue(2), 2);
        nft.depositRevenue{value: 9_999 wei}();
        assertEq(nft.pendingRevenue(2), 3);
        uint256[] memory ids = new uint256[](1);
        ids[0] = 2;
        vm.prank(address(uint160(0x10000)));
        assertEq(nft.claimRevenue(ids), 3);
        vm.prank(address(uint160(0x10000)));
        vm.expectRevert(GoblinNFT.NothingOwed.selector);
        nft.claimRevenue(ids);
    }

    function testFuzzDeferredRevenueConservation(uint256 n, uint256 amount, uint256 burned) public {
        n = bound(n, 1, 20);
        amount = bound(amount, 1, 100 ether);
        burned = bound(burned, 0, n - 1);
        vm.deal(address(this), amount);
        vm.prank(alice);
        nft.mint{value: n * 0.001 ether}(n);
        nft.depositRevenue{value: amount}();
        for (uint256 id = 1; id <= burned; ++id) {
            vm.prank(alice);
            nft.refund(id);
        }
        assertEq(nft.deferredRevenue(), amount);
        assertEq(nft.totalRevenueDeposited(), amount);
        assertEq(address(nft).balance, (n - burned) * 0.001 ether + amount);
        uint256 pending;
        for (uint256 id = burned + 1; id <= n; ++id) {
            pending += nft.pendingRevenue(id);
        }
        assertLe(pending, amount);
        assertGe(pending + (n - burned), amount);
    }
}
