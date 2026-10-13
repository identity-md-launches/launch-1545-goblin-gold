// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {BagGacha} from "../src/BagGacha.sol";
import {GenesisVault} from "../src/GenesisVault.sol";
import {GoblinNFT} from "../src/GoblinNFT.sol";
import {MockERC20, MockOracle, MockPOL, MockVRFWrapper} from "./mocks/Mocks.sol";

contract GachaHandler is Test {
    BagGacha public gacha;
    GenesisVault public genesis;
    GoblinNFT public nft;
    MockERC20 public bagToken;
    MockERC20 public platform;
    MockOracle public oracle;
    MockVRFWrapper public vrf;
    address public team = address(0x7EA);
    uint256 public successfulSettlements;
    uint256 public successfulDraws;
    uint256 public successfulSpins;

    constructor() {
        vm.deal(address(this), 1_000_000 ether);
        oracle = new MockOracle();
        vrf = new MockVRFWrapper();
        MockPOL pol = new MockPOL();
        bagToken = new MockERC20("BAG");
        platform = new MockERC20("PLATFORM");
        oracle.set(address(bagToken), 1e15);
        oracle.set(address(platform), 1e12);
        nft = new GoblinNFT(address(this));
        nft.mint{value: 0.001 ether}(1);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        genesis = new GenesisVault(
            address(platform), address(oracle), predicted, vm.getBlockTimestamp(), 1e27, 2e25, address(this)
        );
        gacha = new BagGacha(
            address(oracle),
            address(genesis),
            address(nft),
            address(vrf),
            address(pol),
            team,
            vm.getBlockTimestamp(),
            address(this)
        );
        platform.mint(address(genesis), 1e27);
        bagToken.mint(address(this), 1e30);
        bagToken.approve(address(gacha), 1e30);
        gacha.fundReserve{value: 30 ether}();
        gacha.fundVRF{value: 1 ether}();
        vm.warp(vm.getBlockTimestamp() + 3 days);
    }
    receive() external payable {}

    function seal(uint256 amount) external {
        if (gacha.activeCount() == gacha.MAX_ACTIVE()) return;
        amount = bound(amount, 3e18, 200e18);
        address[] memory ts = new address[](1);
        ts[0] = address(bagToken);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        try gacha.seal(ts, amounts) {} catch {}
    }

    function spin(bool free) external {
        if (gacha.pending()) return;
        if (free) {
            try gacha.freeSpin(1) {
                ++successfulSpins;
            } catch {}
        } else {
            (uint256 price,) = gacha.spinPrice();
            try gacha.spin{value: price + 3}() {
                ++successfulSpins;
            } catch {}
        }
    }

    function fulfill(uint256 word, bool wrongId) external {
        if (!gacha.pending()) return;
        (, uint256 id,,,,) = gacha.currentRequest();
        vrf.fulfill(address(gacha), wrongId ? id ^ 1 : id, word);
    }

    function draw() external {
        if (!gacha.pending()) return;
        (,, bool ready,,,) = gacha.currentRequest();
        if (!ready) return;
        gacha.draw();
        ++successfulDraws;
    }

    function settle(uint256 rawId, bool keep, bool finalize) external {
        if (gacha.nextAllocationId() == 1) return;
        uint256 id = bound(rawId, 1, gacha.nextAllocationId() - 1);
        (,,,,, uint64 deadline, bool canBuyback, bool settled) = gacha.allocations(id);
        if (settled) {
            // Retrying a completed allocation can never generate a second credit.
            uint256 beforeCredit = gacha.totalCredits();
            try gacha.choose(id, true) {
                revert("double settlement");
            } catch {}
            assertEq(gacha.totalCredits(), beforeCredit);
            return;
        }
        if (finalize || vm.getBlockTimestamp() >= deadline) {
            if (vm.getBlockTimestamp() < deadline) vm.warp(deadline);
            gacha.finalize(id);
        } else {
            gacha.choose(id, keep || !canBuyback);
        }
        ++successfulSettlements;
    }

    function advance(uint256 seconds_) external {
        vm.warp(vm.getBlockTimestamp() + bound(seconds_, 1, 2 days));
    }

    function withdrawBag(uint256 rawId) external {
        if (gacha.nextBagId() == 1 || gacha.pending()) return;
        uint256 id = bound(rawId, 1, gacha.nextBagId() - 1);
        (, BagGacha.BagStatus status, uint64 time,,) = gacha.bagInfo(id);
        if (status != BagGacha.BagStatus.Listed || vm.getBlockTimestamp() < uint256(time) + 1 days) return;
        uint256 fee;
        try gacha.bagValue(id) returns (uint256 value) {
            fee = value * 50 / 10_000;
        } catch {}
        gacha.withdraw{value: fee}(id);
    }

    function claim(uint256 rawId) external {
        if (gacha.nextBagId() > 1) {
            uint256 id = bound(rawId, 1, gacha.nextBagId() - 1);
            if (gacha.bagWinner(id) == address(this)) gacha.claimBag(id);
        }
        if (gacha.credits(address(this)) > 0) gacha.withdrawCredit();
        if (genesis.claimable(address(this)) > 0) genesis.claim();
        if (genesis.pendingDividends(address(this)) > 0) genesis.claimDividends();
    }

    function changeAvailability(bool brokenBag, bool brokenPlatform) external {
        oracle.breakToken(address(bagToken), brokenBag);
        oracle.breakToken(address(platform), brokenPlatform);
    }

    /// @dev Pool depth moves: the payout cap of the Bag token lands anywhere from binding hard to unlimited.
    function changeCap(uint256 raw, bool unlimited) external {
        oracle.setCap(address(bagToken), unlimited ? 0 : bound(raw, 0.001 ether, 0.2 ether));
    }

    function flush() external {
        gacha.flush();
    }
}

/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract BagGachaInvariantTest is Test {
    GachaHandler h;
    BagGacha g;

    function setUp() public {
        h = new GachaHandler();
        g = h.gacha();
        bytes4[] memory m = new bytes4[](11);
        m[0] = h.seal.selector;
        m[1] = h.spin.selector;
        m[2] = h.fulfill.selector;
        m[3] = h.draw.selector;
        m[4] = h.settle.selector;
        m[5] = h.advance.selector;
        m[6] = h.withdrawBag.selector;
        m[7] = h.claim.selector;
        m[8] = h.changeAvailability.selector;
        m[9] = h.flush.selector;
        m[10] = h.changeCap.selector;
        targetContract(address(h));
        targetSelector(FuzzSelector(address(h), m));
    }

    function invariant_allReserveAndTokenLiabilitiesAreBacked() public view {
        assertEq(
            address(g).balance,
            g.reserve() + g.locked() + g.vrfBudget() + g.holderAccrued() + g.polAccrued() + g.burnAccrued()
                + g.totalCredits() + g.heldSpinPayment()
        );
        assertEq(g.totalCredits(), g.credits(address(h)) + g.credits(h.team()));
        uint256 liabilities;
        if (g.pending()) (,,, liabilities,,) = g.currentRequest();
        for (uint256 id = 1; id < g.nextAllocationId(); ++id) {
            (,,,, uint256 liability,,, bool settled) = g.allocations(id);
            if (!settled) liabilities += liability;
        }
        assertEq(g.locked(), liabilities);
        uint256 tokensOwed;
        for (uint256 id = 1; id < g.nextBagId(); ++id) {
            (, BagGacha.BagStatus status,,, uint256[] memory amounts) = g.bagInfo(id);
            if (
                status == BagGacha.BagStatus.Listed || status == BagGacha.BagStatus.Drawn
                    || g.bagWinner(id) != address(0)
            ) {
                tokensOwed += amounts[0];
            }
        }
        assertEq(h.bagToken().balanceOf(address(g)), tokensOwed);
        GenesisVault genesis = h.genesis();
        assertEq(h.platform().balanceOf(address(genesis)) + genesis.withdrawn(), genesis.genesisSupply());
        assertLe(genesis.totalClaimable(), h.platform().balanceOf(address(genesis)));
        assertLe(genesis.emitted(), genesis.distributable());
        assertLe(h.successfulSettlements(), h.successfulDraws());
        assertLe(h.successfulDraws(), h.successfulSpins());
    }
}
