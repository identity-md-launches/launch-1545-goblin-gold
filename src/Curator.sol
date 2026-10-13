// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {OracleAttestation, OracleAttestationConsumer} from "./OracleAttestation.sol";

interface ICuratorIntake {
    struct Callback {
        address target;
        bytes4 selector;
    }
    function priceOf(bytes32 action, address asset) external view returns (uint256);
    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        bytes4 onFailure,
        address asset,
        uint256 amount
    ) external payable returns (bytes32);
}

interface ICuratedOracle {
    function setPool(address token, address pool) external;
    function setTokenPaused(address token, bool paused) external;
    function validatePool(address token, address pool) external view;
}

interface ICuratedGenesis {
    function setDiscount(uint256 bps) external;
}

interface ICuratedGacha {
    function setTierOdds(uint256[4] calldata odds) external;
    function baseOdds() external view returns (uint256[4] memory);
}

/// @notice Ownerless, bounded IMD governance. The proposer funds a fixed question generated here;
/// the canonical question hash is pinned before requesting. Only that intake request may answer it.
/// Callback verifies/stores under the protocol's stipend. Anyone later executes a fresh approval.
contract Curator is OracleAttestationConsumer, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Strings for uint256;

    address public constant ATTESTER = 0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982;
    bytes32 public constant ACTION = bytes32("oracle.request@oracle-1");
    uint16 public constant MIN_PANEL = 30;
    uint16 public constant MIN_QUORUM = 20;
    uint64 public constant MAX_AGE = 1 hours;
    uint64 public constant REQUEST_TIMEOUT = 1 days;
    uint256 public constant CONFIRMATIONS = 12;
    uint256 public constant MAX_BLOCK_AGE = 300;

    ICuratorIntake public immutable intake;
    IERC20 public immutable paymentAsset;
    ICuratedOracle public immutable oracle;
    ICuratedGenesis public immutable genesis;
    ICuratedGacha public immutable gacha;

    enum Kind {
        Pool,
        Discount,
        Odds,
        Pause
    }
    enum State {
        None,
        Pending,
        Approved,
        Rejected,
        Failed,
        Expired,
        Executed
    }

    struct Window {
        uint64 fromBlock;
        uint64 toBlock;
    }

    struct Proposal {
        Kind kind;
        State state;
        uint64 openedAt;
        uint64 deadline;
        uint64 validUntil;
        uint64 fromBlock;
        uint64 toBlock;
        uint256 revision;
        bytes32 resource;
        bytes32 questionHash;
        bytes32 intakeId;
        bytes data;
    }

    uint256 public nextProposalId = 1;
    mapping(uint256 => Proposal) private proposals;
    mapping(bytes32 => uint256) public proposalForRequest;
    mapping(bytes32 => uint256) public revisions;

    event Proposed(uint256 indexed id, bytes32 indexed intakeId, bytes32 indexed questionHash, Kind kind, bytes data);
    event Answered(uint256 indexed id, bytes32 indexed oracleId, bool approved);
    event Failed(uint256 indexed id, uint8 status, bytes32 reason);
    event Expired(uint256 indexed id);
    event Executed(uint256 indexed id);

    error BadConfig();
    error BadProposal();
    error BadWindow();
    error FeeTooHigh();
    error OnlyIntake();
    error UnknownRequest();
    error NotPending();
    error WrongQuestion();
    error WeakPanel();
    error StaleAnswer();
    error NotApproved();
    error RevisionChanged();
    error DeadlinePending();

    constructor(address intake_, address asset_, address oracle_, address genesis_, address gacha_)
        OracleAttestationConsumer(ATTESTER)
    {
        if (
            intake_ == address(0) || asset_ == address(0) || oracle_ == address(0) || genesis_ == address(0)
                || gacha_ == address(0)
        ) revert BadConfig();
        intake = ICuratorIntake(intake_);
        paymentAsset = IERC20(asset_);
        oracle = ICuratedOracle(oracle_);
        genesis = ICuratedGenesis(genesis_);
        gacha = ICuratedGacha(gacha_);
    }

    function proposal(uint256 id) external view returns (Proposal memory) {
        return proposals[id];
    }

    /// @notice No free-form question or definitions are accepted. `data` is exactly one of:
    /// Pool: abi.encode(token,pool), pool=0 means delist; Discount: abi.encode(bps);
    /// Odds: abi.encode(uint256[4]); Pause: abi.encode(token,bool).
    function propose(Kind kind, bytes calldata data, Window calldata window, bytes32 questionHash, uint256 maxFee)
        external
        nonReentrant
        returns (uint256 id)
    {
        if (questionHash == bytes32(0)) revert BadProposal();
        _checkWindow(window);
        bytes32 resource = _validate(kind, data);
        uint256 revision = revisions[resource];
        bytes memory body = _requestBody(kind, data, window, revision);
        id = nextProposalId++;
        Proposal storage p = proposals[id];
        p.kind = kind;
        p.state = State.Pending;
        p.openedAt = uint64(block.timestamp);
        p.deadline = uint64(block.timestamp + REQUEST_TIMEOUT);
        p.fromBlock = window.fromBlock;
        p.toBlock = window.toBlock;
        p.resource = resource;
        p.revision = revision;
        p.questionHash = questionHash;
        p.data = data;
        bytes32 intakeId = _ask(body, maxFee);
        if (intakeId == bytes32(0) || proposalForRequest[intakeId] != 0) revert BadProposal();
        p.intakeId = intakeId;
        proposalForRequest[intakeId] = id;
        emit Proposed(id, intakeId, questionHash, kind, data);
    }

    function _ask(bytes memory body, uint256 maxFee) internal returns (bytes32 id) {
        uint256 fee = intake.priceOf(ACTION, address(paymentAsset));
        if (fee == 0 || fee > maxFee) revert FeeTooHigh();
        uint256 beforeBalance = paymentAsset.balanceOf(address(this));
        paymentAsset.safeTransferFrom(msg.sender, address(this), fee);
        if (paymentAsset.balanceOf(address(this)) - beforeBalance != fee) revert BadConfig();
        paymentAsset.forceApprove(address(intake), fee);
        id = intake.requestWithFailure(
            ACTION,
            body,
            ICuratorIntake.Callback(address(this), this.onOracleResult.selector),
            this.onOracleFailure.selector,
            address(paymentAsset),
            fee
        );
        paymentAsset.forceApprove(address(intake), 0);
    }

    function _checkWindow(Window calldata w) internal view {
        if (
            w.fromBlock > w.toBlock || w.toBlock >= block.number || block.number - w.toBlock < CONFIRMATIONS
                || block.number - w.toBlock > MAX_BLOCK_AGE
        ) {
            revert BadWindow();
        }
    }

    function _validate(Kind kind, bytes memory data) internal view returns (bytes32 resource) {
        address token;
        if (kind == Kind.Pool) {
            if (data.length != 64) revert BadProposal();
            address pool;
            (token, pool) = abi.decode(data, (address, address));
            if (token == address(0)) revert BadProposal();
            if (pool != address(0)) oracle.validatePool(token, pool);
        } else if (kind == Kind.Discount) {
            if (data.length != 32) revert BadProposal();
            uint256 bps = abi.decode(data, (uint256));
            if (bps < 500 || bps > 1200) revert BadProposal();
        } else if (kind == Kind.Odds) {
            if (data.length != 128) revert BadProposal();
            uint256[4] memory odds = abi.decode(data, (uint256[4]));
            uint256[4] memory old = gacha.baseOdds();
            uint256 sum;
            for (uint256 i; i < 4; ++i) {
                uint256 delta = odds[i] > old[i] ? odds[i] - old[i] : old[i] - odds[i];
                if (odds[i] == 0 || odds[i] > 10_000 || delta > old[i] / 10) revert BadProposal();
                sum += odds[i];
            }
            if (sum != 10_000) revert BadProposal();
        } else {
            if (data.length != 64) revert BadProposal();
            (token,) = abi.decode(data, (address, bool));
            if (token == address(0)) revert BadProposal();
        }
        return keccak256(abi.encode(kind, token));
    }

    /// @notice Preview the exact paid body. Compute its canonical absolute-window question hash
    /// with the protocol's oracleQuestionHash, then supply that hash to propose in the same revision.
    /// A bad hash wastes only the proposer's fee; it cannot substitute a different question/body.
    function requestBody(Kind kind, bytes calldata data, Window calldata window) external view returns (bytes memory) {
        _checkWindow(window);
        bytes32 resource = _validate(kind, data);
        return _requestBody(kind, data, window, revisions[resource]);
    }

    function _operation(Kind kind, bytes memory data) internal pure returns (string memory) {
        if (kind == Kind.Pool) {
            (address token, address pool) = abi.decode(data, (address, address));
            return string.concat(
                pool == address(0) ? "delist token " : "whitelist token ",
                Strings.toHexString(token),
                " with Uniswap v3 WETH pool ",
                Strings.toHexString(pool)
            );
        }
        if (kind == Kind.Discount) {
            return string.concat("set Genesis discount basis points to ", abi.decode(data, (uint256)).toString());
        }
        if (kind == Kind.Pause) {
            (address token, bool paused) = abi.decode(data, (address, bool));
            return string.concat(
                paused ? "pause Bags containing token " : "resume Bags containing token ", Strings.toHexString(token)
            );
        }
        uint256[4] memory odds = abi.decode(data, (uint256[4]));
        return string.concat(
            "set small, medium, large, jackpot odds basis points to ",
            odds[0].toString(),
            ", ",
            odds[1].toString(),
            ", ",
            odds[2].toString(),
            ", ",
            odds[3].toString()
        );
    }

    function _requestBody(Kind kind, bytes memory data, Window calldata w, uint256 revision)
        internal
        view
        returns (bytes memory)
    {
        string memory question = string.concat(
            "Should Goblin Gold v2 Curator ",
            Strings.toHexString(address(this)),
            " on chain ",
            block.chainid.toString(),
            " at resource revision ",
            revision.toString(),
            " ",
            _operation(kind, data),
            "? Return true only when the proposed action satisfies policy at the closing block."
        );
        string memory policy =
            "Protect reserve solvency and users. Listed tokens must be non-rebasing, non-taxed ERC20s without malicious transfers; pools must be canonical Uniswap v3 WETH pools with at least 50 ETH value per side and valid 30m and 4h TWAPs. Delist or pause unsafe tokens; resume only if safe. Discount must be 5-12 percent; each tier odds change at most 10 percent relative per 24 hours, sum 10000 bps. Parameter changes must support sustainable payouts, not extraction.";
        bytes memory first = bytes(
            string.concat(
                '{"v":1,"question":"',
                question,
                '","chainId":',
                block.chainid.toString(),
                ',"window":{"fromBlock":',
                uint256(w.fromBlock).toString(),
                ',"toBlock":',
                uint256(w.toBlock).toString(),
                "}"
            )
        );
        return bytes.concat(
            first,
            bytes(
                string.concat(
                    ',"answerType":"bool","evidence":"panel","panelSize":30,"quorum":20,',
                    '"validForSeconds":3600,"definitions":{"policy":"',
                    policy,
                    '"}}'
                )
            )
        );
    }

    function onOracleResult(bytes32 requestId, OracleAttestation.Attestation calldata a, bytes calldata signature)
        external
        nonReentrant
    {
        if (msg.sender != address(intake)) revert OnlyIntake();
        uint256 id = proposalForRequest[requestId];
        if (id == 0) revert UnknownRequest();
        Proposal storage p = proposals[id];
        if (p.state != State.Pending) revert NotPending();
        if (
            a.questionHash != p.questionHash || a.chainId != block.chainid || a.fromBlock != p.fromBlock
                || a.toBlock != p.toBlock
        ) revert WrongQuestion();
        if (
            a.panelSize < MIN_PANEL || a.quorum < MIN_QUORUM || a.agreed < a.quorum || a.quorum > a.panelSize
                || a.agreed > a.panelSize
        ) revert WeakPanel();
        if (
            block.timestamp > p.deadline || a.issuedAt < p.openedAt || a.issuedAt > block.timestamp
                || block.timestamp - a.issuedAt > MAX_AGE || a.expiresAt < a.issuedAt || a.toBlock >= block.number
                || block.number - a.toBlock > MAX_BLOCK_AGE
        ) revert StaleAnswer();
        _verifyAttestation(a, signature);
        if (a.requestId == bytes32(0) || a.answer.length != 32) revert BadProposal();
        bool approved = decodeBool(a);
        _consume(a.requestId);
        p.state = approved ? State.Approved : State.Rejected;
        uint64 freshnessEnd = a.issuedAt + MAX_AGE;
        p.validUntil = a.expiresAt < freshnessEnd ? a.expiresAt : freshnessEnd;
        emit Answered(id, a.requestId, approved);
    }

    /// @notice An unsigned failure only closes this contract's own pending request; never changes settings.
    function onOracleFailure(bytes32 requestId, uint8 status, bytes32 reason, uint16, uint16, bytes calldata)
        external
        nonReentrant
    {
        if (msg.sender != address(intake)) revert OnlyIntake();
        uint256 id = proposalForRequest[requestId];
        if (id == 0) revert UnknownRequest();
        Proposal storage p = proposals[id];
        if (p.state != State.Pending) revert NotPending();
        if (status != 1 && status != 2) revert BadProposal();
        p.state = State.Failed;
        emit Failed(id, status, reason);
    }

    function clear(uint256 id) external {
        Proposal storage p = proposals[id];
        if (p.state != State.Pending && p.state != State.Approved) revert NotPending();
        uint256 deadline = p.state == State.Pending ? p.deadline : p.validUntil;
        if (block.timestamp <= deadline) revert DeadlinePending();
        p.state = State.Expired;
        emit Expired(id);
    }

    function execute(uint256 id) external nonReentrant {
        Proposal storage p = proposals[id];
        if (p.state != State.Approved) revert NotApproved();
        if (block.timestamp > p.validUntil || block.number - p.toBlock > MAX_BLOCK_AGE) revert StaleAnswer();
        if (revisions[p.resource] != p.revision) revert RevisionChanged();
        p.state = State.Executed;
        revisions[p.resource] += 1;
        emit Executed(id);
        if (p.kind == Kind.Pool) {
            (address token, address pool) = abi.decode(p.data, (address, address));
            oracle.setPool(token, pool); // rechecks live liquidity, identity and freshness
        } else if (p.kind == Kind.Discount) {
            genesis.setDiscount(abi.decode(p.data, (uint256)));
        } else if (p.kind == Kind.Odds) {
            gacha.setTierOdds(abi.decode(p.data, (uint256[4])));
        } else {
            (address token, bool paused) = abi.decode(p.data, (address, bool));
            oracle.setTokenPaused(token, paused);
        }
    }
}
