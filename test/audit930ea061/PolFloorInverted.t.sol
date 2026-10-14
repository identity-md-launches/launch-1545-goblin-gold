// Adapted from audit 930ea061, published 2026-10-14. See README.md for provenance.
// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolManager} from "test/v4-core/PoolManager.sol";
import {IPoolManager} from "test/v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "test/v4-core/interfaces/IHooks.sol";
import {Currency} from "test/v4-core/types/Currency.sol";
import {PoolKey as CoreKey} from "test/v4-core/types/PoolKey.sol";
import {SwapParams as CoreSwap, ModifyLiquidityParams as CoreModify} from "test/v4-core/types/PoolOperation.sol";
import {PoolSwapTest} from "test/v4-core/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "test/v4-core/test/PoolModifyLiquidityTest.sol";
import {GoldHook} from "src/GoldHook.sol";
import {TwapOracle} from "src/TwapOracle.sol";
import {POLManager} from "src/POLManager.sol";
import {TickMath} from "src/TickMath.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract ScratchGold is ERC20 {
    constructor() ERC20("GOLD", "GOLD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract ScratchV3Factory {
    function getPool(address, address, uint24) external pure returns (address) {
        return address(0);
    }
}

/// @notice v3.2 finding 5 changed `TwapOracle.tokensForEth(GOLD)` from the larger token amount of the two windows to
///         the smaller one, for the GenesisVault quote. POLManager uses the same function as its slippage floor
///         (`minOut = tokensForEth(GOLD, ethIn) * 9475 / 10000`), where the protective direction is the opposite:
///         the floor must follow the window that gives MORE tokens, otherwise a 30-minute pump of the GOLD price
///         lowers the floor and the permissionless `buyAndBurn` / `addLiquidity` buy GOLD at the pumped price.
///         This test fails on v3.2 (the buy goes through at ~60% of the 4-hour TWAP token amount) and passes once
///         POLManager's floor again follows the larger of the two window quotes.
contract PolFloorInvertedTest is Test {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    address constant HOOK_ADDRESS = address((uint160(0x4A) << 152) | 0x38CC);
    address factoryEOA = address(0xFAC7);
    address trader = address(0x7A4D);

    PoolManager manager;
    ScratchGold gold;
    GoldHook hook;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;
    CoreKey key;
    TwapOracle oracle;
    POLManager pol;

    receive() external payable {}

    function setUp() public {
        vm.warp(1_800_000_000);
        manager = new PoolManager(address(this));
        gold = new ScratchGold();
        GoldHook impl = new GoldHook(address(manager), address(gold), factoryEOA);
        vm.etch(HOOK_ADDRESS, address(impl).code);
        hook = GoldHook(payable(HOOK_ADDRESS));
        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));
        key = CoreKey(Currency.wrap(address(0)), Currency.wrap(address(gold)), 12500, 60, IHooks(HOOK_ADDRESS));
        vm.deal(trader, 1000 ether);
        vm.deal(address(this), 10_000 ether);
        vm.prank(factoryEOA);
        manager.initialize(key, SQRT_PRICE_1_1);
        // seed 100 ETH / 100 GOLD full range (L = 100e18), as the launch would
        gold.mint(address(this), 100 ether);
        gold.approve(address(lpRouter), 100 ether);
        lpRouter.modifyLiquidity{value: 100 ether}(key, CoreModify(-887220, 887220, 100e18, bytes32(0)), "");

        oracle = new TwapOracle(
            address(this), address(0xBEEF), address(new ScratchV3Factory()), address(gold), HOOK_ADDRESS
        );
        pol = new POLManager(address(manager), address(gold), HOOK_ADDRESS, address(oracle), address(0xEEEE));
    }

    function _swap(bool zeroForOne, int256 amountSpecified) internal {
        uint160 limit = zeroForOne ? 4295128739 + 1 : 1461446703485210103287273052203988822378723970342 - 1;
        uint256 value;
        if (zeroForOne) {
            value = uint256(-amountSpecified);
        } else {
            gold.mint(trader, 1_000_000 ether);
            vm.prank(trader);
            gold.approve(address(swapRouter), type(uint256).max);
        }
        vm.prank(trader);
        swapRouter.swap{value: value}(
            key, CoreSwap(zeroForOne, amountSpecified, limit), PoolSwapTest.TestSettings(false, false), ""
        );
    }

    function _tokensAtTick(int24 tick, uint256 ethAmount) internal pure returns (uint256) {
        uint160 sqrtRatio = TickMath.sqrtPriceAtTick(tick);
        return Math.mulDiv(uint256(sqrtRatio) * sqrtRatio, ethAmount, 1 << 192);
    }

    function _meanTicks() internal view returns (int24 shortTick, int24 longTick) {
        uint32[] memory agos = new uint32[](3);
        agos[0] = 30 minutes;
        agos[1] = 4 hours;
        int56[] memory c = hook.observe(agos);
        shortTick = int24((c[2] - c[0]) / int56(uint56(30 minutes)));
        longTick = int24((c[2] - c[1]) / int56(uint56(4 hours)));
        if (c[2] - c[0] < 0 && (c[2] - c[0]) % int56(uint56(30 minutes)) != 0) shortTick--;
        if (c[2] - c[1] < 0 && (c[2] - c[1]) % int56(uint56(4 hours)) != 0) longTick--;
    }

    function testThirtyMinutePumpLowersThePolFloorAndTheBurnBuysAtThePumpedPrice() public {
        // GOLD priceable: a swap past the tax window records the seeded liquidity, 4 hours of ring history
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        _swap(true, -0.001 ether);
        vm.warp(vm.getBlockTimestamp() + 4 hours);
        _swap(false, -0.001 ether);
        uint256 fair = oracle.tokensForEth(address(gold), 0.1 ether);
        assertApproxEqRel(fair, 0.1 ether, 0.01e18, "1:1 pool: 0.1 GOLD per 0.1 ETH");

        // attacker pumps GOLD: 30 ETH into a 100 ETH-deep pool, held for 31 minutes
        _swap(true, -30 ether);
        vm.warp(vm.getBlockTimestamp() + 31 minutes);
        (int24 s, int24 l) = _meanTicks();
        uint256 shortQuote = _tokensAtTick(s, 0.1 ether);
        uint256 longQuote = _tokensAtTick(l, 0.1 ether);
        assertLt(shortQuote, (longQuote * 70) / 100, "the 30-minute window is at the pumped price");
        assertGt(longQuote, (fair * 90) / 100, "the 4-hour window barely moved");

        // v3.3: the POL floor follows the protective window; the Genesis quote still follows the smaller amount.
        uint256 floorNow = (oracle.polTokensForEth(0.1 ether) * pol.MIN_OUT_BPS()) / 10_000;
        uint256 floorProtective = (longQuote * pol.MIN_OUT_BPS()) / 10_000;
        assertEq(floorNow, floorProtective);
        assertEq(oracle.tokensForEth(address(gold), 0.1 ether), shortQuote);
        emit log_named_uint("floor used by POLManager (GOLD per 0.1 ETH)", floorNow);
        emit log_named_uint("floor at the 4-hour TWAP               ", floorProtective);

        // a permissionless burn of POL money must NOT clear at the pumped price: the pool pays far less than the
        // 4-hour quote minus the 5.25% allowance, which is what MIN_OUT_BPS is documented to guarantee
        pol.depositBurn{value: 1 ether}();
        vm.expectRevert(POLManager.Slippage.selector);
        pol.buyAndBurn(0.1 ether);
        pol.depositPOL{value: 1 ether}();
        vm.expectRevert(POLManager.Slippage.selector);
        pol.addLiquidity(0.2 ether);
    }
}
