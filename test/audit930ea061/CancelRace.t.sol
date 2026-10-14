// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BagGachaTest} from "../BagGacha.t.sol";
import {BagGacha} from "../../src/BagGacha.sol";

/// @notice Audit 930ea061 finding 6: at the cancellation deadline every word is ignored, regardless of ordering.
contract CancelRaceTest is BagGachaTest {
    function _request() internal returns (uint256 id, uint256 deadline) {
        plat.mint(address(genesis), genesis.genesisSupply());
        _seal(10 ether);
        vm.warp(start + 2 days);
        (uint256 total,) = gacha.spinPrice();
        vm.prank(spinner);
        id = gacha.spin{value: total}();
        deadline = vm.getBlockTimestamp() + gacha.CANCEL_DELAY();
    }

    function testFulfilmentOneSecondBeforeDeadlineStillDrawsAfterIt() public {
        (uint256 id, uint256 deadline) = _request();
        vm.warp(deadline - 1);
        vrf.fulfill(address(gacha), id, 42);
        (,, bool fulfilled,,,) = gacha.currentRequest();
        assertTrue(fulfilled);
        vm.warp(deadline);
        vm.expectRevert(BagGacha.AlreadyFulfilled.selector);
        gacha.cancelRequest();
        gacha.draw();
        _conserved();
    }

    function testFuzzAtOrAfterDeadlineBothTransactionOrdersCancel(uint256 word, uint32 lateness, bool fulfillFirst)
        public
    {
        (uint256 id, uint256 deadline) = _request();
        vm.warp(deadline + uint256(lateness));
        uint256 emittedBefore = genesis.emitted();
        assertGt(emittedBefore, 0);
        if (fulfillFirst) {
            vrf.fulfill(address(gacha), id, word);
            (,, bool fulfilled,,,) = gacha.currentRequest();
            assertFalse(fulfilled, "no late winning word can be accepted");
            vm.expectRevert(BagGacha.NotFulfilled.selector);
            gacha.draw();
        }
        gacha.cancelRequest();
        vrf.fulfill(address(gacha), id, word);
        assertFalse(gacha.pending());
        assertEq(gacha.locked(), 0);
        assertEq(gacha.credits(spinner), gacha.P());
        assertEq(genesis.emitted(), 0);
        _conserved();
    }

    function testExactDeadlineIgnoresFulfilmentBeforeCancelEvenWhenPaused() public {
        (uint256 id, uint256 deadline) = _request();
        vm.warp(deadline);
        oracle.breakToken(address(plat), true);
        oracle.breakToken(address(tokA), true);
        vrf.fulfill(address(gacha), id, type(uint256).max);
        (,, bool fulfilled,,,) = gacha.currentRequest();
        assertFalse(fulfilled);
        vm.prank(address(0xBEEF));
        gacha.cancelRequest();
        assertEq(gacha.credits(spinner), gacha.P());
        assertEq(genesis.emitted(), 0);
        _conserved();
    }
}
