// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {GoblinNFT} from "../src/GoblinNFT.sol";

contract EscrowTarget {
    receive() external payable {}

    function pull(GoblinNFT nft) external returns (uint256) {
        return nft.claimRelease();
    }
}

contract EscrowHandler is Test {
    GoblinNFT public nft;
    EscrowTarget[3] public targets;
    mapping(address => uint256) public owed;
    mapping(uint256 => bool) public burned;
    mapping(uint256 => uint256) public revenueClaimedAt;
    uint256 public live = 10_000;
    uint256 public deposits;
    uint256 public paid;
    uint256 public retained;
    uint256 public accumulator;
    uint256 public deferred;
    bool public released;
    address public pol;
    address public reserve;
    address public vrf;

    constructor() {
        nft = new GoblinNFT(address(this));
        for (uint256 i; i < 3; ++i) {
            targets[i] = new EscrowTarget();
        }
        for (uint256 i; i < 500; ++i) {
            address minter = address(uint160(0x10000 + i));
            vm.deal(minter, 1 ether);
            vm.prank(minter);
            nft.mint{value: 0.02 ether}(20);
        }
        vm.deal(address(this), 1_000_000 ether);
    }

    function review(uint256 a, uint256 b, uint256 c) external {
        if (released) return;
        pol = address(targets[a % 3]);
        reserve = address(targets[b % 3]);
        vrf = address(targets[c % 3]);
        nft.setLaunchTargets(pol, reserve, vrf);
    }

    function advance(uint256 seconds_) external {
        vm.warp(vm.getBlockTimestamp() + bound(seconds_, 1, 100 days));
    }

    function refund(uint256 raw) external {
        uint256 id = bound(raw, 1, 10_000);
        if (released || burned[id]) return;
        address holder = nft.ownerOf(id);
        if (!nft.refundsOpen()) {
            vm.prank(holder);
            vm.expectRevert(GoblinNFT.RefundsClosed.selector);
            nft.refund(id);
            return;
        }
        burned[id] = true;
        --live;
        retained += accumulator - revenueClaimedAt[id];
        uint256 beforeBalance = holder.balance;
        vm.prank(holder);
        nft.refund(id);
        assertEq(holder.balance - beforeBalance, 0.001 ether);
    }

    function deposit(uint256 amount) external {
        amount = bound(amount, 1, 1 ether);
        deposits += amount;
        if (!released) {
            deferred += amount;
        } else if (live == 0) {
            retained += amount;
        } else {
            accumulator += amount / live;
            retained += amount % live;
        }
        nft.depositRevenue{value: amount}();
    }

    function claim(uint256 raw) external {
        uint256 id = bound(raw, 1, 10_000);
        if (burned[id]) return;
        uint256 revenue = accumulator - revenueClaimedAt[id];
        if (revenue == 0) return;
        revenueClaimedAt[id] = accumulator;
        paid += revenue;
        uint256[] memory ids = new uint256[](1);
        ids[0] = id;
        vm.prank(nft.ownerOf(id));
        assertEq(nft.claimRevenue(ids), revenue);
    }

    function release() external {
        if (released || !nft.targetsSet() || vm.getBlockTimestamp() < nft.targetsSetAt() + 7 days) return;
        released = true;
        uint256 amount = live * 0.001 ether;
        owed[pol] += amount / 2;
        owed[reserve] += amount * 40 / 100;
        owed[vrf] += amount - amount / 2 - amount * 40 / 100;
        if (live == 0) {
            retained += deferred;
        } else {
            accumulator += deferred / live;
            retained += deferred % live;
        }
        deferred = 0;
        nft.release();
    }

    function pull(uint256 raw) external {
        EscrowTarget target = targets[raw % 3];
        uint256 amount = owed[address(target)];
        if (amount == 0) return;
        owed[address(target)] = 0;
        assertEq(target.pull(nft), amount);
    }

    function renounce() external {
        if (nft.owner() == address(0)) return;
        if (!released) vm.expectRevert(GoblinNFT.NotReleased.selector);
        nft.renounceOwnership();
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract GoblinEscrowInvariantTest is Test {
    EscrowHandler h;
    GoblinNFT nft;

    function setUp() public {
        h = new EscrowHandler();
        nft = h.nft();
        bytes4[] memory methods = new bytes4[](8);
        methods[0] = h.review.selector;
        methods[1] = h.advance.selector;
        methods[2] = h.refund.selector;
        methods[3] = h.deposit.selector;
        methods[4] = h.claim.selector;
        methods[5] = h.release.selector;
        methods[6] = h.pull.selector;
        methods[7] = h.renounce.selector;
        targetContract(address(h));
        targetSelector(FuzzSelector(address(h), methods));
    }

    function invariant_reviewsRefundsRevenueReleaseAndPullsRemainSolvent() public view {
        assertEq(nft.liveSupply(), h.live());
        assertEq(nft.released(), h.released());
        assertEq(nft.totalRevenueDeposited(), h.deposits());
        assertEq(nft.totalRevenueClaimed(), h.paid());
        assertEq(nft.retainedRevenue(), h.retained());
        assertEq(nft.revenuePerToken(), h.accumulator());
        assertEq(nft.deferredRevenue(), h.deferred());
        uint256 escrow;
        for (uint256 i; i < 3; ++i) {
            address target = address(h.targets(i));
            uint256 credit = h.owed(target);
            assertEq(nft.releaseOwed(target), credit);
            escrow += credit;
        }
        if (!h.released()) {
            escrow = h.live() * 0.001 ether;
        } else {
            assertEq(nft.polTarget(), h.pol());
            assertEq(nft.reserveTarget(), h.reserve());
            assertEq(nft.vrfTarget(), h.vrf());
            assertFalse(nft.refundsOpen());
        }
        if (nft.owner() == address(0)) assertTrue(h.released());
        assertEq(address(nft).balance, escrow + h.deposits() - h.paid());
    }
}
