// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {GoldHook, IHookPOL} from "../src/GoldHook.sol";
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
    error WrongWiring();
    error BindNotReady(bytes4 reason);

    /// @param expectedWrapper Chain's verified VRF wrapper, independently supplied from the launch parameters.
    /// @param expectedCurator Curator address resolved for this launch.
    /// @param expectedStartTime Agreed startTime, at least four hours after the first post-seed swap.
    function run(
        address hookAddress,
        address gachaAddress,
        address expectedWrapper,
        address expectedCurator,
        uint256 expectedStartTime
    ) external {
        GoldHook hook = GoldHook(payable(hookAddress));
        if (gachaAddress.codehash != hook.GACHA_RUNTIME_CODE_HASH()) revert WrongRuntimeCode();
        if (!hook.hasRequiredFlags() || !hook.initialized()) revert WrongPermissions();
        BagGacha gacha = BagGacha(payable(gachaAddress));
        GenesisVault vault = GenesisVault(address(gacha.genesis()));
        uint256 balance = IERC20(hook.token()).balanceOf(address(vault));
        uint256 supply = vault.genesisSupply();
        if (balance < supply) revert WrongFunding();
        if (balance > supply) console2.log("GenesisVault surplus GOLD (base units)", balance - supply);
        if (
            address(gacha.vrf()) != expectedWrapper || gacha.curator() != expectedCurator
                || vault.curator() != expectedCurator || gacha.startTime() != expectedStartTime
        ) revert WrongWiring();
        try gacha.spinPrice() returns (uint256 total, uint256 fee) {
            if (fee == 0 || total <= fee) revert WrongWiring();
        } catch {
            revert WrongWiring();
        }
        GoblinNFT nft = GoblinNFT(hook.NFT());
        address pol = address(gacha.polManager());
        if (IHookPOL(pol).mintEscrow() != hook.NFT() || IHookPOL(pol).poolManager() != address(hook.poolManager())) {
            revert BindNotReady(GoldHook.GachaMismatch.selector);
        }
        vm.prank(nft.owner());
        nft.setLaunchTargets(pol, gachaAddress, gachaAddress);
        bytes4 reason = hook.bindCheck(gachaAddress);
        if (reason != bytes4(0)) revert BindNotReady(reason);
        // Also simulate the actual bind at the review boundary, before release can freeze the named targets.
        uint256 reviewEnd = nft.targetsSetAt() + hook.TARGET_REVIEW_PERIOD();
        if (block.timestamp < reviewEnd) vm.warp(reviewEnd);
        hook.bindGacha(gachaAddress);
    }
}
