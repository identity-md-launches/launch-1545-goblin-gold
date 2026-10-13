// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {GenesisVault} from "../src/GenesisVault.sol";
import {MockERC20, MockOracle} from "./mocks/Mocks.sol";

contract GenesisVaultTest is Test {
    GenesisVault vault;
    MockERC20 token;
    MockOracle oracle;
    uint256 constant SUPPLY = 540_000 ether;
    uint256 constant DIVIDENDS = 54_000 ether;
    uint256 start;

    function setUp() public {
        token = new MockERC20("T");
        oracle = new MockOracle();
        oracle.set(address(token), 1e12);
        start = vm.getBlockTimestamp() + 1 days;
        vault =
            new GenesisVault(address(token), address(oracle), address(this), start, SUPPLY, DIVIDENDS, address(this));
        token.mint(address(vault), SUPPLY);
    }

    function testNotStartedUnfundedAndProtectedEntryPoints() public {
        assertEq(vault.quote(false), 0);
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(GenesisVault.OnlyGacha.selector);
        vault.commit(false);
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(GenesisVault.OnlyGacha.selector);
        vault.deliver(address(this), 1);
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(GenesisVault.OnlyGacha.selector);
        vault.uncommit(1);
        vm.prank(makeAddr("attacker"));
        vm.expectRevert(GenesisVault.OnlyGacha.selector);
        vault.setShares(address(this), 1);
        vm.warp(start);
        vm.prank(address(vault));
        token.transfer(address(this), 1);
        assertEq(vault.quote(false), 0);
    }

    function testHugeQuoteCappedAtThreeDaysAndReopensWithSchedule() public {
        vm.warp(start);
        oracle.set(address(token), 1); // cheap token: raw quote much larger than the whole supply
        uint256 cap = (vault.distributable() * 3) / 540;
        assertEq(vault.quote(false), cap);
        assertEq(vault.commit(false), cap);
        assertEq(vault.quote(false), 0);
        vm.warp(start + 1 days);
        assertEq(vault.quote(false), vault.distributable() / 540);
        vault.uncommit(cap);
        assertEq(vault.emitted(), 0);
    }

    function testScheduleDecayAndDiscountLimits() public {
        vm.warp(start);
        oracle.set(address(token), 1e13); // quote = 920 tokens, daily schedule = 900 tokens
        uint256 one = vault.commit(false);
        assertEq(one, 920 ether);
        assertEq(vault.quote(false), 828 ether);
        vault.commit(false); // 1748, still one whole day ahead
        vault.commit(false); // 2576, now two whole days ahead
        assertEq(vault.quote(false), 124 ether); // three-day ceiling is stricter than the decayed quote
        vault.commit(false);
        assertEq(vault.quote(false), 0);
        vm.expectRevert(GenesisVault.DiscountOutOfBounds.selector);
        vault.setDiscount(499);
        vm.expectRevert(GenesisVault.DiscountOutOfBounds.selector);
        vault.setDiscount(1201);
        vault.setDiscount(500);
        vault.setDiscount(1200);
    }

    function testDividendsAndGenesisClaimsRemainSolventAndCannotPayTwice() public {
        vm.warp(start);
        vault.setShares(address(this), 9);
        uint256 committed = vault.commit(false);
        vault.deliver(address(this), committed);
        vault.claim();
        vm.expectRevert(GenesisVault.NothingToClaim.selector);
        vault.claim();
        vm.warp(start + 540 days);
        assertEq(vault.pendingDividends(address(this)), DIVIDENDS);
        vault.claimDividends();
        vm.expectRevert(GenesisVault.NothingToClaim.selector);
        vault.claimDividends();
        assertEq(token.balanceOf(address(vault)) + token.balanceOf(address(this)), SUPPLY);
        assertEq(vault.withdrawn(), committed + DIVIDENDS);
        assertLe(vault.quote(false), vault.distributable() - vault.emitted());
    }

    function testFuzzCurveBounds(uint256 price, uint256 elapsed, uint256 discount, bool holder) public {
        price = bound(price, 1, 1e30);
        elapsed = bound(elapsed, 0, 800 days);
        discount = bound(discount, 500, 1200);
        oracle.set(address(token), price);
        vault.setDiscount(discount);
        vm.warp(start + elapsed);
        uint256 amount = vault.quote(holder);
        assertLe(amount, vault.distributable());
        assertLe(amount, vault.target() + (vault.distributable() * 3) / 540);
        uint256 d = holder ? 500 : discount;
        assertLe(amount, oracle.tokensForEth(address(token), (0.01 ether * (10_000 - d)) / 10_000));
        assertEq(vault.commit(holder), amount);
        assertLe(vault.emitted(), vault.target() + (vault.distributable() * 3) / 540);
        assertLe(vault.quote(holder), vault.distributable() - amount);
    }
}
