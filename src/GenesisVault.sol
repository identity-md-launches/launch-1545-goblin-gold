// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface ITokenOracle {
    function tokensForEth(address token, uint256 ethAmount) external view returns (uint256);
    function valueInEth(address token, uint256 amount) external view returns (uint256);
}

/// @title GenesisVault
/// @notice Holds the platform-token Genesis supply. Prices Genesis Bags on a 540-day schedule, reserves their tokens
///         when a spin is requested, and streams 2% of supply as dividends to sqrt-value shares of listed Bags.
///         Tokens only ever leave to the account that claims them. Code only: not deployed by this job.
contract GenesisVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant SPIN_PRICE = 0.01 ether;
    uint256 public discountBps = 800; // d = 8% (design band 5-12%)
    uint256 public constant HOLDER_DISCOUNT_BPS = 500; // d = 5% for NFT holders in the first 48 h
    uint256 public constant SCHEDULE = 540 days;
    uint256 public constant MAX_AHEAD_DAYS = 3;
    uint256 private constant ACC = 1e18;

    IERC20 public immutable token;
    ITokenOracle public immutable oracle;
    address public immutable gacha;
    address public immutable curator;
    uint256 public immutable startTime;
    uint256 public immutable genesisSupply; // total tokens this vault is funded with
    uint256 public immutable dividendBudget; // 2% of token supply, streamed over SCHEDULE

    uint256 public emitted; // Genesis tokens committed or delivered
    mapping(address => uint256) public claimable;
    uint256 public totalClaimable;

    // dividend accumulator
    uint256 public accPerShare;
    uint256 public lastAccrual;
    uint256 public totalShares;
    uint256 public dividendsStreamed;
    mapping(address => uint256) public shares;
    mapping(address => uint256) public rewardDebt;
    mapping(address => uint256) public dividendOwed;

    event GenesisCommitted(uint256 tokens);
    event GenesisReturned(uint256 tokens);
    event GenesisDelivered(address indexed to, uint256 tokens);
    event Claimed(address indexed account, uint256 tokens);
    event SharesUpdated(address indexed account, uint256 shares);
    event DividendClaimed(address indexed account, uint256 tokens);

    error OnlyGacha();
    error OnlyCurator();
    error DiscountOutOfBounds();
    event DiscountSet(uint256 discountBps);
    error NothingToClaim();
    error BadConfig();

    modifier onlyGacha() {
        if (msg.sender != gacha) revert OnlyGacha();
        _;
    }

    constructor(
        address token_,
        address oracle_,
        address gacha_,
        uint256 startTime_,
        uint256 genesisSupply_,
        uint256 dividendBudget_,
        address curator_
    ) {
        if (token_ == address(0) || oracle_ == address(0) || gacha_ == address(0) || curator_ == address(0)) {
            revert BadConfig();
        }
        if (dividendBudget_ >= genesisSupply_) revert BadConfig();
        curator = curator_;
        token = IERC20(token_);
        oracle = ITokenOracle(oracle_);
        gacha = gacha_;
        startTime = startTime_;
        genesisSupply = genesisSupply_;
        dividendBudget = dividendBudget_;
        lastAccrual = startTime_;
    }

    function setDiscount(uint256 bps) external {
        if (msg.sender != curator) revert OnlyCurator();
        if (bps < 500 || bps > 1200) revert DiscountOutOfBounds();
        discountBps = bps;
        emit DiscountSet(bps);
    }

    function distributable() public view returns (uint256) {
        return genesisSupply - dividendBudget;
    }

    /// @notice Linear emission target at the current time.
    function target() public view returns (uint256) {
        if (block.timestamp <= startTime) return 0;
        uint256 elapsed = block.timestamp - startTime;
        if (elapsed >= SCHEDULE) return distributable();
        return (distributable() * elapsed) / SCHEDULE;
    }

    /// @notice Tokens in one Genesis Bag now: min((1-d)P / minTWAP, schedule-decayed, remaining). Zero when the
    ///         vault is unfunded, sold out, or more than MAX_AHEAD_DAYS ahead of schedule.
    function quote(bool holder) public view returns (uint256 tokens) {
        if (block.timestamp < startTime) return 0;
        if (token.balanceOf(address(this)) < genesisSupply - emittedDelivered()) return 0;
        uint256 left = distributable() - emitted;
        if (left < 1) return 0;
        uint256 d = holder ? HOLDER_DISCOUNT_BPS : discountBps;
        tokens = oracle.tokensForEth(address(token), (SPIN_PRICE * (10_000 - d)) / 10_000);
        uint256 tgt = target();
        if (emitted > tgt) {
            uint256 aheadDays = ((emitted - tgt) * SCHEDULE) / (distributable() * 1 days);
            if (aheadDays >= MAX_AHEAD_DAYS) return 0;
            for (uint256 i = 0; i < aheadDays; ++i) {
                tokens = (tokens * 9) / 10;
            }
        }
        // A single cheap-token quote cannot jump beyond the same three-day bound.
        uint256 ceiling = tgt + Math.mulDiv(distributable(), MAX_AHEAD_DAYS * 1 days, SCHEDULE);
        if (ceiling > distributable()) ceiling = distributable();
        if (emitted >= ceiling) return 0;
        uint256 headroom = ceiling - emitted;
        if (tokens > headroom) tokens = headroom;
        if (tokens > left) tokens = left;
    }

    /// @dev Tokens that already left the vault (claims). Used to check the vault still holds what it owes.
    uint256 public withdrawn;

    function emittedDelivered() public view returns (uint256) {
        return withdrawn;
    }

    /// @notice Reserve a Genesis Bag's tokens at request time, before randomness.
    function commit(bool holder) external onlyGacha returns (uint256 tokens) {
        tokens = quote(holder);
        if (tokens > 0) {
            emitted += tokens;
            emit GenesisCommitted(tokens);
        }
    }

    /// @notice Return reserved tokens (draw went to the regular lane, or the Bag was bought back).
    function uncommit(uint256 tokens) external onlyGacha {
        emitted -= tokens;
        emit GenesisReturned(tokens);
    }

    /// @notice Credit a kept Genesis Bag to its winner; the winner pulls with `claim()`.
    function deliver(address to, uint256 tokens) external onlyGacha {
        claimable[to] += tokens;
        totalClaimable += tokens;
        emit GenesisDelivered(to, tokens);
    }

    function claim() external nonReentrant {
        uint256 amount = claimable[msg.sender];
        if (amount < 1) revert NothingToClaim();
        claimable[msg.sender] = 0;
        totalClaimable -= amount;
        withdrawn += amount;
        emit Claimed(msg.sender, amount);
        token.safeTransfer(msg.sender, amount);
    }

    // ---------------------------------------------------------------- dividends

    function _accrue() internal {
        uint256 end = block.timestamp < startTime + SCHEDULE ? block.timestamp : startTime + SCHEDULE;
        if (end <= lastAccrual) return;
        uint256 streamedTotal = (dividendBudget * (end - startTime)) / SCHEDULE;
        uint256 fresh = streamedTotal - dividendsStreamed;
        dividendsStreamed = streamedTotal;
        lastAccrual = end;
        if (totalShares > 0) accPerShare += (fresh * ACC) / totalShares;
        // with no shares the slice stays in the vault, unassigned
    }

    function _settle(address account) internal {
        uint256 accrued = (shares[account] * accPerShare) / ACC;
        dividendOwed[account] += accrued - rewardDebt[account];
        rewardDebt[account] = accrued;
    }

    /// @notice The gacha sets an account's sqrt-value share total when its listed Bags change.
    function setShares(address account, uint256 newShares) external onlyGacha {
        _accrue();
        _settle(account);
        totalShares = totalShares - shares[account] + newShares;
        shares[account] = newShares;
        rewardDebt[account] = (newShares * accPerShare) / ACC;
        emit SharesUpdated(account, newShares);
    }

    function pendingDividends(address account) external view returns (uint256) {
        uint256 acc = accPerShare;
        uint256 end = block.timestamp < startTime + SCHEDULE ? block.timestamp : startTime + SCHEDULE;
        if (end > lastAccrual && totalShares > 0) {
            uint256 fresh = (dividendBudget * (end - startTime)) / SCHEDULE - dividendsStreamed;
            acc += (fresh * ACC) / totalShares;
        }
        return dividendOwed[account] + (shares[account] * acc) / ACC - rewardDebt[account];
    }

    function claimDividends() external nonReentrant {
        _accrue();
        _settle(msg.sender);
        uint256 amount = dividendOwed[msg.sender];
        if (amount < 1) revert NothingToClaim();
        dividendOwed[msg.sender] = 0;
        withdrawn += amount;
        emit DividendClaimed(msg.sender, amount);
        token.safeTransfer(msg.sender, amount);
    }
}
