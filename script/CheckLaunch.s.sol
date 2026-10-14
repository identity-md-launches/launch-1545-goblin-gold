// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {GoldHook} from "../src/GoldHook.sol";
import {BagGacha} from "../src/BagGacha.sol";
import {GenesisVault} from "../src/GenesisVault.sol";
import {GoblinNFT} from "../src/GoblinNFT.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Run on a fork BEFORE the NFT owner sends setLaunchTargets. No broadcast, key, or environment reads.
///         Naming is simulated so bindCheck can check every precondition, including the prospective NFT targets.
contract CheckLaunch is Script {
    error WrongRuntimeCode();
    error WrongFunding();
    error WrongPermissions();
    error BindNotReady(bytes4 reason);

    function run(address hookAddress, address gachaAddress) external {
        GoldHook hook = GoldHook(payable(hookAddress));
        if (gachaAddress.codehash != hook.GACHA_RUNTIME_CODE_HASH()) revert WrongRuntimeCode();
        if (!hook.hasRequiredFlags() || !hook.initialized()) revert WrongPermissions();
        BagGacha gacha = BagGacha(payable(gachaAddress));
        GenesisVault vault = GenesisVault(address(gacha.genesis()));
        if (IERC20(hook.token()).balanceOf(address(vault)) != vault.genesisSupply()) revert WrongFunding();
        GoblinNFT nft = GoblinNFT(hook.NFT());
        address pol = address(gacha.polManager());
        vm.prank(nft.owner());
        nft.setLaunchTargets(pol, gachaAddress, gachaAddress);
        bytes4 reason = hook.bindCheck(gachaAddress);
        if (reason != bytes4(0)) revert BindNotReady(reason);
        // Also simulate the actual bind at the review boundary, before release can freeze the named targets.
        vm.warp(nft.targetsSetAt() + hook.TARGET_REVIEW_PERIOD());
        hook.bindGacha(gachaAddress);
    }
}
