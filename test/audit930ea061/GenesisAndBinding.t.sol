// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {V4Fixture} from "../mocks/V4Fixture.sol";
import {BagGacha} from "../../src/BagGacha.sol";
import {GenesisVault} from "../../src/GenesisVault.sol";
import {GoldHook} from "../../src/GoldHook.sol";
import {TwapOracle} from "../../src/TwapOracle.sol";
import {POLManager} from "../../src/POLManager.sol";
import {MockERC20, MockVRFWrapper} from "../mocks/Mocks.sol";
import {MockV3Factory} from "../mocks/CuratorMocks.sol";
import {CheckLaunch} from "../../script/CheckLaunch.s.sol";
import {PoolKey, ModifyLiquidityParams} from "../../src/v4/V4Minimal.sol";

abstract contract Audit930Fixture is V4Fixture {
    TwapOracle oracle;
    POLManager pol;
    BagGacha gacha;
    GenesisVault vault;

    function _setup(uint128 l) internal {
        _deployV4(keccak256(type(BagGacha).runtimeCode));
        _initialize();
        _seed(l + 10, l + 10, int256(uint256(l)));
        oracle = new TwapOracle(
            address(this), address(new MockERC20("WETH")), address(new MockV3Factory()), address(gold), HOOK_ADDRESS
        );
        pol = new POLManager(address(manager), address(gold), HOOK_ADDRESS, address(oracle), NFT_ADDRESS);
        MockVRFWrapper vrf = new MockVRFWrapper();
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        vault = new GenesisVault(address(gold), address(oracle), predicted, block.timestamp, 1e24, 1e22, address(this));
        gacha = new BagGacha(
            address(oracle), address(vault), NFT_ADDRESS, address(vrf), address(pol), address(this), 1, address(this)
        );
        assertEq(address(gacha), predicted);
        gacha.fundReserve{value: 10 ether}();
    }

    function _history() internal {
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _swap(trader, true, -1e9);
        vm.warp(vm.getBlockTimestamp() + 4 hours);
        _swap(trader, false, -1e9);
    }
}

contract GenesisSpotDepthTest is Audit930Fixture {
    function setUp() public {
        _setup(1 ether + 1e12);
    }

    function _refuseRegularGold() internal {
        address[] memory tokens = new address[](1);
        tokens[0] = address(gold);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = 0.03 ether;
        gold.mint(address(this), amounts[0]);
        gold.approve(address(gacha), amounts[0]);
        vm.expectRevert(BagGacha.BadBag.selector);
        gacha.seal(tokens, amounts);
        assertEq(gold.balanceOf(address(gacha)), 0);
    }

    function testFourHourPumpCapAndRegularGenesisExclusion() public {
        _history();
        _refuseRegularGold(); // auditor's first step already fails: GOLD is Genesis-only
        uint256 cap = oracle.payoutCap(address(gold));
        assertApproxEqAbs(cap, 0.05 ether, 1e11);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        _swap(trader, true, -1e9); // fresh observation before the pump
        cap = oracle.payoutCap(address(gold));
        _swap(trader, true, -2.16 ether);
        assertEq(oracle.payoutCap(address(gold)), cap, "same-tx spot pump cannot lift cap");
        for (uint256 i; i < 4; ++i) {
            vm.warp(vm.getBlockTimestamp() + 1 hours);
            _swap(trader, true, -1e9);
        }
        assertGt(oracle.valueInEth(address(gold), 0.03 ether), 0.28 ether);
        _refuseRegularGold(); // even after both windows move, no regular Bag can exploit the mark
        gold.mint(address(vault), vault.genesisSupply());
        uint256 quote = vault.quote(false);
        assertGt(quote, 0);
        (uint256 value,) = oracle.genesisValueAndCap(quote);
        assertLe(value, 0.0092 ether, "Genesis value remains bounded by the discounted spin price");
    }

    function testAddLiquidityCallbackChecksCallerPoolAndFullRange() public {
        PoolKey memory k = hook.poolKey();
        ModifyLiquidityParams memory p = ModifyLiquidityParams(-887220, 887220, 1, bytes32(0));
        vm.expectRevert(GoldHook.OnlyPoolManager.selector);
        hook.beforeAddLiquidity(address(this), k, p, "");
        vm.prank(address(manager));
        assertEq(hook.beforeAddLiquidity(address(this), k, p, ""), hook.beforeAddLiquidity.selector);
        p.tickLower = -887160;
        vm.prank(address(manager));
        vm.expectRevert(GoldHook.FullRangeOnly.selector);
        hook.beforeAddLiquidity(address(this), k, p, "");
        p.tickLower = -887220;
        p.tickUpper = 887160;
        vm.prank(address(manager));
        vm.expectRevert(GoldHook.FullRangeOnly.selector);
        hook.beforeAddLiquidity(address(this), k, p, "");
        k.fee = 3000;
        vm.prank(address(manager));
        vm.expectRevert(GoldHook.WrongPool.selector);
        hook.beforeAddLiquidity(address(this), k, p, "");
    }
}

contract SameTransactionGenesisGateTest is Audit930Fixture {
    function setUp() public {
        _setup(0.5 ether);
    }

    function testTwoBuysCannotOpenThinGenesisGateInTheSameTransaction() public {
        _history();
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, HOOK_ADDRESS));
        oracle.genesisValueAndCap(1 ether);
        _swap(trader, true, -0.3 ether);
        _swap(trader, true, -0.3 ether);
        (uint160 price,) = hook.slot0();
        assertGt(oracle.genesisEthHeld(hook.liquidity(), price), 1 ether, "old spot formula passes");
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, HOOK_ADDRESS));
        oracle.genesisValueAndCap(1 ether);
        vm.expectRevert(abi.encodeWithSelector(TwapOracle.ThinPool.selector, HOOK_ADDRESS));
        oracle.tokensForEth(address(gold), 0.0092 ether);
        gold.mint(address(vault), vault.genesisSupply());
        (uint256 total,) = gacha.spinPrice();
        vm.expectRevert(BagGacha.NothingToDraw.selector);
        gacha.spin{value: total}();
    }
}

contract BindPreflightTest is Audit930Fixture {
    function setUp() public {
        _setup(100 ether);
    }

    function _name() internal {
        nft.setLaunchTargets(address(pol), address(gacha), address(gacha));
    }

    function _assertMismatch(address dependency, bytes4 selector) internal {
        vm.mockCall(dependency, abi.encodeWithSelector(selector), abi.encode(address(this)));
        assertEq(hook.bindCheck(address(gacha)), GoldHook.GachaMismatch.selector);
        vm.expectRevert(GoldHook.GachaMismatch.selector);
        hook.bindGacha(address(gacha));
        vm.clearMockedCalls();
        assertEq(hook.bindCheck(address(gacha)), bytes4(0));
    }

    function testBindCheckChecksEveryWireWithoutWaitingForReview() public {
        assertEq(hook.bindCheck(address(pol)), GoldHook.CodeMismatch.selector);
        assertEq(hook.bindCheck(address(gacha)), GoldHook.NotLaunchTarget.selector);
        _name();
        assertEq(hook.bindCheck(address(gacha)), bytes4(0));
        vm.expectRevert(GoldHook.ReviewPending.selector);
        hook.bindGacha(address(gacha));
        _assertMismatch(address(oracle), oracle.goldHook.selector);
        _assertMismatch(address(oracle), oracle.genesisToken.selector);
        _assertMismatch(address(pol), pol.oracle.selector);
        _assertMismatch(address(pol), pol.hook.selector);
        _assertMismatch(address(pol), pol.token.selector);
        _assertMismatch(address(vault), vault.oracle.selector);
        _assertMismatch(address(vault), vault.gacha.selector);
        _assertMismatch(address(vault), vault.token.selector);
        _assertMismatch(address(gacha), gacha.nft.selector);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        hook.bindGacha(address(gacha));
        assertEq(hook.bindCheck(address(gacha)), GoldHook.AlreadyBound.selector);
    }

    function testMalformedDependencyReturnsReasonAndDoesNotBind() public {
        _name();
        vm.mockCall(address(pol), abi.encodeWithSelector(pol.oracle.selector), hex"01");
        assertEq(hook.bindCheck(address(gacha)), GoldHook.GachaMismatch.selector);
        vm.expectRevert(GoldHook.GachaMismatch.selector);
        hook.bindGacha(address(gacha));
        vm.clearMockedCalls();
        vm.mockCallRevert(address(oracle), abi.encodeWithSelector(oracle.goldHook.selector), "bad oracle");
        assertEq(hook.bindCheck(address(gacha)), GoldHook.GachaMismatch.selector);
    }

    function testWrongCodeIsDetectedBeforeNamingOrReview() public {
        bytes memory runtime = address(gacha).code;
        runtime[0] = bytes1(uint8(runtime[0]) ^ 1);
        vm.etch(address(gacha), runtime);
        assertEq(hook.bindCheck(address(gacha)), GoldHook.CodeMismatch.selector);
        vm.expectRevert(GoldHook.CodeMismatch.selector);
        hook.bindGacha(address(gacha));
        assertFalse(nft.targetsSet());
    }

    function testPathAFundingAndPreflightBeforeOwnerNamesTargets() public {
        CheckLaunch check = new CheckLaunch();
        // The harness accepts either build profile; the production hook always uses its pinned launch hash.
        vm.mockCall(
            HOOK_ADDRESS,
            abi.encodeWithSelector(hook.GACHA_RUNTIME_CODE_HASH.selector),
            abi.encode(address(gacha).codehash)
        );
        vm.expectRevert(CheckLaunch.WrongFunding.selector);
        check.run(HOOK_ADDRESS, address(gacha));
        assertFalse(nft.targetsSet());
        gold.mint(address(this), vault.genesisSupply()); // simulate launch remainder in the paying wallet
        gold.transfer(address(vault), vault.genesisSupply());
        assertEq(gold.balanceOf(address(vault)), vault.genesisSupply());
        gold.mint(address(vault), 1);
        vm.expectRevert(CheckLaunch.WrongFunding.selector);
        check.run(HOOK_ADDRESS, address(gacha));
        vm.prank(address(vault));
        gold.transfer(address(this), 1);
        check.run(HOOK_ADDRESS, address(gacha));
        assertEq(hook.gacha(), address(gacha)); // the script's fork simulation includes the post-review bind
    }

    function testPreflightRejectsIncorrectRuntimeAndWiring() public {
        CheckLaunch check = new CheckLaunch();
        vm.expectRevert(CheckLaunch.WrongRuntimeCode.selector);
        check.run(HOOK_ADDRESS, address(pol));
        vm.mockCall(
            HOOK_ADDRESS,
            abi.encodeWithSelector(hook.GACHA_RUNTIME_CODE_HASH.selector),
            abi.encode(address(gacha).codehash)
        );
        gold.mint(address(vault), vault.genesisSupply());
        vm.mockCall(address(pol), abi.encodeWithSelector(pol.hook.selector), abi.encode(address(this)));
        vm.expectRevert(abi.encodeWithSelector(CheckLaunch.BindNotReady.selector, GoldHook.GachaMismatch.selector));
        check.run(HOOK_ADDRESS, address(gacha));
        assertFalse(nft.targetsSet(), "failed simulation rolls naming back");
    }

    function testPostBindRetargetRemainsAnNFTOwnerTrustAssumption() public {
        _name();
        vm.warp(vm.getBlockTimestamp() + 7 days);
        hook.bindGacha(address(gacha));
        // Deployed NFT code cannot be changed by this job: the owner can still retarget until release.
        nft.setLaunchTargets(address(pol), address(vault), address(vault));
        assertEq(nft.reserveTarget(), address(vault));
        assertEq(hook.gacha(), address(gacha), "hook binding remains fixed");
        assertEq(nft.targetsSetAt(), vm.getBlockTimestamp(), "another seven-day review begins");
    }

    function testAValidPreflightedSetStillBindsIfReleaseWinsTheRace() public {
        _name();
        assertEq(hook.bindCheck(address(gacha)), bytes4(0));
        for (uint256 i; i < 500; ++i) {
            address holder = address(uint160(0x10000 + i));
            vm.deal(holder, 0.02 ether);
            vm.prank(holder);
            nft.mint{value: 0.02 ether}(20);
        }
        vm.warp(vm.getBlockTimestamp() + 7 days);
        nft.release(); // anyone can release before the binding transaction lands
        assertTrue(nft.released());
        assertEq(hook.bindCheck(address(gacha)), bytes4(0));
        hook.bindGacha(address(gacha));
        assertEq(hook.gacha(), address(gacha));
    }
}
