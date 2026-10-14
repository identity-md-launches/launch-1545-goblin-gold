// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Audit930Fixture} from "../audit930ea061/GenesisAndBinding.t.sol";
import {BagGacha} from "../../src/BagGacha.sol";
import {TwapOracle} from "../../src/TwapOracle.sol";

contract GenesisDarkTest is Audit930Fixture {
    function setUp() public {
        _setup(100 ether);
        gold.mint(address(vault), vault.genesisSupply());
    }

    function _keeperSwap(uint256 timestamp) internal {
        vm.warp(timestamp);
        vm.roll(vm.getBlockNumber() + 1);
        _swap(trader, false, -1e9); // small exact-input GOLD sell; no early-buy tax
    }

    function testGenesisOpensFourHoursAfterFirstPostSeedSwapWithFiftyMinuteKeeper() public {
        uint256 first = vm.getBlockTimestamp() + 1 hours;
        _keeperSwap(first);
        for (uint256 i = 1; i <= 4; ++i) {
            _keeperSwap(first + i * 50 minutes);
        }
        vm.warp(first + 4 hours - 1);
        assertEq(hook.liquidityAt(4 hours), 0);
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, HOOK_ADDRESS));
        oracle.genesisValueAndCap(1 ether);
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, HOOK_ADDRESS));
        oracle.polTokensForEth(0.1 ether);
        (uint256 total,) = gacha.spinPrice();
        vm.expectRevert(BagGacha.NothingToDraw.selector);
        gacha.spin{value: total}();
        vm.warp(first + 4 hours);
        assertGt(hook.liquidityAt(4 hours), 0);
        (uint256 value, uint256 cap) = oracle.genesisValueAndCap(1 ether);
        assertGt(value, 0);
        assertGt(cap, 0);
        assertGt(oracle.polTokensForEth(0.1 ether), 0);
        assertGt(gacha.spin{value: total}(), 0);
        (,,,,, uint256 genesisBps) = gacha.currentRequest();
        assertEq(genesisBps, 10_000);
    }

    function testKeeperRestoresSeasonedLaneAfterStaleness() public {
        uint256 first = vm.getBlockTimestamp() + 1 hours;
        _keeperSwap(first);
        for (uint256 i = 1; i <= 5; ++i) {
            _keeperSwap(first + i * 50 minutes);
        }
        uint256 last = vm.getBlockTimestamp();
        assertGt(oracle.polTokensForEth(0.1 ether), 0);
        vm.warp(last + 3601);
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.StalePool.selector, HOOK_ADDRESS));
        oracle.genesisValueAndCap(1 ether);
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.StalePool.selector, HOOK_ADDRESS));
        oracle.polTokensForEth(0.1 ether);
        (uint256 total,) = gacha.spinPrice();
        vm.expectRevert(BagGacha.NothingToDraw.selector);
        gacha.spin{value: total}();
        _keeperSwap(vm.getBlockTimestamp());
        assertGt(oracle.polTokensForEth(0.1 ether), 0);
        assertGt(gacha.spin{value: total}(), 0);
    }
}
