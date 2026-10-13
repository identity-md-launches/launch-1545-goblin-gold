// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {GoblinNFT} from "../src/GoblinNFT.sol";

/// @notice Reference deploy for review. The launch deploys GoblinNFT from its bytecode with `owner_ = $owner`.
contract DeployGoblinNFT is Script {
    function deploy(address owner_) public returns (GoblinNFT) {
        require(owner_ != address(0), "owner required");
        return new GoblinNFT(owner_);
    }
}
