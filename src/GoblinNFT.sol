// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {GoblinArt} from "./GoblinArt.sol";

/// @title GoblinNFT
/// @notice 10,000 on-chain goblin traders minted at 0.001 ETH with a built-in escrow that nobody can withdraw from.
///         Mint money is refundable until sellout. After sellout it can only leave the contract through
///         `release()` (50% POL / 40% payout reserve / 10% VRF budget) or through holder refunds, which reopen
///         90 days after sellout if nothing was released, and while a newly set release destination is under review.
///         At any time the contract also accepts ETH revenue (the gacha's NFT-holder share) for holders. Revenue that
///         arrives before `release()` is pooled and split equally across the tokens live at release, because until
///         then every token is still refundable at full price and must not be a free claim on other holders' revenue.
///         Revenue that arrives after `release()` accrues to the live tokens immediately.
contract GoblinNFT is ERC721, Ownable, ReentrancyGuard {
    using Strings for uint256;

    uint256 public constant PRICE = 0.001 ether;
    uint256 public constant MAX_SUPPLY = 10_000;
    uint256 public constant MAX_PER_WALLET = 20;
    uint256 public constant REFUND_REOPEN_DELAY = 90 days;
    uint256 public constant TARGET_REVIEW_PERIOD = 7 days;
    uint256 public constant FREE_SPINS_PER_TOKEN = 2;

    // ---------------------------------------------------------------- mint state
    uint256 public nextTokenId = 1;
    uint256 public liveSupply;
    mapping(address => uint256) public mintedBy;
    bool public soldOut;
    uint256 public soldOutAt;

    // ---------------------------------------------------------------- reveal
    uint256 public revealBlock;
    bytes32 public seed;
    bool public revealed;

    // ---------------------------------------------------------------- escrow release
    address public polTarget;
    address public reserveTarget;
    address public vrfTarget;
    uint256 public targetsSetAt;
    bool public targetsSet;
    bool public released;
    uint256 public polOwed;
    uint256 public reserveOwed;
    uint256 public vrfOwed;

    // ---------------------------------------------------------------- holder revenue
    uint256 public revenuePerToken; // cumulative whole wei per live token
    mapping(uint256 => uint256) public revenuePaid;
    uint256 public totalRevenueDeposited;
    uint256 public totalRevenueClaimed;
    /// @notice Whole-wei dust and zero-supply deposits. Explicitly retained forever; never part of mint escrow or an
    ///         owner's withdrawal.
    uint256 public retainedRevenue;
    /// @notice Revenue deposited before `release()`. Held in one pool, never credited to any token until release,
    ///         then split equally across the tokens live at that moment. Refunds are open or can reopen at any time
    ///         before release, so a token must not earn a share of revenue while its mint is still refundable.
    uint256 public deferredRevenue;

    event Minted(address indexed to, uint256 firstId, uint256 quantity);
    event Refunded(address indexed holder, uint256 indexed tokenId);
    event SoldOut(uint256 timestamp, uint256 revealBlock);
    event Revealed(bytes32 seed);
    event RevealRearmed(uint256 revealBlock);
    event LaunchTargetsSet(address indexed pol, address indexed reserve, address indexed vrf, uint256 reviewEnds);
    event EscrowReleased(uint256 pol, uint256 reserve, uint256 vrf);
    event ReleaseClaimed(address indexed target, uint256 amount);
    event RevenueRetained(uint256 indexed tokenId, uint256 amount);
    event RevenueAccrued(address indexed from, uint256 amount);
    event RevenueClaimed(address indexed holder, uint256 amount);
    event DeferredRevenueDistributed(uint256 amount, uint256 liveSupply);

    error WrongPayment();
    error MintClosed();
    error ExceedsSupply();
    error WalletLimit();
    error BadQuantity();
    error NotHolder();
    error RefundsClosed();
    error AlreadyReleased();
    error TargetsNotSet();
    error ReviewPending();
    error NotSoldOut();
    error ZeroAddress();
    error TargetNotContract();
    error NothingOwed();
    error TransferFailed();
    error NotReleased();
    error RevealNotReady();
    error AlreadyRevealed();
    error NonexistentToken();

    /// @param owner_ the launch owner; its only power is naming the release destinations (see README).
    constructor(address owner_) ERC721("Goblin Gold", "GOBLIN") Ownable(owner_) {}

    // ================================================================ mint and refund

    function mint(uint256 quantity) external payable nonReentrant {
        if (soldOut) revert MintClosed();
        if (quantity == 0) revert BadQuantity();
        if (msg.value != quantity * PRICE) revert WrongPayment();
        if (liveSupply + quantity > MAX_SUPPLY) revert ExceedsSupply();
        if (mintedBy[msg.sender] + quantity > MAX_PER_WALLET) revert WalletLimit();

        uint256 first = nextTokenId;
        mintedBy[msg.sender] += quantity;
        liveSupply += quantity;
        nextTokenId = first + quantity;
        if (liveSupply >= MAX_SUPPLY) {
            soldOut = true;
            soldOutAt = block.timestamp;
            revealBlock = block.number + 1;
            emit SoldOut(block.timestamp, block.number + 1);
        }
        emit Minted(msg.sender, first, quantity);
        for (uint256 i = 0; i < quantity; ++i) {
            revenuePaid[first + i] = revenuePerToken;
            _mint(msg.sender, first + i);
        }
    }

    /// @notice True while holders may burn a token for its 0.001 ETH.
    function refundsOpen() public view returns (bool) {
        if (released) return false;
        if (!soldOut) return true;
        if (block.timestamp >= soldOutAt + REFUND_REOPEN_DELAY) return true;
        return targetsSet && block.timestamp < targetsSetAt + TARGET_REVIEW_PERIOD;
    }

    function refund(uint256 tokenId) external nonReentrant {
        if (!refundsOpen()) revert RefundsClosed();
        if (_ownerOf(tokenId) != msg.sender) revert NotHolder();
        // Nothing has accrued to any token before release (revenuePerToken is still zero), so a refund forfeits
        // nothing and the token's share of the deferred pool simply stays in the pool for the remaining holders.
        liveSupply -= 1;
        _burn(tokenId);
        emit Refunded(msg.sender, tokenId);
        (bool ok,) = payable(msg.sender).call{value: PRICE}("");
        if (!ok) revert TransferFailed();
    }

    // ================================================================ reveal

    /// @notice Fixes the collection seed from the hash of the block after the sellout block. Traits were unknown to
    ///         every minter, so nobody could pick a rare token at mint time. Rarity is cosmetic only.
    function reveal() external {
        if (revealed) revert AlreadyRevealed();
        if (!soldOut || block.number <= revealBlock) revert RevealNotReady();
        bytes32 h = blockhash(revealBlock);
        if (uint256(h) < 1) {
            // More than 256 blocks passed: arm a fresh future block instead of using an empty hash.
            revealBlock = block.number + 1;
            emit RevealRearmed(block.number + 1);
            return;
        }
        seed = keccak256(abi.encode(h, address(this)));
        revealed = true;
        emit Revealed(seed);
    }

    function traitsOf(uint256 tokenId) external view returns (GoblinArt.Traits memory) {
        if (!revealed) revert RevealNotReady();
        if (_ownerOf(tokenId) == address(0)) revert NonexistentToken();
        return GoblinArt.traitsOf(seed, tokenId);
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        if (_ownerOf(tokenId) == address(0)) revert NonexistentToken();
        bytes memory image;
        bytes memory attrs;
        if (revealed) {
            GoblinArt.Traits memory t = GoblinArt.traitsOf(seed, tokenId);
            image = GoblinArt.svg(t);
            attrs = GoblinArt.attributes(t);
        } else {
            image = GoblinArt.hiddenSvg();
            attrs = '[{"trait_type":"Status","value":"Unrevealed"}]';
        }
        bytes memory json = bytes(
            string.concat(
                '{"name":"Goblin #',
                tokenId.toString(),
                '","description":"A goblin trader hauling a loot bag. Fully on-chain 32x32 pixel art.","image":"data:image/svg+xml;base64,',
                Base64.encode(image),
                '","attributes":',
                string(attrs),
                "}"
            )
        );
        return string.concat("data:application/json;base64,", Base64.encode(json));
    }

    // ================================================================ escrow release

    /// @notice Owner names the contracts that receive the escrow. Every call restarts a 7-day review window during
    ///         which holders may refund, so a bad destination can always be exited before `release()`.
    function setLaunchTargets(address pol, address reserve, address vrf) external onlyOwner {
        if (released) revert AlreadyReleased();
        if (pol == address(0) || reserve == address(0) || vrf == address(0)) revert ZeroAddress();
        if (pol.code.length == 0 || reserve.code.length == 0 || vrf.code.length == 0) revert TargetNotContract();
        polTarget = pol;
        reserveTarget = reserve;
        vrfTarget = vrf;
        targetsSet = true;
        targetsSetAt = block.timestamp;
        emit LaunchTargetsSet(pol, reserve, vrf, block.timestamp + TARGET_REVIEW_PERIOD);
    }

    function renounceOwnership() public override onlyOwner {
        if (!released) revert NotReleased();
        super.renounceOwnership();
    }

    /// @notice Permissionless. Splits the escrow into pull credits for the three destinations.
    function release() external {
        if (released) revert AlreadyReleased();
        if (!soldOut) revert NotSoldOut();
        if (!targetsSet) revert TargetsNotSet();
        if (block.timestamp < targetsSetAt + TARGET_REVIEW_PERIOD) revert ReviewPending();
        uint256 amount = liveSupply * PRICE;
        uint256 pol = amount / 2;
        uint256 res = (amount * 40) / 100;
        uint256 vrf = amount - pol - res;
        released = true;
        polOwed = pol;
        reserveOwed = res;
        vrfOwed = vrf;
        emit EscrowReleased(pol, res, vrf);
        _distributeDeferredRevenue();
    }

    /// @dev Refunds are closed for good once released: credit the pre-release revenue pool to the live tokens now.
    function _distributeDeferredRevenue() private {
        uint256 pool = deferredRevenue;
        if (pool == 0) return;
        deferredRevenue = 0;
        uint256 supply = liveSupply;
        uint256 dust = pool;
        if (supply > 0) {
            revenuePerToken += pool / supply;
            dust = pool % supply;
        }
        retainedRevenue += dust;
        if (dust > 0) emit RevenueRetained(0, dust);
        emit DeferredRevenueDistributed(pool, supply);
    }

    /// @notice Each destination pulls its own share; the ETH always goes to the caller.
    function claimRelease() external nonReentrant returns (uint256 amount) {
        if (msg.sender == polTarget) {
            amount += polOwed;
            polOwed = 0;
        }
        if (msg.sender == reserveTarget) {
            amount += reserveOwed;
            reserveOwed = 0;
        }
        if (msg.sender == vrfTarget) {
            amount += vrfOwed;
            vrfOwed = 0;
        }
        if (amount == 0) revert NothingOwed();
        emit ReleaseClaimed(msg.sender, amount);
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /// @notice What `account` can pull with `claimRelease()`.
    function releaseOwed(address account) external view returns (uint256 amount) {
        if (account == polTarget) amount += polOwed;
        if (account == reserveTarget) amount += reserveOwed;
        if (account == vrfTarget) amount += vrfOwed;
    }

    // ================================================================ holder revenue

    /// @notice Anyone may add ETH for holders, including before minting or sellout. Before `release()` the ETH is
    ///         pooled in `deferredRevenue` and split equally across the tokens live at release; after `release()` it
    ///         accrues to the live tokens at once. Division remainders and zero-supply deposits are explicitly
    ///         retained, not gifted to later mints.
    function depositRevenue() external payable {
        if (msg.value == 0) revert WrongPayment();
        totalRevenueDeposited += msg.value;
        if (!released) {
            deferredRevenue += msg.value;
            emit RevenueAccrued(msg.sender, msg.value);
            return;
        }
        uint256 dust = msg.value;
        if (liveSupply > 0) {
            revenuePerToken += msg.value / liveSupply;
            dust = msg.value % liveSupply;
        }
        retainedRevenue += dust;
        if (dust > 0) emit RevenueRetained(0, dust);
        emit RevenueAccrued(msg.sender, msg.value);
    }

    /// @notice Claimable revenue of a live token. Before release this is the token's provisional share of the
    ///         deferred pool (`deferredRevenue / liveSupply`), which becomes claimable only at `release()` and is
    ///         recomputed over whichever tokens are live then.
    function pendingRevenue(uint256 tokenId) public view returns (uint256) {
        if (_ownerOf(tokenId) == address(0)) return 0;
        uint256 pending = revenuePerToken - revenuePaid[tokenId];
        if (!released) pending += deferredRevenue / liveSupply; // liveSupply > 0: the token exists
        return pending;
    }

    /// @notice Pays the caller the accrued revenue of its tokens. Before `release()` nothing has accrued to any
    ///         token, so the call settles nothing and returns 0 instead of reverting.
    function claimRevenue(uint256[] calldata tokenIds) external nonReentrant returns (uint256 amount) {
        uint256 acc = revenuePerToken;
        for (uint256 i = 0; i < tokenIds.length; ++i) {
            uint256 id = tokenIds[i];
            if (_ownerOf(id) != msg.sender) revert NotHolder();
            amount += acc - revenuePaid[id];
            revenuePaid[id] = acc;
        }
        if (amount == 0) {
            if (released) revert NothingOwed();
            return 0;
        }
        totalRevenueClaimed += amount;
        emit RevenueClaimed(msg.sender, amount);
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
