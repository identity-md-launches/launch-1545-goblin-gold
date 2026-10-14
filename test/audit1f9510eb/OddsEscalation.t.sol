// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BagGacha} from "src/BagGacha.sol";

contract DrainToken is ERC20 {
    constructor() ERC20("T", "T") {
        _mint(msg.sender, 1_000_000 ether);
    }
}

/// @dev Prices every token at 1 token = 1e-3 ETH, no payout cap.
contract DrainOracle {
    function isPriced(address) external pure returns (bool) {
        return true;
    }

    function valueInEth(address, uint256 a) external pure returns (uint256) {
        return a / 1000;
    }

    function valueAndCap(address, uint256 a) external pure returns (uint256, uint256) {
        return (a / 1000, type(uint256).max);
    }

    function genesisValueAndCap(uint256 a) external pure returns (uint256, uint256) {
        return (a / 1000, type(uint256).max);
    }
}

/// @dev Auditor fixture: Genesis defaults to unavailable; tests can enable it to verify safe fallback.
contract DrainVault {
    address public immutable token;
    uint256 public available;

    function setAvailable(uint256 amount) external {
        available = amount;
    }

    constructor(address t) {
        token = t;
    }

    function quote(bool) external view returns (uint256) {
        return available;
    }

    function commit(bool) external view returns (uint256) {
        return available;
    }

    function uncommit(uint256) external {}
    function deliver(address, uint256) external {}
    function setShares(address, uint256) external {}
}

contract DrainVRF {
    uint256 public last;

    function calculateRequestPriceNative(uint32, uint32) external pure returns (uint256) {
        return 0.0005 ether;
    }

    function requestRandomWordsInNative(uint32, uint16, uint32, bytes calldata) external payable returns (uint256) {
        last += 1;
        return last;
    }

    function fulfill(address consumer, uint256 id, uint256 word) external {
        uint256[] memory w = new uint256[](1);
        w[0] = word;
        BagGacha(payable(consumer)).rawFulfillRandomWords(id, w);
    }
}

contract Sink {
    function depositPOL() external payable {}
    function depositBurn() external payable {}
}

/// @notice Audit 1f9510eb proof adapted to require rejection of the original inventory-control attack.
///         Genesis fallback and fuzzed tier subsets verify that no lower tier can donate odds upward.
contract OddsEscalationDrainTest is Test {
    BagGacha gacha;
    DrainToken token;
    DrainVRF vrf;
    DrainVault vault;
    address attacker = address(0xA11CE);

    function setUp() public {
        vm.warp(1_000_000);
        token = new DrainToken();
        vrf = new DrainVRF();
        vault = new DrainVault(address(0xB0B)); // GOLD is some other address
        gacha = new BagGacha(
            address(new DrainOracle()),
            address(vault),
            address(0xCAFE), // nft: never called on this path
            address(vrf),
            address(new Sink()),
            address(0x7EA0),
            vm.getBlockTimestamp(),
            address(this)
        );
        vm.deal(address(this), 100 ether);
        gacha.fundReserve{value: 4 ether}();
        token.transfer(attacker, 1000 ether);
        vm.deal(attacker, 10 ether);
        vm.warp(vm.getBlockTimestamp() + gacha.HOLDER_WINDOW());
    }

    function testEmptyTierOddsMustNotEscalateToTheOnlyBag() public {
        // one large-tier Bag: 59 tokens = 0.059 ETH (large tier is [2P, 6P)), under 5% of the 4 ETH reserve
        address[] memory toks = new address[](1);
        toks[0] = address(token);
        uint256[] memory amts = new uint256[](1);
        amts[0] = 59 ether;
        vm.startPrank(attacker);
        token.approve(address(gacha), type(uint256).max);
        gacha.seal(toks, amts);
        vm.warp(vm.getBlockTimestamp() + gacha.MATURATION());

        uint256 reserveBefore = gacha.reserve();
        (uint256 price,) = gacha.spinPrice();
        vm.expectRevert(BagGacha.NothingToDraw.selector);
        gacha.spin{value: price}();
        vm.stopPrank();
        (,,,, uint256[4] memory odds,) = gacha.currentRequest();
        assertLe(odds[2], 700, "empty lower tiers cannot subsidize the large tier");
        assertEq(gacha.reserve(), reserveBefore);
        assertEq(gacha.credits(attacker), 0);
        assertEq(vrf.last(), 0, "no fee spent on an impossible request");
        assertFalse(gacha.pending());
    }

    function _seal(uint256 amount) internal returns (uint256) {
        address[] memory tokens = new address[](1);
        tokens[0] = address(token);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        vm.startPrank(attacker);
        token.approve(address(gacha), amount);
        uint256 id = gacha.seal(tokens, amounts);
        vm.stopPrank();
        return id;
    }

    function testOnlyLargeInventoryFallsBackToGenesisWithoutRegularLiability() public {
        _seal(59 ether);
        vm.warp(vm.getBlockTimestamp() + gacha.MATURATION());
        vault.setAvailable(9 ether); // 0.009 ETH Genesis mark
        (uint256 total,) = gacha.spinPrice();
        vm.prank(attacker);
        uint256 id = gacha.spin{value: total}();
        (,,, uint256 liability, uint256[4] memory odds, uint256 genesisBps) = gacha.currentRequest();
        assertEq(genesisBps, 10_000);
        assertEq(liability, 0.009 ether * 8800 / 10_000);
        assertLe(odds[2], 700);
        (uint256[] memory ids,,) = gacha.snapshot();
        assertEq(ids.length, 0);
        vrf.fulfill(address(gacha), id, uint256(keccak256("any word")));
        uint256 allocation = gacha.draw();
        (, uint256 bag,, uint256 genesisTokens,,,,) = gacha.allocations(allocation);
        assertEq(bag, 0);
        assertEq(genesisTokens, 9 ether);
        assertEq(gacha.activeCount(), 1, "large bag remains listed");
        vm.warp(vm.getBlockTimestamp() + gacha.CHOICE_WINDOW());
        gacha.finalize(allocation);
        assertEq(gacha.credits(attacker), 0, "no 95 percent large-bag payout");
    }

    function testFuzzOddsOnlyMoveDown(uint8 mask, uint256 word) public {
        mask = uint8(bound(mask, 1, 15));
        gacha.fundReserve{value: 10 ether}(); // jackpot enabled
        uint256[4] memory amounts = [uint256(5 ether), 10 ether, 59 ether, 70 ether];
        for (uint256 t; t < 4; ++t) {
            if (mask & (1 << t) != 0) _seal(amounts[t]);
        }
        vm.warp(vm.getBlockTimestamp() + gacha.MATURATION());
        (uint256 total,) = gacha.spinPrice();
        vm.prank(attacker);
        if (mask & 1 == 0) {
            vm.expectRevert(BagGacha.NothingToDraw.selector);
            gacha.spin{value: total}();
            return;
        }
        uint256 id = gacha.spin{value: total}();
        (,,,, uint256[4] memory odds,) = gacha.currentRequest();
        uint256[4] memory base = gacha.baseOdds();
        uint256 sum;
        for (uint256 t; t < 4; ++t) {
            uint256 expected;
            if (mask & (1 << t) != 0) {
                expected = base[t];
                for (uint256 j = t + 1; j < 4 && mask & (1 << j) == 0; ++j) {
                    expected += base[j];
                }
            }
            assertEq(odds[t], expected, "only nearest lower non-empty tier inherits odds");
            sum += odds[t];
        }
        assertEq(sum, 10_000);
        vrf.fulfill(address(gacha), id, word);
        uint256 allocation = gacha.draw();
        (, uint256 bag,,,,,,) = gacha.allocations(allocation);
        assertGt(bag, 0);
    }
}
