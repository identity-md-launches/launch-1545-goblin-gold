// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IMDProtocol
/// @notice Compiled-in IdentityMD protocol addresses for Ethereum mainnet (chain 1), pinned from the
///         oracle-consumer reference of 2026-10-10 and verified live on 2026-10-13 (`Intake.priceOf` on the intake
///         returns 0.5 IMD for the oracle action; the token reports `symbol() == "IMD"`). They are constants, like the
///         oracle signer, so that no launch manifest word is ever an IMD protocol address. A protocol migration
///         (new intake version, moved token) needs a new, separately reviewed Curator build.
library IMDProtocol {
    /// @dev `Intake` version 2 on Ethereum: `request` and `requestWithFailure`.
    address internal constant INTAKE_V2 = 0xa43e6F75ee006411F79Ac1C84120606C2330DE82;
    /// @dev The IMD token the intake is paid in on Ethereum.
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    /// @dev The oracle signer whose EIP-712 attestations the Curator accepts.
    address internal constant ORACLE_SIGNER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
    /// @dev Action id: the UTF-8 bytes right-padded with zeros, not a keccak hash.
    bytes32 internal constant ORACLE_ACTION = bytes32("oracle.request@oracle-1");
}
