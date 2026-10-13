// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";
import {CuratorHarness, MockIntake} from "./mocks/CuratorMocks.sol";
import {Curator} from "../src/Curator.sol";
import {MockERC20} from "./mocks/Mocks.sol";

/// @title The conformance test a consumer copies
/// @notice Delivered whole to builders by the `oracle-consumer` skill. It is the one test that ties
/// a consumer to what the oracle actually signs: the protocol's vector values, its digest and a
/// signature made by `oracle-eip712.ts` (the same vector `OracleAttestation.t.sol` pins). A consumer
/// whose struct, type string or domain differs from the protocol's passes its own self-signed tests
/// and fails this one.
///
/// A builder replaces `deployConsumer` with its own contract, deployed at `VECTOR_CONSUMER` with
/// `SIGNER` as its oracle signer and `caller()` as the address its callback trusts, and `CALLBACK`
/// with its callback's name in the canonical signature.
contract OracleConsumerConformanceTest is Test {
    // ---- the protocol's vector: do not change these ----
    uint256 constant VECTOR_CHAIN = 11155111;
    address constant VECTOR_CONSUMER = 0x0000000000000000000000000000000000002748;
    bytes32 constant VECTOR_DIGEST = 0x95fefa8b7c529852f4e2b6aec888930eb2bf5078e6443a85808e36df19e1325c;
    bytes constant VECTOR_SIGNATURE =
        hex"a26b14918607eb565af126beb54d3c5d19e923c41506def500b3521a4f9aa6d603ab44fd22f15dd2191732961a7131e4641244add8b0f09f20e6ae64381be8481b";
    /// @dev anvil's second account: the vector's attester. A test key, never a real one.
    address constant SIGNER = 0x70997970C51812dc3A010C7d01b50e0d17dc79C8;
    uint256 constant SIGNER_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint64 constant ISSUED_AT = 1800000000;
    uint64 constant EXPIRES_AT = 1800003600;

    /// @dev The callback's canonical signature. Its selector is what the intake calls: a struct that
    /// differs from the protocol's by one field has another selector and is never reached.
    string constant CALLBACK =
        "onOracleResult(bytes32,(bytes32,uint256,bytes32,uint8,bytes,uint256,uint64,uint64,bytes32,bytes32,uint16,uint16,uint16,uint64,uint64),bytes)";

    address constant WRITER = address(0x717E);
    address constant SOURCE_INTAKE = 0x1397434cd35e8a9C8aC312A61D3A285EB31dea56;

    MockIntake delivery;
    MockERC20 asset;
    CuratorHarness consumer;

    function setUp() public {
        vm.chainId(VECTOR_CHAIN);
        vm.warp(ISSUED_AT);
        vm.roll(220);
        delivery = new MockIntake();
        asset = new MockERC20("IMD");
        deployConsumer();
    }

    /// @dev Replace with your consumer, at the vector's address, trusting `caller()`.
    function deployConsumer() internal {
        deployCodeTo(
            "CuratorMocks.sol:CuratorHarness",
            abi.encode(caller(), address(asset), address(this), address(this), address(this), SIGNER),
            VECTOR_CONSUMER
        );
        consumer = CuratorHarness(VECTOR_CONSUMER);
        asset.mint(address(this), 10 ether);
        asset.approve(address(consumer), 10 ether);
    }

    /// @dev Who calls your callback: `IntakeDelivery` for an answer from another chain, the
    /// `Intake` (or a mock of it) for one from the same chain.
    function caller() internal view returns (address) {
        return address(delivery);
    }

    /// @dev The vector attestation: a `bytes32[]` answer with one element, figure 12345, blocks
    /// 100–200, a panel of five with a quorum of four that agreed unanimously.
    function vector() internal pure returns (OracleAttestation.Attestation memory a) {
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = bytes32(uint256(1));
        a = OracleAttestation.Attestation({
            requestId: 0x0000000000004000800000000000000100000000000000000000000000000000,
            chainId: 1,
            questionHash: 0x2117f4362ebfa37aa8a8c0fed548604fe09ac46faf8ae7559cd64780f26a46fb,
            answerType: OracleAttestation.ANSWER_BYTES32_LIST,
            answer: abi.encode(ids),
            figure: 12345,
            fromBlock: 100,
            toBlock: 200,
            blockHash: bytes32(uint256(7)),
            panelJobId: 0x0000000000004000800000000000000200000000000000000000000000000000,
            panelSize: 5,
            quorum: 4,
            agreed: 5,
            issuedAt: ISSUED_AT,
            expiresAt: EXPIRES_AT
        });
    }

    /// @notice The digest your consumer verifies is the one the oracle signs.
    function test_digestMatchesTheProtocol() public view {
        assertEq(
            consumer.attestationDigest(vector()),
            VECTOR_DIGEST,
            "struct, type string or domain differs from the protocol's"
        );
    }

    /// @notice Your callback's selector is the one the intake calls.
    function test_callbackSelectorIsCanonical() public view {
        assertEq(
            consumer.onOracleResult.selector,
            bytes4(keccak256(bytes(CALLBACK))),
            "callback parameters differ from the protocol's"
        );
    }

    /// @notice The protocol's own signature, delivered the way the writer delivers it, is accepted.
    /// @dev A consumer that refuses the vector's answer type signs its own answer with `SIGNER_KEY`
    /// instead; `test_digestMatchesTheProtocol` is what ties it to the protocol.
    function test_acceptsTheProtocolSignature() public {
        // The immutable production policy only accepts bool answers. The test harness exposes the
        // very same inherited verifier to prove the protocol's unmodified bytes32[] vector too.
        consumer.verifyVector(vector(), VECTOR_SIGNATURE);
        assertTrue(consumer.consumed(vector().requestId));
    }

    /// @notice A fresh signature from the same key verifies too, so tests can sign their own answers.
    function test_acceptsAFreshSignatureFromTheVectorKey() public {
        OracleAttestation.Attestation memory a = vector();
        Curator.Window memory w = Curator.Window(100, 200);
        consumer.propose(Curator.Kind.Discount, abi.encode(uint256(900)), w, a.questionHash, 0.5 ether);
        a.chainId = VECTOR_CHAIN;
        a.answerType = OracleAttestation.ANSWER_BOOL;
        a.answer = abi.encode(true);
        a.panelSize = 30;
        a.quorum = 20;
        a.agreed = 25;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SIGNER_KEY, consumer.attestationDigest(a));
        delivery.deliver(delivery.lastId(), a, abi.encodePacked(r, s, v));
        assertTrue(consumer.consumed(a.requestId));
        assertEq(uint256(consumer.proposal(1).state), uint256(Curator.State.Approved));
    }
}
