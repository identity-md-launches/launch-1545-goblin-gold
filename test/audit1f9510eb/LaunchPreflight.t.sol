// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Audit930Fixture} from "../audit930ea061/GenesisAndBinding.t.sol";
import {BagGacha} from "../../src/BagGacha.sol";
import {GenesisVault} from "../../src/GenesisVault.sol";
import {GoldHook} from "../../src/GoldHook.sol";
import {POLManager} from "../../src/POLManager.sol";
import {CheckLaunch} from "../../script/CheckLaunch.s.sol";

contract LaunchPreflightTest is Audit930Fixture {
    CheckLaunch check;

    function setUp() public {
        _setup(100 ether);
        check = new CheckLaunch();
        vm.mockCall(
            HOOK_ADDRESS,
            abi.encodeWithSelector(hook.GACHA_RUNTIME_CODE_HASH.selector),
            abi.encode(address(gacha).codehash)
        );
        gold.mint(address(vault), vault.genesisSupply());
    }

    function _run() internal {
        check.run(HOOK_ADDRESS, address(gacha), address(vrf), address(this), 1);
    }

    function _pair(address wrapper, address pol_) internal {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        vault = new GenesisVault(address(gold), address(oracle), predicted, 1, 1e24, 1e22, address(this));
        gacha =
            new BagGacha(address(oracle), address(vault), NFT_ADDRESS, wrapper, pol_, address(this), 1, address(this));
        gold.mint(address(vault), vault.genesisSupply());
    }

    function testMintEscrowWireNowRejectsGachaMismatch() public {
        POLManager badPol =
            new POLManager(address(manager), address(gold), HOOK_ADDRESS, address(oracle), address(vault));
        _pair(address(vrf), address(badPol));
        _refuseBadPol(address(badPol));
    }

    function testWrongPoolManagerWireRejectedBeforeAndAfterReview() public {
        POLManager badPol = new POLManager(address(oracle), address(gold), HOOK_ADDRESS, address(oracle), NFT_ADDRESS);
        _pair(address(vrf), address(badPol));
        _refuseBadPol(address(badPol));
    }

    function _refuseBadPol(address badPol) internal {
        vm.expectRevert(abi.encodeWithSelector(CheckLaunch.BindNotReady.selector, GoldHook.GachaMismatch.selector));
        _run();
        assertFalse(nft.targetsSet(), "preflight refuses before naming");
        nft.setLaunchTargets(badPol, address(gacha), address(gacha));
        assertEq(hook.bindCheck(address(gacha)), GoldHook.GachaMismatch.selector);
        vm.expectRevert(GoldHook.GachaMismatch.selector);
        hook.bindGacha(address(gacha));
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.expectRevert(GoldHook.GachaMismatch.selector);
        hook.bindGacha(address(gacha));
        assertEq(hook.gacha(), address(0));
    }

    function testExactFundingPasses() public {
        _run();
        assertEq(hook.gacha(), address(gacha));
    }

    function testOneWeiDonationPassesAndRemainsInVault() public {
        gold.mint(address(vault), 1);
        _run();
        assertEq(hook.gacha(), address(gacha));
        assertEq(gold.balanceOf(address(vault)), vault.genesisSupply() + 1);
    }

    function testUnderfundingFailsBeforeNaming() public {
        // A fresh vault with one wei less than its commitment, without impersonating the vault to withdraw.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        vault = new GenesisVault(address(gold), address(oracle), predicted, 1, 1e24, 1e22, address(this));
        gacha = new BagGacha(
            address(oracle), address(vault), NFT_ADDRESS, address(vrf), address(pol), address(this), 1, address(this)
        );
        gold.mint(address(vault), vault.genesisSupply() - 1);
        vm.expectRevert(CheckLaunch.WrongFunding.selector);
        _run();
        assertFalse(nft.targetsSet());
    }

    function testWrongExpectedWrapperCuratorAndStartAreRejected() public {
        vm.expectRevert(CheckLaunch.WrongWiring.selector);
        check.run(HOOK_ADDRESS, address(gacha), address(oracle), address(this), 1);
        vm.expectRevert(CheckLaunch.WrongWiring.selector);
        check.run(HOOK_ADDRESS, address(gacha), address(vrf), address(pol), 1);
        vm.expectRevert(CheckLaunch.WrongWiring.selector);
        check.run(HOOK_ADDRESS, address(gacha), address(vrf), address(this), 2);
        assertFalse(nft.targetsSet());
    }

    function testVaultCuratorMismatchRejected() public {
        vm.mockCall(address(vault), abi.encodeWithSelector(vault.curator.selector), abi.encode(address(pol)));
        vm.expectRevert(CheckLaunch.WrongWiring.selector);
        _run();
        assertFalse(nft.targetsSet());
    }

    function testConstructorWrapperWithoutPriceFunctionRejected() public {
        _pair(address(oracle), address(pol));
        // Even if an operator mistakenly supplies this same wrong address, the live price call catches it.
        vm.expectRevert(CheckLaunch.WrongWiring.selector);
        check.run(HOOK_ADDRESS, address(gacha), address(oracle), address(this), 1);
        assertFalse(nft.targetsSet());
    }

    function testZeroFeeAndNonPositiveSpinPriceRejected() public {
        vm.mockCall(
            address(vrf), abi.encodeWithSelector(vrf.calculateRequestPriceNative.selector), abi.encode(uint256(0))
        );
        vm.expectRevert(CheckLaunch.WrongWiring.selector);
        _run();
        vm.clearMockedCalls();
        vm.mockCall(
            HOOK_ADDRESS,
            abi.encodeWithSelector(hook.GACHA_RUNTIME_CODE_HASH.selector),
            abi.encode(address(gacha).codehash)
        );
        vm.mockCall(
            address(gacha), abi.encodeWithSelector(gacha.spinPrice.selector), abi.encode(uint256(1), uint256(1))
        );
        vm.expectRevert(CheckLaunch.WrongWiring.selector);
        _run();
        vm.mockCall(
            address(gacha), abi.encodeWithSelector(gacha.spinPrice.selector), abi.encode(uint256(1), uint256(2))
        );
        vm.expectRevert(CheckLaunch.WrongWiring.selector);
        _run();
        assertFalse(nft.targetsSet());
    }

    function testPriceRevertFailsBeforeNaming() public {
        vm.mockCallRevert(
            address(vrf), abi.encodeWithSelector(vrf.calculateRequestPriceNative.selector), "disabled wrapper"
        );
        vm.expectRevert(CheckLaunch.WrongWiring.selector);
        _run();
        assertFalse(nft.targetsSet());
    }
}
