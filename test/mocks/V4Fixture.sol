// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "../v4-core/PoolManager.sol";
import {IPoolManager} from "../v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "../v4-core/interfaces/IHooks.sol";
import {Currency} from "../v4-core/types/Currency.sol";
import {PoolKey as CoreKey} from "../v4-core/types/PoolKey.sol";
import {SwapParams as CoreSwap, ModifyLiquidityParams as CoreModify} from "../v4-core/types/PoolOperation.sol";
import {BalanceDelta} from "../v4-core/types/BalanceDelta.sol";
import {PoolSwapTest} from "../v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "../v4-core/test/PoolModifyLiquidityTest.sol";
import {GoldHook} from "../../src/GoldHook.sol";
import {GoblinNFT} from "../../src/GoblinNFT.sol";
import {MockERC20} from "./Mocks.sol";

/// @dev GoldHook whose pinned gacha hash can be chosen at deployment, so bind tests run under any compiler profile.
contract GoldHookHarness is GoldHook {
    bytes32 private immutable _hash;

    constructor(address pm, address token_, address factory_, bytes32 hash_) GoldHook(pm, token_, factory_) {
        _hash = hash_;
    }

    function gachaRuntimeCodeHash() public view override returns (bytes32) {
        return _hash;
    }
}

/// @dev Deploys the real v4 PoolManager, a GOLD token, GoldHook at a flagged address and the deployed GoblinNFT code
///      at its mainnet address, then initializes the platform pool as the launch factory would.
abstract contract V4Fixture is Test {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    address constant HOOK_ADDRESS = address((uint160(0x4A) << 152) | 0x30CC);
    address constant NFT_ADDRESS = 0xC5d5F314da6d4a433F9BF897a2cC24A537576cB1;
    address factoryEOA = address(0xFAC7);
    address trader = address(0x7A4D);

    PoolManager public manager;
    MockERC20 public gold;
    GoldHook public hook;
    GoblinNFT public nft;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;
    CoreKey key;

    receive() external payable {}

    function _deployV4(bytes32 gachaHash) internal {
        vm.warp(1_800_000_000);
        manager = new PoolManager(address(this));
        gold = new MockERC20("GOLD");
        GoldHookHarness impl = new GoldHookHarness(address(manager), address(gold), factoryEOA, gachaHash);
        vm.etch(HOOK_ADDRESS, address(impl).code);
        hook = GoldHook(payable(HOOK_ADDRESS));
        assertTrue(hook.hasRequiredFlags());
        GoblinNFT nftImpl = new GoblinNFT(address(this));
        vm.etch(NFT_ADDRESS, address(nftImpl).code);
        nft = GoblinNFT(NFT_ADDRESS);
        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));
        key = CoreKey(Currency.wrap(address(0)), Currency.wrap(address(gold)), 12500, 60, IHooks(HOOK_ADDRESS));
        vm.deal(trader, 1000 ether);
        vm.deal(address(this), 10_000 ether);
    }

    function _initialize() internal {
        vm.prank(factoryEOA);
        manager.initialize(key, SQRT_PRICE_1_1);
    }

    /// @dev Full-range liquidity from this contract, as the launch's pool seeding would.
    function _seed(uint256 eth, uint256 tokens, int256 liquidity) internal {
        gold.mint(address(this), tokens);
        gold.approve(address(lpRouter), tokens);
        lpRouter.modifyLiquidity{value: eth}(key, CoreModify(-887220, 887220, liquidity, bytes32(0)), "");
    }

    function _coreSwap(bool zeroForOne, int256 amountSpecified) internal pure returns (CoreSwap memory) {
        uint160 limit = zeroForOne ? 4295128739 + 1 : 1461446703485210103287273052203988822378723970342 - 1;
        return CoreSwap(zeroForOne, amountSpecified, limit);
    }

    function _settings() internal pure returns (PoolSwapTest.TestSettings memory) {
        return PoolSwapTest.TestSettings(false, false);
    }

    function _swap(address who, bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        uint160 limit = zeroForOne ? 4295128739 + 1 : 1461446703485210103287273052203988822378723970342 - 1;
        PoolSwapTest.TestSettings memory settings = PoolSwapTest.TestSettings(false, false);
        uint256 value;
        if (zeroForOne) {
            // give the router enough native currency to settle fee and tax on top of the specified amount
            value = amountSpecified < 0 ? uint256(-amountSpecified) : 20 ether;
        } else {
            gold.mint(who, 1_000_000 ether);
            vm.prank(who);
            gold.approve(address(swapRouter), type(uint256).max);
        }
        vm.prank(who);
        return swapRouter.swap{value: value}(key, CoreSwap(zeroForOne, amountSpecified, limit), settings, "");
    }
}
