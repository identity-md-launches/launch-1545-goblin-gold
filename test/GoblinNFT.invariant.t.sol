// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {GoblinNFT} from "../src/GoblinNFT.sol";

contract NFTHandler is Test {
    GoblinNFT public nft;
    address[8] public actors;
    mapping(uint256 => address) public holder;
    mapping(uint256 => uint256) public owed;
    uint256 public live;
    uint256 public deposited;
    uint256 public paid;
    uint256 public retained;
    uint256 public minted;

    constructor() {
        nft = new GoblinNFT(address(this));
        for (uint256 i; i < 8; ++i) {
            actors[i] = address(uint160(0x8000 + i));
            vm.deal(actors[i], 1000 ether);
        }
        vm.deal(address(this), 1_000_000 ether);
    }

    function mint(uint256 actor, uint256 quantity) external {
        address to = actors[actor % 8];
        uint256 remaining = 20 - nft.mintedBy(to);
        if (remaining == 0) return;
        quantity = bound(quantity, 1, remaining);
        uint256 first = nft.nextTokenId();
        vm.prank(to);
        nft.mint{value: quantity * 0.001 ether}(quantity);
        live += quantity;
        minted += quantity;
        for (uint256 id = first; id < first + quantity; ++id) {
            holder[id] = to;
        }
    }

    function deposit(uint256 amount) external {
        amount = bound(amount, 1, 1 ether);
        deposited += amount;
        if (live == 0) {
            retained += amount;
        } else {
            retained += amount % live;
            for (uint256 id = 1; id <= minted; ++id) {
                if (holder[id] != address(0)) owed[id] += amount / live;
            }
        }
        nft.depositRevenue{value: amount}();
    }

    function refund(uint256 rawId) external {
        if (minted == 0) return;
        uint256 id = bound(rawId, 1, minted);
        address who = holder[id];
        if (who == address(0)) return;
        retained += owed[id];
        owed[id] = 0;
        holder[id] = address(0);
        --live;
        vm.prank(who);
        nft.refund(id);
    }

    function claim(uint256 rawId) external {
        if (minted == 0) return;
        uint256 id = bound(rawId, 1, minted);
        address who = holder[id];
        if (who == address(0) || owed[id] == 0) return;
        uint256 expected = owed[id];
        owed[id] = 0;
        paid += expected;
        uint256[] memory ids = new uint256[](2);
        ids[0] = id;
        ids[1] = id;
        vm.prank(who);
        assertEq(nft.claimRevenue(ids), expected);
    }

    function transfer(uint256 rawId, uint256 recipient) external {
        if (minted == 0) return;
        uint256 id = bound(rawId, 1, minted);
        address who = holder[id];
        if (who == address(0)) return;
        address to = actors[recipient % 8];
        holder[id] = to;
        vm.prank(who);
        nft.transferFrom(who, to, id);
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract GoblinNFTInvariantTest is Test {
    NFTHandler handler;
    GoblinNFT nft;

    function setUp() public {
        handler = new NFTHandler();
        nft = handler.nft();
        bytes4[] memory methods = new bytes4[](5);
        methods[0] = handler.mint.selector;
        methods[1] = handler.deposit.selector;
        methods[2] = handler.refund.selector;
        methods[3] = handler.claim.selector;
        methods[4] = handler.transfer.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), methods));
    }

    function invariant_revenueAndRefundBackingMatchIndependentLedger() public view {
        assertEq(nft.liveSupply(), handler.live());
        assertEq(nft.totalRevenueDeposited(), handler.deposited());
        assertEq(nft.totalRevenueClaimed(), handler.paid());
        assertEq(nft.retainedRevenue(), handler.retained());
        uint256 pending;
        for (uint256 id = 1; id <= handler.minted(); ++id) {
            assertEq(nft.pendingRevenue(id), handler.owed(id));
            pending += handler.owed(id);
            if (handler.holder(id) != address(0)) assertEq(nft.ownerOf(id), handler.holder(id));
        }
        assertEq(pending + handler.retained() + handler.paid(), handler.deposited());
        assertEq(address(nft).balance, handler.live() * 0.001 ether + pending + handler.retained());
        for (uint256 i; i < 8; ++i) {
            assertLe(nft.mintedBy(handler.actors(i)), 20);
        }
        assertLe(nft.liveSupply(), 10_000);
    }
}
