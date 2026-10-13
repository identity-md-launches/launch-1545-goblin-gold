// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BagGachaTest} from "./BagGacha.t.sol";
import {BagGacha} from "../src/BagGacha.sol";
import {MockERC20} from "./mocks/Mocks.sol";

/// @notice v3.1 payout cap: a single draw pays at most the oracle's cap per token (5% of that token pool's ETH-side
///         depth at the TWAP). When it binds, the capped portion is paid from the Bag and the rest stays in the Bag.
///         The mock oracle's `setCap` stands in for the pool depth; `TwapOracle.t.sol` covers the depth arithmetic.
contract PayoutCapTest is BagGachaTest {
    function _drawnBag(uint256 allocationId) internal view returns (uint256 bagId, uint256 value) {
        (, bagId, value,,,,,) = gacha.allocations(allocationId);
    }

    function _amounts(uint256 bagId) internal view returns (uint256[] memory amounts, BagGacha.BagStatus status) {
        (, status,,, amounts) = gacha.bagInfo(bagId);
    }

    function testCapBindsSplitsBagAndKeepPaysOnlyTheCappedPortion() public {
        uint256 bagId = _seal(50e18); // 0.05 ETH = 5P, large tier
        oracle.setCap(address(tokA), 0.02 ether); // pool depth 0.4 ETH: a draw pays at most 0.02 ETH of tokA
        vm.warp(start + 2 days);
        uint256 sharesBefore = gacha.depositorShares(dep);
        uint256 allocationId;
        {
            (uint256 total,) = gacha.spinPrice();
            vm.prank(spinner);
            uint256 id = gacha.spin{value: total}();
            // the snapshot commits the capped value and the reserve earmark follows it
            (uint256[] memory ids, uint256[] memory values,) = gacha.snapshot();
            assertEq(ids.length, 1);
            assertEq(values[0], 0.02 ether);
            (,,, uint256 liability,,) = gacha.currentRequest();
            assertEq(liability, 0.019 ether);
            vrf.fulfill(address(gacha), id, 42);
            allocationId = gacha.draw();
            _conserved();
        }
        (uint256 wonId, uint256 value) = _drawnBag(allocationId);
        assertEq(value, 0.02 ether);
        assertEq(wonId, bagId + 1, "the capped portion is a new Bag");
        {
            (uint256[] memory won, BagGacha.BagStatus wonStatus) = _amounts(wonId);
            (uint256[] memory rest, BagGacha.BagStatus restStatus) = _amounts(bagId);
            assertEq(won[0], 20e18);
            assertEq(rest[0], 30e18, "the remainder stays in the original Bag");
            assertEq(uint256(wonStatus), uint256(BagGacha.BagStatus.Drawn));
            assertEq(uint256(restStatus), uint256(BagGacha.BagStatus.Listed));
        }
        assertEq(gacha.activeCount(), 1);
        assertEq(gacha.depositorShares(dep), sharesBefore, "shares only move with the won portion");

        vm.prank(spinner);
        gacha.choose(allocationId, true);
        _conserved();
        assertEq(gacha.credits(dep), 0.019 ether, "depositor is paid 95% of the capped value");
        assertEq(gacha.locked(), 0);
        vm.prank(spinner);
        gacha.claimBag(wonId);
        assertEq(tokA.balanceOf(spinner), 20e18);
        assertEq(tokA.balanceOf(address(gacha)), 30e18);
        vm.prank(spinner);
        vm.expectRevert(BagGacha.NotSpinner.selector);
        gacha.claimBag(bagId);
        // the depositor still owns the remainder: it can be withdrawn (0.5% of its 0.03 ETH value) or drawn again
        uint256 sharesAfterKeep = gacha.depositorShares(dep);
        assertLt(sharesAfterKeep, sharesBefore);
        assertGt(sharesAfterKeep, 0);
        vm.deal(dep, 1 ether);
        vm.prank(dep);
        gacha.withdraw{value: 0.00015 ether}(bagId);
        assertEq(tokA.balanceOf(dep), 1_000e18 - 20e18);
        assertEq(gacha.depositorShares(dep), 0);
        assertEq(gacha.activeCount(), 0);
        _conserved();
    }

    function testCapBindsAndBuybackRelistsOnlyTheWonPortionWhileTheRemainderStaysDrawable() public {
        uint256 bagId = _seal(50e18);
        oracle.setCap(address(tokA), 0.02 ether);
        vm.warp(start + 2 days);
        uint256 allocationId = _spinAndDraw(7);
        (uint256 wonId,) = _drawnBag(allocationId);
        vm.prank(spinner);
        gacha.choose(allocationId, false);
        _conserved();
        assertEq(gacha.credits(spinner), 0.0176 ether + 1, "winner is paid 88% of the capped value");
        (, BagGacha.BagStatus wonStatus) = _amounts(wonId);
        assertEq(uint256(wonStatus), uint256(BagGacha.BagStatus.Listed));
        assertEq(gacha.activeCount(), 2);
        assertEq(tokA.balanceOf(address(gacha)), 50e18, "nothing left the vault");
        // the won portion matures again, the remainder is still mature: the next draw caps the remainder again
        (uint256 total,) = gacha.spinPrice();
        vm.prank(spinner);
        uint256 id = gacha.spin{value: total}();
        (uint256[] memory ids, uint256[] memory values,) = gacha.snapshot();
        assertEq(ids.length, 1);
        assertEq(ids[0], bagId);
        assertEq(values[0], 0.02 ether);
        vrf.fulfill(address(gacha), id, 8);
        uint256 second = gacha.draw();
        (uint256 wonId2, uint256 value2) = _drawnBag(second);
        assertEq(value2, 0.02 ether);
        assertEq(wonId2, wonId + 1);
        (uint256[] memory rest,) = _amounts(bagId);
        assertEq(rest[0], 10e18);
        vm.expectRevert(BagGacha.WindowOpen.selector);
        gacha.finalize(second);
        vm.warp(vm.getBlockTimestamp() + 5 minutes);
        gacha.finalize(second);
        assertEq(gacha.bagWinner(wonId2), spinner);
        _conserved();
    }

    function testCapAtExactlyTheValueDoesNotSplitAndOneWeiBelowDoes() public {
        uint256 bagId = _seal(50e18);
        oracle.setCap(address(tokA), 0.05 ether);
        vm.warp(start + 2 days);
        uint256 allocationId = _spinAndDraw(1);
        (uint256 drawn, uint256 value) = _drawnBag(allocationId);
        assertEq(drawn, bagId, "value == cap: the whole Bag is drawn");
        assertEq(value, 0.05 ether);
        vm.prank(spinner);
        gacha.choose(allocationId, false); // back to the listing
        oracle.setCap(address(tokA), 0.05 ether - 1);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        allocationId = _spinAndDraw(2);
        (drawn, value) = _drawnBag(allocationId);
        assertEq(drawn, bagId + 1, "one wei over the cap splits");
        assertLe(value, 0.05 ether - 1);
        assertGt(value, 0.0499 ether);
        (uint256[] memory rest,) = _amounts(bagId);
        assertGt(rest[0], 0);
        assertLt(rest[0], 1e15);
        _conserved();
    }

    function testCapIsPerTokenAndAnUncappedTokenLeavesNothingBehind() public {
        MockERC20 tokB = new MockERC20("B");
        oracle.set(address(tokB), 1e15);
        tokB.mint(dep, 100e18);
        vm.prank(dep);
        tokB.approve(address(gacha), type(uint256).max);
        address[] memory t = new address[](2);
        t[0] = address(tokA);
        t[1] = address(tokB);
        uint256[] memory a = new uint256[](2);
        a[0] = 20e18; // 0.02 ETH, capped to 0.01
        a[1] = 20e18; // 0.02 ETH, uncapped
        vm.prank(dep);
        uint256 bagId = gacha.seal(t, a);
        oracle.setCap(address(tokA), 0.01 ether);
        (uint256 value, uint256 fullValue, uint256[] memory amounts, bool capped) = gacha.bagPayout(bagId);
        assertTrue(capped);
        assertEq(value, 0.03 ether);
        assertEq(fullValue, 0.04 ether);
        assertEq(amounts[0], 10e18);
        assertEq(amounts[1], 20e18);
        vm.warp(start + 2 days);
        uint256 allocationId = _spinAndDraw(3);
        (uint256 wonId, uint256 drawnValue) = _drawnBag(allocationId);
        assertEq(drawnValue, 0.03 ether);
        (uint256[] memory rest,) = _amounts(bagId);
        assertEq(rest[0], 10e18);
        assertEq(rest[1], 0);
        vm.prank(spinner);
        gacha.choose(allocationId, true);
        vm.prank(spinner);
        gacha.claimBag(wonId);
        assertEq(tokA.balanceOf(spinner), 10e18);
        assertEq(tokB.balanceOf(spinner), 20e18);
        // the remainder (tokA only, a zero tokB line) is still withdrawable
        vm.deal(dep, 1 ether);
        vm.prank(dep);
        gacha.withdraw{value: 0.00005 ether}(bagId);
        assertEq(tokA.balanceOf(dep), 1_000e18 - 10e18);
        assertEq(tokB.balanceOf(dep), 80e18);
        _conserved();
    }

    function testCapChangesAfterTheRequestDoNotRewriteTheCommittedSplit() public {
        uint256 bagId = _seal(50e18);
        oracle.setCap(address(tokA), 0.02 ether);
        vm.warp(start + 2 days);
        (uint256 total,) = gacha.spinPrice();
        vm.prank(spinner);
        uint256 id = gacha.spin{value: total}();
        oracle.setCap(address(tokA), 0); // the pool got deep after the request
        vrf.fulfill(address(gacha), id, 5);
        uint256 allocationId = gacha.draw();
        (uint256 wonId, uint256 value) = _drawnBag(allocationId);
        assertEq(value, 0.02 ether);
        assertEq(wonId, bagId + 1);
        // an old split cannot leak into a later snapshot: the remainder is drawn whole once the cap is gone
        vm.warp(vm.getBlockTimestamp() + 5 minutes);
        gacha.finalize(allocationId);
        allocationId = _spinAndDraw(6);
        (uint256 drawn, uint256 v2) = _drawnBag(allocationId);
        assertEq(drawn, bagId);
        assertEq(v2, 0.03 ether);
        _conserved();
    }

    function testGenesisQuoteIsCappedAndTheSurplusStaysInTheVault() public {
        plat.mint(address(genesis), 800_000_000e18);
        vm.warp(start + 3 days);
        // uncapped quote: 0.0092 ETH of PLAT at 1e-6 ETH each
        assertEq(genesis.quote(false), 9.2e21);
        oracle.setCap(address(plat), 0.005 ether); // GOLD pool ETH-side depth of 0.1 ETH
        (uint256 total,) = gacha.spinPrice();
        vm.prank(spinner);
        uint256 id = gacha.spin{value: total}();
        assertEq(genesis.emitted(), 5e21, "only the capped tokens stay committed");
        (,,, uint256 liability,,) = gacha.currentRequest();
        assertEq(liability, 0.0044 ether);
        vrf.fulfill(address(gacha), id, 11);
        uint256 allocationId = gacha.draw();
        (, uint256 bag, uint256 value, uint256 gTokens,,,,) = gacha.allocations(allocationId);
        assertEq(bag, 0);
        assertEq(value, 0.005 ether);
        assertEq(gTokens, 5e21);
        vm.prank(spinner);
        gacha.choose(allocationId, true);
        vm.prank(spinner);
        genesis.claim();
        assertEq(plat.balanceOf(spinner), 5e21);
        assertEq(genesis.emitted(), 5e21);
        _conserved();
        // buyback pays 88% of the capped value and returns the capped tokens
        allocationId = _spinAndDraw(12);
        (,, value, gTokens,,,,) = gacha.allocations(allocationId);
        assertEq(value, 0.005 ether);
        vm.prank(spinner);
        gacha.choose(allocationId, false);
        assertEq(gacha.credits(spinner), 0.0044 ether + 1);
        assertEq(genesis.emitted(), 5e21);
        _conserved();
        // free spins are capped the same way
        address holder = nft.ownerOf(1);
        vm.prank(holder);
        id = gacha.freeSpin(1);
        vrf.fulfill(address(gacha), id, 13);
        allocationId = gacha.draw();
        (,, value, gTokens,,,,) = gacha.allocations(allocationId);
        assertEq(value, 0.005 ether);
        assertEq(gTokens, 5e21);
        _conserved();
    }

    function testFuzzCappedPayoutNeverExceedsCapAndTokensAreConserved(uint256 amount, uint256 cap, bool keep) public {
        gacha.fundReserve{value: 10 ether}();
        amount = bound(amount, 3.1e18, 200e18);
        uint256 full = (amount * 1e15) / 1e18;
        // a capped value that rounds below the 0.3P small-tier floor is not drawable, so keep the cap above it
        cap = bound(cap, 0.0031 ether, full);
        uint256 bagId = _seal(amount);
        oracle.setCap(address(tokA), cap);
        vm.warp(start + 3 days);
        uint256 allocationId = _spinAndDraw(amount ^ cap);
        (uint256 drawn, uint256 value) = _drawnBag(allocationId);
        assertLe(value, cap);
        if (cap == full) {
            assertEq(drawn, bagId);
        } else {
            assertEq(drawn, bagId + 1);
            assertGe(value + 1, cap); // rounding leaves at most one wei of value below the cap
            (uint256[] memory won,) = _amounts(drawn);
            (uint256[] memory rest,) = _amounts(bagId);
            assertEq(won[0] + rest[0], amount);
        }
        vm.prank(spinner);
        gacha.choose(allocationId, keep);
        _conserved();
        if (keep) assertEq(gacha.credits(dep), (value * 9500) / 10_000);
        else assertEq(gacha.credits(spinner), (value * 8800) / 10_000 + 1);
        assertEq(tokA.balanceOf(address(gacha)), amount);
    }
}
