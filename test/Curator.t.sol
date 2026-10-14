// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Curator} from "../src/Curator.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/OracleAttestation.sol";
import {TwapOracle} from "../src/TwapOracle.sol";
import {GenesisVault} from "../src/GenesisVault.sol";
import {BagGacha} from "../src/BagGacha.sol";
import {GoblinNFT} from "../src/GoblinNFT.sol";
import {IMDProtocol} from "../src/IMDProtocol.sol";
import {MockERC20, MockVRFWrapper, MockPOL, MockGoldHook} from "./mocks/Mocks.sol";
import {CuratorHarness, MockIntake, MockV3Factory, MockV3Pool} from "./mocks/CuratorMocks.sol";

abstract contract CuratorFixture is Test {
    CuratorHarness curator;
    TwapOracle oracle;
    MockERC20 gold;
    MockGoldHook goldHook;
    GenesisVault genesis;
    BagGacha gacha;
    MockIntake intake;
    MockERC20 imd;
    MockERC20 token;
    MockERC20 weth;
    MockV3Factory factory;
    MockV3Pool pool;
    uint256 constant KEY = 0xC0FFEE;
    address signer;
    Curator.Window window;

    function setUp() public virtual {
        vm.chainId(31337);
        vm.warp(1_800_000_000);
        vm.roll(10_000);
        window = Curator.Window(9900, 9988);
        signer = vm.addr(KEY);
        // the intake and the payment token are compiled-in constants: the mocks live at those addresses
        vm.etch(IMDProtocol.IMD, address(new MockERC20("IMD")).code);
        imd = MockERC20(IMDProtocol.IMD);
        vm.etch(IMDProtocol.INTAKE_V2, address(new MockIntake()).code);
        intake = MockIntake(IMDProtocol.INTAKE_V2);
        intake.setPrice(0.5 ether); // etched code starts with empty storage
        token = new MockERC20("TOKEN");
        weth = new MockERC20("WETH");
        factory = new MockV3Factory();
        pool = new MockV3Pool(address(token), address(weth));
        factory.setPool(address(token), address(weth), 3000, address(pool));
        token.mint(address(pool), 100 ether);
        weth.mint(address(pool), 100 ether);
        GoblinNFT nft = new GoblinNFT(address(this));
        MockVRFWrapper vrf = new MockVRFWrapper();
        MockPOL pol = new MockPOL();
        gold = new MockERC20("GOLD");
        goldHook = new MockGoldHook();
        uint64 nonce = vm.getNonce(address(this));
        address predictedCurator = vm.computeCreateAddress(address(this), nonce + 3);
        address predictedGacha = vm.computeCreateAddress(address(this), nonce + 2);
        oracle = new TwapOracle(predictedCurator, address(weth), address(factory), address(gold), address(goldHook));
        genesis = new GenesisVault(
            address(token), address(oracle), predictedGacha, vm.getBlockTimestamp(), 1e24, 1e22, predictedCurator
        );
        gacha = new BagGacha(
            address(oracle),
            address(genesis),
            address(nft),
            address(vrf),
            address(pol),
            address(this),
            vm.getBlockTimestamp(),
            predictedCurator
        );
        curator = new CuratorHarness(address(oracle), address(genesis), address(gacha), signer);
        assertEq(address(curator), predictedCurator);
        imd.mint(address(this), 100 ether);
        imd.approve(address(curator), 100 ether);
    }

    function _propose(Curator.Kind kind, bytes memory data) internal returns (uint256 id) {
        // The mock protocol hashes the body as its deterministic test question hash.
        // Production callers use the real protocol's oracleQuestionHash, never this mock hash.
        bytes32 q = keccak256(curator.requestBody(kind, data, window));
        id = curator.propose(kind, data, window, q, 0.5 ether);
    }

    function _answer(uint256 id, bool yes) internal view returns (OracleAttestation.Attestation memory a) {
        Curator.Proposal memory p = curator.proposal(id);
        a.requestId = keccak256(abi.encode("oracle UUID", id));
        a.chainId = block.chainid;
        a.questionHash = p.questionHash;
        a.answer = abi.encode(yes);
        a.fromBlock = p.fromBlock;
        a.toBlock = p.toBlock;
        a.blockHash = bytes32(uint256(7));
        a.panelSize = 30;
        a.quorum = 20;
        a.agreed = 25;
        a.issuedAt = uint64(vm.getBlockTimestamp());
        a.expiresAt = uint64(vm.getBlockTimestamp() + 1 hours);
    }

    function _sign(OracleAttestation.Attestation memory a) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, curator.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function _deliver(uint256 id, bool yes) internal {
        OracleAttestation.Attestation memory a = _answer(id, yes);
        intake.deliver(curator.proposal(id).intakeId, a, _sign(a));
    }
}

contract CuratorTest is CuratorFixture {
    function testProductionPinsTheRequiredSignerAndHasNoOwner() public {
        Curator prod = new Curator(address(oracle), address(genesis), address(gacha));
        assertEq(prod.oracleSigner(), 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982);
        (bool ok,) = address(prod).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
        (ok,) = address(prod).call(abi.encodeWithSignature("setSigner(address)", signer));
        assertFalse(ok);
        (ok,) = address(oracle).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
    }

    /// @dev v3.1: the IMD intake and token are compiled in (reference values of the oracle-consumer skill, verified
    ///      live on Ethereum), the constructor takes only this project's own contracts, and the compiled-in intake is
    ///      the only address whose callbacks are accepted.
    function testIntakeAndPaymentTokenAreCompiledInConstantsNotConstructorWords() public {
        Curator prod = new Curator(address(oracle), address(genesis), address(gacha));
        assertEq(address(prod.intake()), 0xa43e6F75ee006411F79Ac1C84120606C2330DE82);
        assertEq(address(prod.paymentAsset()), 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7);
        assertEq(prod.INTAKE(), IMDProtocol.INTAKE_V2);
        assertEq(prod.PAYMENT_ASSET(), IMDProtocol.IMD);
        assertEq(prod.ATTESTER(), IMDProtocol.ORACLE_SIGNER);
        assertEq(prod.ACTION(), bytes32("oracle.request@oracle-1"));
        assertEq(address(prod.oracle()), address(oracle));
        assertEq(address(prod.genesis()), address(genesis));
        assertEq(address(prod.gacha()), address(gacha));
        vm.expectRevert(Curator.BadConfig.selector);
        new Curator(address(0), address(genesis), address(gacha));
        // a second intake deployment, even one with identical code, cannot answer a proposal
        uint256 id = _propose(Curator.Kind.Discount, abi.encode(uint256(1000)));
        OracleAttestation.Attestation memory a = _answer(id, true);
        bytes memory sig = _sign(a);
        MockIntake impostor = new MockIntake();
        vm.prank(address(impostor));
        vm.expectRevert(Curator.OnlyIntake.selector);
        curator.onOracleResult(curator.proposal(id).intakeId, a, sig);
        vm.prank(address(impostor));
        vm.expectRevert(Curator.OnlyIntake.selector);
        curator.onOracleFailure(curator.proposal(id).intakeId, 2, bytes32("disagreed"), 1, 2, "");
        // the fee was pulled in the compiled-in token and paid to the compiled-in intake
        assertEq(imd.balanceOf(IMDProtocol.INTAKE_V2), 0.5 ether);
    }

    function testApproveStoreThenPermissionlessExecuteAndReplay() public {
        uint256 id = _propose(Curator.Kind.Discount, abi.encode(uint256(1000)));
        assertEq(imd.balanceOf(address(intake)), 0.5 ether);
        assertEq(imd.allowance(address(curator), address(intake)), 0);
        _deliver(id, true); // mock enforces the real 200,000 gas callback stipend
        assertEq(genesis.discountBps(), 800);
        vm.prank(makeAddr("executor"));
        curator.execute(id);
        assertEq(genesis.discountBps(), 1000);
        vm.expectRevert(Curator.NotApproved.selector);
        curator.execute(id);
        OracleAttestation.Attestation memory a = _answer(id, true);
        bytes memory sig = _sign(a);
        bytes32 req = curator.proposal(id).intakeId;
        vm.expectRevert(Curator.NotPending.selector);
        intake.deliver(req, a, sig);
        assertTrue(curator.consumed(a.requestId));
    }

    function testPoolWhitelistDelistPauseAndUnpauseOnlyByApprovedAction() public {
        uint256 id = _propose(Curator.Kind.Pool, abi.encode(address(token), address(pool)));
        _deliver(id, true);
        curator.execute(id);
        assertEq(oracle.poolOf(address(token)), address(pool));
        assertEq(oracle.valueInEth(address(token), 1 ether), 1 ether);
        id = _propose(Curator.Kind.Pause, abi.encode(address(token), true));
        _deliver(id, true);
        curator.execute(id);
        assertFalse(oracle.isPriced(address(token)));
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.PausedToken.selector, address(token)));
        oracle.valueInEth(address(token), 1 ether);
        id = _propose(Curator.Kind.Pause, abi.encode(address(token), false));
        _deliver(id, true);
        curator.execute(id);
        assertTrue(oracle.isPriced(address(token)));
        id = _propose(Curator.Kind.Pool, abi.encode(address(token), address(0)));
        _deliver(id, true);
        curator.execute(id);
        assertFalse(oracle.isPriced(address(token)));
    }

    function testLiquidityRecheckedAtExecutionAndCanonicalPoolRequired() public {
        uint256 id = _propose(Curator.Kind.Pool, abi.encode(address(token), address(pool)));
        _deliver(id, true);
        pool.setLiquidity(4 ether);
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, address(pool)));
        curator.execute(id);
        assertEq(uint256(curator.proposal(id).state), uint256(Curator.State.Approved));
        pool.setLiquidity(21 ether + 100); // 1 ETH in-band capital plus rounding headroom
        curator.execute(id);
        MockV3Pool fake = new MockV3Pool(address(token), address(weth));
        vm.expectRevert(TwapOracle.PoolMismatch.selector);
        curator.propose(
            Curator.Kind.Pool, abi.encode(address(token), address(fake)), window, bytes32(uint256(1)), 0.5 ether
        );
    }

    function testDirectSettersAndOutsideBoundsRejected() public {
        vm.expectRevert(TwapOracle.OnlyCurator.selector);
        oracle.setPool(address(token), address(pool));
        vm.expectRevert(TwapOracle.OnlyCurator.selector);
        oracle.setTokenPaused(address(token), true);
        vm.expectRevert(GenesisVault.OnlyCurator.selector);
        genesis.setDiscount(1000);
        vm.expectRevert(BagGacha.OnlyCurator.selector);
        gacha.setTierOdds([uint256(7500), 1800, 650, 50]);
        vm.expectRevert(Curator.BadProposal.selector);
        curator.propose(Curator.Kind.Discount, abi.encode(uint256(499)), window, bytes32(uint256(1)), 0.5 ether);
        vm.expectRevert(Curator.BadProposal.selector);
        curator.propose(Curator.Kind.Discount, abi.encode(uint256(1201)), window, bytes32(uint256(1)), 0.5 ether);
    }

    function testNoAnswerFailureAndTimeoutDoNotChangeSettings() public {
        uint256 no = _propose(Curator.Kind.Discount, abi.encode(uint256(1000)));
        _deliver(no, false);
        assertEq(uint256(curator.proposal(no).state), uint256(Curator.State.Rejected));
        vm.expectRevert(Curator.NotApproved.selector);
        curator.execute(no);
        uint256 failed = _propose(Curator.Kind.Discount, abi.encode(uint256(900)));
        intake.fail(curator.proposal(failed).intakeId, 2);
        assertEq(uint256(curator.proposal(failed).state), uint256(Curator.State.Failed));
        uint256 late = _propose(Curator.Kind.Discount, abi.encode(uint256(1100)));
        vm.expectRevert(Curator.DeadlinePending.selector);
        curator.clear(late);
        vm.warp(vm.getBlockTimestamp() + 1 days + 1);
        curator.clear(late);
        assertEq(uint256(curator.proposal(late).state), uint256(Curator.State.Expired));
        assertEq(genesis.discountBps(), 800);
    }

    function testWrongSenderUnknownIdWrongQuestionAndTampering() public {
        uint256 id = _propose(Curator.Kind.Discount, abi.encode(uint256(1000)));
        OracleAttestation.Attestation memory a = _answer(id, true);
        bytes memory sig = _sign(a);
        bytes32 req = curator.proposal(id).intakeId;
        vm.expectRevert(Curator.OnlyIntake.selector);
        curator.onOracleResult(req, a, sig);
        vm.prank(address(intake));
        vm.expectRevert(Curator.UnknownRequest.selector);
        curator.onOracleResult(bytes32(uint256(234)), a, sig);
        a.questionHash = keccak256("another question");
        vm.expectRevert(Curator.WrongQuestion.selector);
        intake.deliver(req, a, sig);
        a = _answer(id, true);
        a.answer = abi.encode(false);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        intake.deliver(req, a, sig);
        a = _answer(id, true);
        a.chainId++;
        vm.expectRevert(Curator.WrongQuestion.selector);
        intake.deliver(req, a, sig);
    }

    function testWeakPanelExpiredFutureAndStaleAnswersRejected() public {
        uint256 id = _propose(Curator.Kind.Discount, abi.encode(uint256(1000)));
        OracleAttestation.Attestation memory a = _answer(id, true);
        bytes32 req = curator.proposal(id).intakeId;
        a.agreed = 19;
        bytes memory sig = _sign(a);
        vm.expectRevert(Curator.WeakPanel.selector);
        intake.deliver(req, a, sig);
        a = _answer(id, true);
        a.quorum = 19;
        sig = _sign(a);
        vm.expectRevert(Curator.WeakPanel.selector);
        intake.deliver(req, a, sig);
        a = _answer(id, true);
        a.issuedAt++;
        sig = _sign(a);
        vm.expectRevert(Curator.StaleAnswer.selector);
        intake.deliver(req, a, sig);
        a = _answer(id, true);
        a.expiresAt = uint64(vm.getBlockTimestamp());
        sig = _sign(a);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.AttestationExpired.selector, a.expiresAt));
        intake.deliver(req, a, sig);
        a = _answer(id, true);
        sig = _sign(a);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1);
        vm.expectRevert(Curator.StaleAnswer.selector);
        intake.deliver(req, a, sig);
    }

    function testCrossContractAndCrossChainSignaturesRejected() public {
        uint256 id = _propose(Curator.Kind.Discount, abi.encode(uint256(1000)));
        OracleAttestation.Attestation memory a = _answer(id, true);
        CuratorHarness other = new CuratorHarness(address(oracle), address(genesis), address(gacha), signer);
        bytes32 req = curator.proposal(id).intakeId;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(KEY, other.attestationDigest(a));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        intake.deliver(req, a, abi.encodePacked(r, s, v));
        vm.chainId(31338);
        bytes memory wrongChain = _sign(a);
        vm.chainId(31337);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        intake.deliver(req, a, wrongChain);
    }

    function testConsumedOracleUuidCannotApproveSecondRequest() public {
        uint256 first = _propose(Curator.Kind.Discount, abi.encode(uint256(900)));
        uint256 second = _propose(Curator.Kind.Discount, abi.encode(uint256(1000)));
        _deliver(first, true);
        OracleAttestation.Attestation memory a = _answer(second, true);
        a.requestId = _answer(first, true).requestId;
        bytes memory sig = _sign(a);
        bytes32 req = curator.proposal(second).intakeId;
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.AlreadyConsumed.selector, a.requestId));
        intake.deliver(req, a, sig);
    }

    function testStaleConcurrentApprovalAndExpiredExecutionCannotChangeSettings() public {
        uint256 a = _propose(Curator.Kind.Discount, abi.encode(uint256(900)));
        uint256 b = _propose(Curator.Kind.Discount, abi.encode(uint256(1000)));
        _deliver(a, true);
        _deliver(b, true);
        curator.execute(a);
        vm.expectRevert(Curator.RevisionChanged.selector);
        curator.execute(b);
        uint256 c = _propose(Curator.Kind.Discount, abi.encode(uint256(1100)));
        _deliver(c, true);
        vm.warp(vm.getBlockTimestamp() + 1 hours + 1);
        vm.expectRevert(Curator.StaleAnswer.selector);
        curator.execute(c);
        curator.clear(c);
        assertEq(genesis.discountBps(), 900);
    }

    function testProposeReentrancyCannotOpenNestedRequest() public {
        bytes memory data = abi.encode(uint256(900));
        intake.armReentry(
            abi.encodeCall(curator.propose, (Curator.Kind.Discount, data, window, bytes32(uint256(1)), 0.5 ether))
        );
        _propose(Curator.Kind.Discount, data);
        assertFalse(intake.reentered());
        assertEq(curator.nextProposalId(), 2);
    }

    function testOddsRelativeTenPercentAndRollingDay() public {
        uint256[4] memory odds = [uint256(7500), 1800, 645, 55]; // jackpot +10%, 5 bps, not 1000 bps
        uint256 id = _propose(Curator.Kind.Odds, abi.encode(odds));
        _deliver(id, true);
        vm.expectRevert(BagGacha.OddsCooldown.selector);
        curator.execute(id);
        vm.warp(vm.getBlockTimestamp() + 1 days);
        window = Curator.Window(uint64(vm.getBlockNumber() - 20), uint64(vm.getBlockNumber() - 12));
        id = _propose(Curator.Kind.Odds, abi.encode(odds));
        _deliver(id, true);
        curator.execute(id);
        assertEq(gacha.baseOdds()[3], 55);
        odds[0] -= 5;
        odds[3] += 5;
        id = _propose(Curator.Kind.Odds, abi.encode(odds));
        _deliver(id, true);
        vm.expectRevert(BagGacha.OddsCooldown.selector);
        curator.execute(id);
        odds[0] -= 1;
        odds[3] += 1;
        vm.expectRevert(Curator.BadProposal.selector);
        curator.propose(Curator.Kind.Odds, abi.encode(odds), window, bytes32(uint256(1)), 0.5 ether);
    }

    function testFuzzDiscountBounds(uint256 bps) public {
        bps = bound(bps, 0, 2000);
        if (bps < 500 || bps > 1200) {
            vm.expectRevert(Curator.BadProposal.selector);
            curator.propose(Curator.Kind.Discount, abi.encode(bps), window, bytes32(uint256(1)), 0.5 ether);
        } else {
            uint256 id = _propose(Curator.Kind.Discount, abi.encode(bps));
            _deliver(id, true);
            curator.execute(id);
            assertEq(genesis.discountBps(), bps);
        }
    }
}
