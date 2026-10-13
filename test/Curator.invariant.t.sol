// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {CuratorFixture} from "./Curator.t.sol";
import {Curator} from "../src/Curator.sol";
import {CuratorHarness, MockIntake} from "./mocks/CuratorMocks.sol";
import {MockERC20} from "./mocks/Mocks.sol";
import {GenesisVault} from "../src/GenesisVault.sol";
import {BagGacha} from "../src/BagGacha.sol";
import {OracleAttestation} from "../src/OracleAttestation.sol";

contract CuratorHandler is Test {
    CuratorHarness public curator;
    MockIntake public intake;
    GenesisVault public genesis;
    BagGacha public gacha;
    uint256 public approvals;
    uint256 public expectedDiscount = 800;
    bool public unauthorizedChange;
    uint256 public lastExecuted;

    constructor(CuratorHarness c, MockIntake i, MockERC20 asset, GenesisVault v, BagGacha g) {
        curator = c;
        intake = i;
        genesis = v;
        gacha = g;
        asset.mint(address(this), 1_000_000 ether);
        asset.approve(address(c), 1_000_000 ether);
    }

    function discount(uint256 raw, bool yes) external {
        uint256 bps = bound(raw, 500, 1200);
        Curator.Window memory w = Curator.Window(uint64(vm.getBlockNumber() - 20), uint64(vm.getBlockNumber() - 12));
        bytes memory data = abi.encode(bps);
        bytes32 question = keccak256(curator.requestBody(Curator.Kind.Discount, data, w));
        uint256 id = curator.propose(Curator.Kind.Discount, data, w, question, 0.5 ether);
        OracleAttestation.Attestation memory a;
        a.requestId = keccak256(abi.encode("invariant UUID", id));
        a.chainId = block.chainid;
        a.questionHash = question;
        a.answer = abi.encode(yes);
        a.fromBlock = w.fromBlock;
        a.toBlock = w.toBlock;
        a.panelSize = 30;
        a.quorum = 20;
        a.agreed = 25;
        a.issuedAt = uint64(vm.getBlockTimestamp());
        a.expiresAt = uint64(vm.getBlockTimestamp() + 1 hours);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xC0FFEE, curator.attestationDigest(a));
        intake.deliver(curator.proposal(id).intakeId, a, abi.encodePacked(r, s, v));
        if (yes) {
            curator.execute(id);
            expectedDiscount = bps;
            ++approvals;
            lastExecuted = id;
        } else {
            uint256 beforeBps = genesis.discountBps();
            try curator.execute(id) {
                unauthorizedChange = true;
            } catch {}
            if (beforeBps != genesis.discountBps()) unauthorizedChange = true;
        }
    }

    function replay() external {
        if (lastExecuted == 0) return;
        try curator.execute(lastExecuted) {
            unauthorizedChange = true;
        } catch {}
    }

    function invalidProposal(uint256 raw) external {
        uint256 bps = raw % 2 == 0 ? bound(raw, 0, 499) : bound(raw, 1201, 10000);
        Curator.Window memory w = Curator.Window(uint64(vm.getBlockNumber() - 20), uint64(vm.getBlockNumber() - 12));
        try curator.propose(Curator.Kind.Discount, abi.encode(bps), w, bytes32(uint256(1)), 0.5 ether) {
            unauthorizedChange = true;
        } catch {}
    }

    function bypass(uint256 bps) external {
        try genesis.setDiscount(bps) {
            unauthorizedChange = true;
        } catch {}
        try gacha.setTierOdds([uint256(7500), 1800, 650, 50]) {
            unauthorizedChange = true;
        } catch {}
    }

    function advance(uint256 seconds_) external {
        uint256 delta = bound(seconds_, 1, 1 days);
        vm.warp(vm.getBlockTimestamp() + delta);
        vm.roll(vm.getBlockNumber() + delta / 12 + 1);
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract CuratorInvariantTest is CuratorFixture {
    CuratorHandler h;

    function setUp() public override {
        super.setUp();
        h = new CuratorHandler(curator, intake, imd, genesis, gacha);
        bytes4[] memory methods = new bytes4[](5);
        methods[0] = h.discount.selector;
        methods[1] = h.replay.selector;
        methods[2] = h.invalidProposal.selector;
        methods[3] = h.bypass.selector;
        methods[4] = h.advance.selector;
        targetContract(address(h));
        targetSelector(FuzzSelector(address(h), methods));
    }

    function invariant_onlyFreshApprovedBoundedChangesExecuteOnce() public view {
        assertFalse(h.unauthorizedChange());
        assertEq(genesis.discountBps(), h.expectedDiscount());
        assertGe(genesis.discountBps(), 500);
        assertLe(genesis.discountBps(), 1200);
        assertEq(curator.revisions(keccak256(abi.encode(Curator.Kind.Discount, address(0)))), h.approvals());
        assertEq(curator.oracleSigner(), vm.addr(0xC0FFEE));
        uint256[4] memory odds = gacha.baseOdds();
        assertEq(odds[0] + odds[1] + odds[2] + odds[3], 10_000);
    }
}
