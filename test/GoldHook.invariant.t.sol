// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {V4Fixture} from "./mocks/V4Fixture.sol";
import {GoldHook} from "../src/GoldHook.sol";
import {BagGacha} from "../src/BagGacha.sol";
import {GenesisVault} from "../src/GenesisVault.sol";
import {MockOracle, MockVRFWrapper, MockPOL} from "./mocks/Mocks.sol";

/// @dev Random buys, sells, time and flushes against the real PoolManager; an independent ledger of every charge.
contract HookHandler is V4Fixture {
    BagGacha public gacha;
    uint256 public charged;
    uint256 public flushedHolders;
    uint256 public flushedReserve;
    bool public bound_;

    constructor() {
        _deployV4(keccak256(type(BagGacha).runtimeCode));
        _initialize();
        _seed(200 ether, 200 ether, 200e18);
        MockOracle o = new MockOracle();
        MockVRFWrapper vrf = new MockVRFWrapper();
        MockPOL p = new MockPOL();
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        GenesisVault genesis =
            new GenesisVault(address(gold), address(o), predicted, vm.getBlockTimestamp(), 1e24, 1e22, address(this));
        gacha = new BagGacha(
            address(o), address(genesis), NFT_ADDRESS, address(vrf), address(p), address(this), 1, address(this)
        );
    }

    function buy(uint256 amount, bool exactOut) external {
        uint256 before = hook.holderAccrued() + hook.reserveAccrued();
        if (exactOut) {
            amount = bound(amount, 1e9, 0.001 ether);
            try swapRouter.swap{value: 1 ether}(key, _coreSwap(true, int256(amount)), _settings(), "") {} catch {}
        } else {
            amount = bound(amount, 1e9, 0.5 ether);
            swapRouter.swap{value: amount}(key, _coreSwap(true, -int256(amount)), _settings(), "");
        }
        charged += hook.holderAccrued() + hook.reserveAccrued() - before;
    }

    function sell(uint256 amount, bool exactOut) external {
        uint256 before = hook.holderAccrued() + hook.reserveAccrued();
        gold.mint(address(this), 10 ether);
        gold.approve(address(swapRouter), type(uint256).max);
        if (exactOut) {
            amount = bound(amount, 1e9, 0.5 ether);
            swapRouter.swap(key, _coreSwap(false, int256(amount)), _settings(), "");
        } else {
            amount = bound(amount, 1e9, 5 ether);
            swapRouter.swap(key, _coreSwap(false, -int256(amount)), _settings(), "");
        }
        charged += hook.holderAccrued() + hook.reserveAccrued() - before;
    }

    function advance(uint256 seconds_) external {
        vm.warp(vm.getBlockTimestamp() + bound(seconds_, 1, 20 minutes));
    }

    function bind() external {
        if (bound_) return;
        bound_ = true;
        hook.bindGacha(address(gacha));
    }

    function flush() external {
        uint256 h = hook.holderAccrued();
        uint256 r = bound_ ? hook.reserveAccrued() : 0;
        if (h + r == 0) return;
        hook.flush();
        flushedHolders += h;
        flushedReserve += r;
    }
}

/// forge-config: default.invariant.runs = 24
/// forge-config: default.invariant.depth = 40
/// forge-config: default.invariant.fail-on-revert = true
contract GoldHookInvariantTest is V4Fixture {
    HookHandler handler;

    function setUp() public {
        handler = new HookHandler();
        hook = handler.hook();
        manager = handler.manager();
        nft = handler.nft();
        bytes4[] memory methods = new bytes4[](5);
        methods[0] = handler.buy.selector;
        methods[1] = handler.sell.selector;
        methods[2] = handler.advance.selector;
        methods[3] = handler.bind.selector;
        methods[4] = handler.flush.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), methods));
    }

    function invariant_chargesEqualClaimsPlusFlushesAndNothingSticksInTheHook() public view {
        assertEq(manager.balanceOf(address(hook), 0), hook.holderAccrued() + hook.reserveAccrued());
        assertEq(
            hook.holderAccrued() + hook.reserveAccrued() + handler.flushedHolders() + handler.flushedReserve(),
            handler.charged()
        );
        assertEq(hook.totalFlushedToHolders(), handler.flushedHolders());
        assertEq(hook.totalFlushedToReserve(), handler.flushedReserve());
        assertEq(nft.deferredRevenue(), handler.flushedHolders());
        assertEq(handler.gacha().reserve(), handler.flushedReserve());
        assertEq(address(hook).balance, 0);
        if (!handler.bound_()) assertEq(hook.gacha(), address(0));
    }
}
