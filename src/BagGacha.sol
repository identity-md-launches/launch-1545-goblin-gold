// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IBagOracle {
    function isPriced(address token) external view returns (bool);
    function valueInEth(address token, uint256 amount) external view returns (uint256);
}

interface IGenesisVault {
    function token() external view returns (address);
    function quote(bool holder) external view returns (uint256 tokens);
    function commit(bool holder) external returns (uint256 tokens);
    function uncommit(uint256 tokens) external;
    function deliver(address to, uint256 tokens) external;
    function setShares(address account, uint256 newShares) external;
}

interface IGoblinNFT {
    function released() external view returns (bool);
    function ownerOf(uint256 tokenId) external view returns (address);
    function reserveTarget() external view returns (address);
    function vrfTarget() external view returns (address);
    function reserveOwed() external view returns (uint256);
    function vrfOwed() external view returns (uint256);
    function claimRelease() external returns (uint256);
    function depositRevenue() external payable;
}

interface IPOLManager {
    function depositPOL() external payable;
    function depositBurn() external payable;
}

/// @notice Chainlink VRF v2.5 direct-funding wrapper (native payment).
interface IVRFV2PlusWrapper {
    function calculateRequestPriceNative(uint32 callbackGasLimit, uint32 numWords) external view returns (uint256);
    function requestRandomWordsInNative(
        uint32 callbackGasLimit,
        uint16 requestConfirmations,
        uint32 numWords,
        bytes calldata extraArgs
    ) external payable returns (uint256 requestId);
}

/// @title BagGacha
/// @notice Bag vault, spin router and payout reserve in one contract. Code only: not deployed by this job.
/// @dev Safety design (research b7e0e298): one outstanding draw; inventory, values, tier odds and Genesis quote
///      are committed in the request transaction; the VRF callback only stores the word; a later permissionless
///      `draw()` selects; the winner has 5 minutes to keep or take the buyback, then anyone may finalize (keep);
///      new Bags mature for 24 h; no timeout reroll, no admin and no rescue path.
contract BagGacha is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ------------------------------------------------------------------ parameters (20ccee81 section 3.7)
    uint256 public constant P = 0.01 ether;
    uint256 public constant BUYBACK_BPS = 8800;
    uint256 public constant DEPOSITOR_BPS = 9500;
    uint256 public constant EXIT_FEE_BPS = 50;
    uint256 public constant MAX_BAG_RESERVE_BPS = 500;
    uint256 public constant JACKPOT_RESERVE_MULTIPLE = 20;
    uint256 public constant GENESIS_LANE_BPS = 6000;
    uint256 public constant MATURATION = 24 hours;
    uint256 public constant CHOICE_WINDOW = 5 minutes;
    uint256 public constant HOLDER_WINDOW = 48 hours;
    uint256 public constant HOLDER_SPINS_PER_NFT = 5;
    uint256 public constant FREE_SPINS_PER_NFT = 2;
    uint256 public constant MAX_ACTIVE = 32; // leave transaction gas headroom for real v3 observation histories
    uint256 public constant MAX_TOKENS_PER_BAG = 4;
    uint32 public constant CALLBACK_GAS = 100_000;
    uint16 public constant CONFIRMATIONS = 3;
    uint256 private constant BPS = 10_000;

    // ------------------------------------------------------------------ wiring (immutable)
    IBagOracle public immutable oracle;
    IGenesisVault public immutable genesis;
    IGoblinNFT public immutable nft;
    IVRFV2PlusWrapper public immutable vrf;
    IPOLManager public immutable polManager;
    address public immutable team;
    address public immutable curator;
    uint256[4] private tierOdds = [uint256(7500), 1800, 650, 50];
    uint256 public lastOddsChange;
    uint256 public immutable startTime;

    // ------------------------------------------------------------------ bags
    enum BagStatus {
        None,
        Listed,
        Drawn,
        Kept,
        Withdrawn
    }

    struct Bag {
        address depositor;
        BagStatus status;
        uint64 listedAt;
        uint256 shares;
        address[] tokens;
        uint256[] amounts;
    }

    uint256 public nextBagId = 1;
    mapping(uint256 => Bag) internal bags;
    mapping(uint256 => address) public bagWinner; // kept Bags: who may pull the contents
    uint256[] public activeBags;
    mapping(uint256 => uint256) internal activeIndex; // bagId => index + 1
    mapping(address => uint256) public depositorShares;

    // ------------------------------------------------------------------ the one outstanding draw
    struct Request {
        address spinner;
        uint256 paid; // spin price held until the lane is known (0 for free spins)
        uint256 vrfRequestId;
        uint256 word;
        uint256 liability; // worst-case payout earmarked from the reserve
        uint256 genesisTokens;
        uint256 genesisValue;
        uint256 genesisBps; // lane probability committed at request time
        uint256[4] odds; // effective tier odds committed at request time
        uint256[4] tierWeight;
        bool free;
        bool fulfilled;
    }

    bool public pending;
    Request internal req;
    uint256[] internal snapIds;
    uint256[] internal snapValues;
    uint256[] internal snapWeights;
    uint8[] internal snapTiers;

    // ------------------------------------------------------------------ allocations
    struct Allocation {
        address spinner;
        uint256 bagId; // 0 for a Genesis Bag
        uint256 value;
        uint256 genesisTokens;
        uint256 liability;
        uint64 deadline;
        bool buybackAllowed;
        bool settled;
    }

    uint256 public nextAllocationId = 1;
    mapping(uint256 => Allocation) public allocations;

    // ------------------------------------------------------------------ ETH accounting
    uint256 public reserve; // free reserve
    uint256 public locked; // earmarked for the pending draw and open allocations
    uint256 public vrfBudget; // pays VRF for free spins (10% of the mint)
    uint256 public holderAccrued;
    uint256 public polAccrued;
    uint256 public burnAccrued;
    uint256 public totalCredits;
    mapping(address => uint256) public credits;
    mapping(uint256 => uint256) public holderSpinsUsed;
    mapping(uint256 => uint256) public freeSpinsUsed;

    event BagSealed(
        uint256 indexed bagId, address indexed depositor, address[] tokens, uint256[] amounts, uint256 value
    );
    event BagWithdrawn(uint256 indexed bagId, address indexed depositor, uint256 exitFee);
    event SpinRequested(
        uint256 indexed vrfRequestId, address indexed spinner, bool free, uint256 vrfFee, uint256 snapshotSize
    );
    event SpinFulfilled(uint256 indexed vrfRequestId, uint256 word);
    event BagDrawn(
        uint256 indexed allocationId, uint256 indexed bagId, address indexed spinner, uint256 value, uint8 tier
    );
    event GenesisDrawn(uint256 indexed allocationId, address indexed spinner, uint256 tokens, uint256 value);
    event Kept(uint256 indexed allocationId, address indexed spinner, uint256 depositorPaid);
    event BoughtBack(uint256 indexed allocationId, address indexed spinner, uint256 paid);
    event BagClaimed(uint256 indexed bagId, address indexed winner);
    event CreditWithdrawn(address indexed account, uint256 amount);
    event MintEscrowReceived(uint256 reserveShare, uint256 vrfShare);
    event Flushed(uint256 holders, uint256 pol, uint256 burn);

    error OnlyCurator();
    error OddsOutOfBounds();
    error OddsCooldown();
    event TierOddsSet(uint256[4] odds);
    event Funded(address indexed from, uint256 reserveAmount, uint256 vrfAmount);
    error BadBag();
    error NotListed();
    error TooManyActive();
    error ValueOutOfRange();
    error NotDepositor();
    error Locked();
    error DrawPending();
    error NoDrawPending();
    error NotFulfilled();
    error WrongPayment();
    error ReserveTooLow();
    error NothingToDraw();
    error HolderWindow();
    error NotHolder();
    error SpinLimit();
    error NotSpinner();
    error WindowOpen();
    error WindowClosed();
    error AlreadySettled();
    error NoBuyback();
    error NothingOwed();
    error TransferFailed();
    error OnlyWrapper();
    error NotStarted();
    error MintNotReleased();
    error UnexpectedSender();

    constructor(
        address oracle_,
        address genesis_,
        address nft_,
        address vrfWrapper_,
        address polManager_,
        address team_,
        uint256 startTime_,
        address curator_
    ) {
        if (
            oracle_ == address(0) || genesis_ == address(0) || nft_ == address(0) || vrfWrapper_ == address(0)
                || polManager_ == address(0) || team_ == address(0) || curator_ == address(0)
        ) revert BadBag();
        curator = curator_;
        lastOddsChange = block.timestamp;
        oracle = IBagOracle(oracle_);
        genesis = IGenesisVault(genesis_);
        nft = IGoblinNFT(nft_);
        vrf = IVRFV2PlusWrapper(vrfWrapper_);
        polManager = IPOLManager(polManager_);
        team = team_;
        startTime = startTime_;
    }

    /// @notice Only the GoblinNFT escrow sends plain ETH here (mint release).
    receive() external payable {
        if (msg.sender != address(nft)) revert UnexpectedSender();
    }

    /// @notice Donations fund early launch independently of refundable NFT mint escrow. No withdrawal rights.
    function fundReserve() external payable {
        if (msg.value == 0) revert WrongPayment();
        reserve += msg.value;
        emit Funded(msg.sender, msg.value, 0);
    }

    function fundVRF() external payable {
        if (msg.value == 0) revert WrongPayment();
        vrfBudget += msg.value;
        emit Funded(msg.sender, 0, msg.value);
    }

    /// @notice At most one relative 10% change to each tier in any rolling 24-hour interval.
    function setTierOdds(uint256[4] calldata odds) external {
        if (msg.sender != curator) revert OnlyCurator();
        if (block.timestamp < lastOddsChange + 1 days) revert OddsCooldown();
        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            uint256 old = tierOdds[i];
            uint256 delta = odds[i] > old ? odds[i] - old : old - odds[i];
            if (odds[i] == 0 || odds[i] > BPS || delta > old / 10) revert OddsOutOfBounds();
            sum += odds[i];
        }
        if (sum != BPS) revert OddsOutOfBounds();
        tierOdds = odds;
        lastOddsChange = block.timestamp;
        emit TierOddsSet(odds);
    }

    // ================================================================== views

    function tierOf(uint256 value) public pure returns (uint8) {
        if (value < (P * 30) / 100 || value > P * 70) return type(uint8).max;
        if (value < (P * 70) / 100) return 0;
        if (value < P * 2) return 1;
        if (value < P * 6) return 2;
        return 3;
    }

    function baseOdds() public view returns (uint256[4] memory) {
        return tierOdds;
    }

    function bagValue(uint256 bagId) public view returns (uint256 v) {
        Bag storage b = bags[bagId];
        for (uint256 i = 0; i < b.tokens.length; ++i) {
            v += oracle.valueInEth(b.tokens[i], b.amounts[i]);
        }
    }

    function bagInfo(uint256 bagId)
        external
        view
        returns (
            address depositor,
            BagStatus status,
            uint64 listedAt,
            address[] memory tokens,
            uint256[] memory amounts
        )
    {
        Bag storage b = bags[bagId];
        return (b.depositor, b.status, b.listedAt, b.tokens, b.amounts);
    }

    /// @notice Spin price held while the draw is pending; split once the lane is known.
    function heldSpinPayment() external view returns (uint256) {
        return req.paid;
    }

    function activeCount() external view returns (uint256) {
        return activeBags.length;
    }

    function spinPrice() public view returns (uint256 total, uint256 vrfFee) {
        vrfFee = vrf.calculateRequestPriceNative(CALLBACK_GAS, 1);
        total = P + vrfFee;
    }

    function currentRequest()
        external
        view
        returns (
            address spinner,
            uint256 vrfRequestId,
            bool fulfilled,
            uint256 liability,
            uint256[4] memory odds,
            uint256 genesisBps
        )
    {
        return (req.spinner, req.vrfRequestId, req.fulfilled, req.liability, req.odds, req.genesisBps);
    }

    function snapshot() external view returns (uint256[] memory ids, uint256[] memory values, uint8[] memory tiers) {
        return (snapIds, snapValues, snapTiers);
    }

    // ================================================================== deposits

    /// @notice Seal 1-4 distinct listed tokens into a Bag. It becomes drawable after 24 h.
    function seal(address[] calldata tokens, uint256[] calldata amounts) external nonReentrant returns (uint256 bagId) {
        uint256 n = tokens.length;
        if (n < 1 || n > MAX_TOKENS_PER_BAG || n != amounts.length) revert BadBag();
        if (activeBags.length >= MAX_ACTIVE) revert TooManyActive();
        uint256 value = 0;
        for (uint256 i = 0; i < n; ++i) {
            if (amounts[i] < 1 || !oracle.isPriced(tokens[i])) revert BadBag();
            for (uint256 j = 0; j < i; ++j) {
                if (tokens[j] == tokens[i]) revert BadBag();
            }
            value += oracle.valueInEth(tokens[i], amounts[i]);
        }
        uint256 cap = (reserve * MAX_BAG_RESERVE_BPS) / BPS;
        if (tierOf(value) == type(uint8).max || value > cap) revert ValueOutOfRange();

        bagId = nextBagId++;
        Bag storage b = bags[bagId];
        b.depositor = msg.sender;
        b.status = BagStatus.Listed;
        b.listedAt = uint64(block.timestamp);
        b.tokens = tokens;
        b.amounts = amounts;
        b.shares = Math.sqrt(value);
        _activate(bagId);
        uint256 newShares = depositorShares[msg.sender] + b.shares;
        depositorShares[msg.sender] = newShares;
        emit BagSealed(bagId, msg.sender, tokens, amounts, value);

        for (uint256 i = 0; i < n; ++i) {
            uint256 beforeBalance = IERC20(tokens[i]).balanceOf(address(this));
            IERC20(tokens[i]).safeTransferFrom(msg.sender, address(this), amounts[i]);
            if (IERC20(tokens[i]).balanceOf(address(this)) - beforeBalance != amounts[i]) revert BadBag();
        }
        genesis.setShares(msg.sender, newShares);
    }

    /// @notice Depositor takes a listed Bag back after its 24 h lock, paying a 0.5% exit fee in ETH to the reserve.
    ///         Bags whose tokens can no longer be priced (delisted, stale or thin pool) exit without a fee.
    function withdraw(uint256 bagId) external payable nonReentrant {
        Bag storage b = bags[bagId];
        if (b.depositor != msg.sender) revert NotDepositor();
        if (b.status != BagStatus.Listed) revert NotListed();
        if (pending) revert DrawPending();
        if (block.timestamp < uint256(b.listedAt) + MATURATION) revert Locked();
        uint256 fee = 0;
        try this.bagValue(bagId) returns (uint256 v) {
            fee = (v * EXIT_FEE_BPS) / BPS;
        } catch {}
        if (msg.value < fee) revert WrongPayment();

        b.status = BagStatus.Withdrawn;
        _deactivate(bagId);
        reserve += fee;
        if (msg.value > fee) {
            credits[msg.sender] += msg.value - fee;
            totalCredits += msg.value - fee;
        }
        uint256 newShares = depositorShares[msg.sender] - b.shares;
        depositorShares[msg.sender] = newShares;
        emit BagWithdrawn(bagId, msg.sender, fee);

        genesis.setShares(msg.sender, newShares);
        _sendTokens(b, msg.sender);
    }

    // ================================================================== spins

    /// @notice Public spin, open after the 48 h holder window. Pay `spinPrice().total`; any excess is credited.
    function spin() external payable nonReentrant returns (uint256) {
        if (block.timestamp < startTime) revert NotStarted();
        if (block.timestamp < startTime + HOLDER_WINDOW) revert HolderWindow();
        return _paidSpin(false);
    }

    /// @notice Holder spin: during the first 48 h only GoblinNFT holders spin (5 per NFT), with d = 5% on Genesis.
    function holderSpin(uint256 tokenId) external payable nonReentrant returns (uint256) {
        if (block.timestamp < startTime) revert NotStarted();
        if (block.timestamp >= startTime + HOLDER_WINDOW) revert WindowClosed();
        if (nft.ownerOf(tokenId) != msg.sender) revert NotHolder();
        if (holderSpinsUsed[tokenId] >= HOLDER_SPINS_PER_NFT) revert SpinLimit();
        holderSpinsUsed[tokenId] += 1;
        return _paidSpin(true);
    }

    /// @notice After mint escrow release, each GoblinNFT has 2 free Genesis spins. VRF uses its budget; keep only.
    function freeSpin(uint256 tokenId) external nonReentrant returns (uint256) {
        if (block.timestamp < startTime) revert NotStarted();
        // Refundable NFTs must not be recycled through new IDs for unlimited free coupons.
        if (!nft.released()) revert MintNotReleased();
        if (nft.ownerOf(tokenId) != msg.sender) revert NotHolder();
        if (freeSpinsUsed[tokenId] >= FREE_SPINS_PER_NFT) revert SpinLimit();
        freeSpinsUsed[tokenId] += 1;
        uint256 fee = vrf.calculateRequestPriceNative(CALLBACK_GAS, 1);
        if (vrfBudget < fee) revert ReserveTooLow();
        vrfBudget -= fee;
        bool holder = block.timestamp < startTime + HOLDER_WINDOW;
        return _request(msg.sender, 0, fee, holder, true);
    }

    function _paidSpin(bool holder) internal returns (uint256) {
        uint256 fee = vrf.calculateRequestPriceNative(CALLBACK_GAS, 1);
        if (msg.value < P + fee) revert WrongPayment();
        uint256 excess = msg.value - P - fee;
        if (excess > 0) {
            credits[msg.sender] += excess;
            totalCredits += excess;
        }
        return _request(msg.sender, P, fee, holder, false);
    }

    /// @dev Commits snapshot, values, odds, lane probability and the Genesis quote, then asks VRF.
    function _request(address spinner, uint256 paid, uint256 fee, bool holder, bool free)
        internal
        returns (uint256 id)
    {
        if (pending) revert DrawPending();
        // new spins revert while reserve < 2P x open requests (this one included)
        if (reserve < 2 * P) revert ReserveTooLow();

        _clearSnapshot();
        uint256 maxRegular = free ? 0 : _buildSnapshot();
        uint256 gTokens;
        try genesis.quote(holder) returns (uint256 quoted) {
            gTokens = quoted;
        } catch {}
        if (free && gTokens == 0) revert NothingToDraw();
        uint256 gValue = 0;
        if (gTokens > 0) {
            try oracle.valueInEth(genesis.token(), gTokens) returns (uint256 value) {
                gValue = value;
            } catch {
                gTokens = 0;
            }
        }
        if (free && gTokens == 0) revert NothingToDraw();

        uint256 gBps = GENESIS_LANE_BPS;
        bool regularEmpty = free || snapIds.length < 1;
        if (gTokens < 1) gBps = 0;
        else if (regularEmpty) gBps = BPS;
        if (gBps < 1 && regularEmpty) revert NothingToDraw();

        // worst-case payout: keep pays the depositor 95%, buyback pays the spinner 88%
        uint256 liab = (maxRegular * DEPOSITOR_BPS) / BPS;
        uint256 gLiab = free ? 0 : (gValue * BUYBACK_BPS) / BPS;
        if (gLiab > liab) liab = gLiab;
        if (reserve < liab) revert ReserveTooLow(); // hard solvency invariant
        reserve -= liab;
        locked += liab;

        pending = true;
        req.spinner = spinner;
        req.paid = paid;
        req.word = 0;
        req.fulfilled = false;
        req.liability = liab;
        req.genesisTokens = gTokens;
        req.genesisValue = gValue;
        req.genesisBps = gBps;
        req.free = free;
        req.vrfRequestId = 0;

        if (gTokens > 0 && genesis.commit(holder) != gTokens) revert NothingToDraw();
        bytes memory extra = abi.encodeWithSelector(bytes4(keccak256("VRF ExtraArgsV1")), true);
        id = vrf.requestRandomWordsInNative{value: fee}(CALLBACK_GAS, CONFIRMATIONS, 1, extra);
        if (id == 0) revert BadBag();
        req.vrfRequestId = id;
        emit SpinRequested(id, spinner, free, fee, snapIds.length);
    }

    function _clearSnapshot() internal {
        delete snapIds;
        delete snapValues;
        delete snapWeights;
        delete snapTiers;
        delete req.odds;
        delete req.tierWeight;
    }

    /// @dev Values every mature listed Bag now (before randomness) and fixes the per-tier odds.
    function _buildSnapshot() internal returns (uint256 maxValue) {
        uint256[4] memory weights = [uint256(0), 0, 0, 0];
        uint256 cap = (reserve * MAX_BAG_RESERVE_BPS) / BPS;
        bool jackpotOn = reserve >= JACKPOT_RESERVE_MULTIPLE * 70 * P;
        for (uint256 i = 0; i < activeBags.length; ++i) {
            uint256 id = activeBags[i];
            if (block.timestamp < uint256(bags[id].listedAt) + MATURATION) continue;
            uint256 v = 0;
            try this.bagValue(id) returns (uint256 got) {
                v = got;
            } catch {
                continue; // unpriceable now: not drawable in this snapshot
            }
            uint8 t = tierOf(v);
            if (t > 3 || v > cap || (t == 3 && !jackpotOn)) continue;
            uint256 w = 1e36 / Math.sqrt(v);
            snapIds.push(id);
            snapValues.push(v);
            snapWeights.push(w);
            snapTiers.push(t);
            weights[t] += w;
            if (v > maxValue) maxValue = v;
        }
        // odds of an empty tier move to the nearest lower non-empty tier, else the nearest higher one
        uint256[4] memory odds = baseOdds();
        uint256[4] memory eff = [uint256(0), 0, 0, 0];
        for (uint256 t = 0; t < 4; ++t) {
            if (weights[t] > 0) {
                eff[t] += odds[t];
                continue;
            }
            bool moved = false;
            for (uint256 k = t; k > 0; --k) {
                if (weights[k - 1] > 0) {
                    eff[k - 1] += odds[t];
                    moved = true;
                    break;
                }
            }
            for (uint256 k = t + 1; k < 4 && !moved; ++k) {
                if (weights[k] > 0) {
                    eff[k] += odds[t];
                    moved = true;
                }
            }
        }
        req.odds = eff;
        req.tierWeight = weights;
    }

    /// @notice Chainlink VRF v2.5 wrapper callback. Stores the word only; never selects, never reverts for a
    ///         stale or unknown id.
    function rawFulfillRandomWords(uint256 requestId, uint256[] memory randomWords) external {
        if (msg.sender != address(vrf)) revert OnlyWrapper();
        if (!pending || requestId != req.vrfRequestId || req.fulfilled || randomWords.length != 1) return;
        req.word = randomWords[0];
        req.fulfilled = true;
        emit SpinFulfilled(requestId, randomWords[0]);
    }

    // ================================================================== draw and settlement

    /// @notice Permissionless: turns the stored word into an allocation using only the committed snapshot.
    function draw() external nonReentrant returns (uint256 allocationId) {
        if (!pending) revert NoDrawPending();
        if (!req.fulfilled) revert NotFulfilled();
        uint256 word = req.word;
        address spinner = req.spinner;
        uint256 liab = req.liability;
        allocationId = nextAllocationId++;
        Allocation storage a = allocations[allocationId];
        a.spinner = spinner;
        a.deadline = uint64(block.timestamp + CHOICE_WINDOW);

        bool genesisLane = uint256(keccak256(abi.encode(word, "lane"))) % BPS < req.genesisBps;
        uint256 returnGenesis = 0;
        uint256 newLiab = 0;
        if (genesisLane) {
            a.genesisTokens = req.genesisTokens;
            a.value = req.genesisValue;
            a.buybackAllowed = !req.free;
            newLiab = req.free ? 0 : (req.genesisValue * BUYBACK_BPS) / BPS;
            _splitGenesis(req.paid);
            emit GenesisDrawn(allocationId, spinner, req.genesisTokens, req.genesisValue);
        } else {
            returnGenesis = req.genesisTokens;
            (uint256 idx, uint8 tier) = _select(word);
            uint256 bagId = snapIds[idx];
            a.bagId = bagId;
            a.value = snapValues[idx];
            a.buybackAllowed = true;
            newLiab = (a.value * DEPOSITOR_BPS) / BPS;
            bags[bagId].status = BagStatus.Drawn;
            _deactivate(bagId);
            _splitRegular(req.paid);
            emit BagDrawn(allocationId, bagId, spinner, a.value, tier);
        }
        // replace the worst-case earmark with this allocation's own maximum payout
        a.liability = newLiab;
        locked = locked - liab + newLiab;
        reserve = reserve + liab - newLiab;
        pending = false;
        req.paid = 0;
        if (returnGenesis > 0) genesis.uncommit(returnGenesis);
    }

    function _select(uint256 word) internal view returns (uint256 idx, uint8 tier) {
        uint256 r = uint256(keccak256(abi.encode(word, "tier"))) % BPS;
        uint256 acc = 0;
        tier = 3;
        for (uint8 t = 0; t < 4; ++t) {
            acc += req.odds[t];
            if (r < acc) {
                tier = t;
                break;
            }
        }
        uint256 pick = uint256(keccak256(abi.encode(word, "bag"))) % req.tierWeight[tier];
        uint256 run = 0;
        for (uint256 i = 0; i < snapIds.length; ++i) {
            if (snapTiers[i] != tier) continue;
            run += snapWeights[i];
            if (pick < run) return (i, tier);
        }
        revert NothingToDraw(); // unreachable: the tier has weight
    }

    function _splitGenesis(uint256 paid) internal {
        if (paid < 1) return;
        uint256 pol = (paid * 40) / 100;
        uint256 res = (paid * 30) / 100;
        uint256 holders = (paid * 15) / 100;
        uint256 teamShare = paid - pol - res - holders;
        polAccrued += pol;
        reserve += res;
        holderAccrued += holders;
        credits[team] += teamShare;
        totalCredits += teamShare;
    }

    function _splitRegular(uint256 paid) internal {
        uint256 res = (paid * 88) / 100;
        uint256 burn = (paid * 4) / 100;
        uint256 holders = (paid * 3) / 100;
        uint256 pol = (paid * 2) / 100;
        uint256 teamShare = paid - res - burn - holders - pol;
        reserve += res;
        burnAccrued += burn;
        holderAccrued += holders;
        polAccrued += pol;
        credits[team] += teamShare;
        totalCredits += teamShare;
    }

    /// @notice The winner chooses within 5 minutes: keep (true) or the 88% buyback (false).
    function choose(uint256 allocationId, bool keep) external nonReentrant {
        Allocation storage a = allocations[allocationId];
        if (a.spinner != msg.sender) revert NotSpinner();
        if (block.timestamp >= a.deadline) revert WindowClosed();
        if (!keep && !a.buybackAllowed) revert NoBuyback();
        _settle(allocationId, keep);
    }

    /// @notice After the window anyone finalizes an unchosen allocation as keep.
    function finalize(uint256 allocationId) external nonReentrant {
        Allocation storage a = allocations[allocationId];
        if (a.spinner == address(0)) revert NotSpinner();
        if (block.timestamp < a.deadline) revert WindowOpen();
        _settle(allocationId, true);
    }

    function _settle(uint256 allocationId, bool keep) internal {
        Allocation storage a = allocations[allocationId];
        if (a.settled) revert AlreadySettled();
        a.settled = true;
        uint256 liab = a.liability;
        locked -= liab;
        address spinner = a.spinner;
        if (a.bagId > 0) {
            Bag storage b = bags[a.bagId];
            address depositor = b.depositor;
            uint256 newShares = depositorShares[depositor];
            if (keep) {
                uint256 pay = (a.value * DEPOSITOR_BPS) / BPS;
                reserve += liab - pay;
                credits[depositor] += pay;
                totalCredits += pay;
                b.status = BagStatus.Kept;
                bagWinner[a.bagId] = spinner;
                newShares -= b.shares;
                depositorShares[depositor] = newShares;
                emit Kept(allocationId, spinner, pay);
                genesis.setShares(depositor, newShares);
            } else {
                uint256 pay = (a.value * BUYBACK_BPS) / BPS;
                reserve += liab - pay;
                credits[spinner] += pay;
                totalCredits += pay;
                // the Bag returns to its depositor's listing and matures again
                b.status = BagStatus.Listed;
                b.listedAt = uint64(block.timestamp);
                if (activeBags.length < MAX_ACTIVE) {
                    _activate(a.bagId);
                } else {
                    b.status = BagStatus.Withdrawn;
                    depositorShares[depositor] = newShares - b.shares;
                    bagWinner[a.bagId] = depositor;
                    genesis.setShares(depositor, newShares - b.shares);
                }
                emit BoughtBack(allocationId, spinner, pay);
            }
        } else {
            if (keep) {
                reserve += liab;
                emit Kept(allocationId, spinner, 0);
                genesis.deliver(spinner, a.genesisTokens);
            } else {
                uint256 pay = (a.value * BUYBACK_BPS) / BPS;
                reserve += liab - pay;
                credits[spinner] += pay;
                totalCredits += pay;
                emit BoughtBack(allocationId, spinner, pay);
                genesis.uncommit(a.genesisTokens);
            }
        }
    }

    /// @notice The winner of a kept Bag (or a depositor whose bought-back Bag found no free slot) pulls the tokens.
    function claimBag(uint256 bagId) external nonReentrant {
        if (bagWinner[bagId] != msg.sender) revert NotSpinner();
        bagWinner[bagId] = address(0);
        emit BagClaimed(bagId, msg.sender);
        _sendTokens(bags[bagId], msg.sender);
    }

    // ================================================================== ETH movement

    /// @notice Pull any ETH credit (payouts, refunds of overpayment, team share). Paid to the caller only.
    function withdrawCredit() external nonReentrant {
        uint256 amount = credits[msg.sender];
        if (amount < 1) revert NothingOwed();
        credits[msg.sender] = 0;
        totalCredits -= amount;
        emit CreditWithdrawn(msg.sender, amount);
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice Pulls this contract's reserve and VRF shares of the released mint escrow.
    function pullMintEscrow() external nonReentrant {
        uint256 res = nft.reserveTarget() == address(this) ? nft.reserveOwed() : 0;
        uint256 v = nft.vrfTarget() == address(this) ? nft.vrfOwed() : 0;
        if (res + v < 1) revert NothingOwed();
        reserve += res;
        vrfBudget += v;
        emit MintEscrowReceived(res, v);
        uint256 got = nft.claimRelease();
        if (got != res + v) revert TransferFailed();
    }

    /// @notice Permissionless: forwards accrued NFT-holder, POL and buy-and-burn shares to their fixed contracts.
    function flush() external nonReentrant {
        uint256 holders = holderAccrued;
        uint256 pol = polAccrued;
        uint256 burn = burnAccrued;
        holderAccrued -= holders;
        polAccrued = 0;
        burnAccrued = 0;
        emit Flushed(holders, pol, burn);
        if (holders > 0) nft.depositRevenue{value: holders}();
        if (pol > 0) polManager.depositPOL{value: pol}();
        if (burn > 0) polManager.depositBurn{value: burn}();
    }

    // ================================================================== internals

    function _activate(uint256 bagId) internal {
        activeBags.push(bagId);
        activeIndex[bagId] = activeBags.length;
    }

    function _deactivate(uint256 bagId) internal {
        uint256 pos = activeIndex[bagId];
        if (pos < 1) return;
        uint256 last = activeBags[activeBags.length - 1];
        activeBags[pos - 1] = last;
        activeIndex[last] = pos;
        activeBags.pop();
        activeIndex[bagId] = 0;
    }

    function _sendTokens(Bag storage b, address to) internal {
        for (uint256 i = 0; i < b.tokens.length; ++i) {
            IERC20(b.tokens[i]).safeTransfer(to, b.amounts[i]);
        }
    }
}
