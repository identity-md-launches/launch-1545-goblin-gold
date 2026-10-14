// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {BagGacha} from "../src/BagGacha.sol";
import {GenesisVault} from "../src/GenesisVault.sol";
import {GoblinNFT} from "../src/GoblinNFT.sol";
import {TwapOracle} from "../src/TwapOracle.sol";
import {MockERC20, MockVRFWrapper, MockPOL, MockGoldHook} from "./mocks/Mocks.sol";
import {MockV3Factory, MockV3Pool} from "./mocks/CuratorMocks.sol";

/// @notice Measures maximum inventory using the actual pricing/selection code and 128 mock v3 pools.
/// Mock observe() is cheap; real observation-history traversal can cost more. This is not a fork benchmark.
contract GasBenchTest is Test {
    BagGacha gacha;
    MockVRFWrapper vrf;
    MockV3Pool[] pools;
    MockERC20 weth;
    MockV3Factory factory;
    TwapOracle oracle;
    MockERC20 gold;
    MockGoldHook goldHook;

    function setUp() public {
        vm.warp(100_000);
        vm.deal(address(this), 100 ether);
        weth = new MockERC20("WETH");
        MockERC20 platform = new MockERC20("PLATFORM");
        factory = new MockV3Factory();
        gold = new MockERC20("GOLD");
        goldHook = new MockGoldHook();
        oracle = new TwapOracle(address(this), address(weth), address(factory), address(gold), address(goldHook));
        GoblinNFT nft = new GoblinNFT(address(this));
        vrf = new MockVRFWrapper();
        MockPOL pol = new MockPOL();
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        GenesisVault genesis = new GenesisVault(
            address(platform), address(oracle), predicted, vm.getBlockTimestamp(), 1e24, 1e22, address(this)
        );
        gacha = new BagGacha(
            address(oracle),
            address(genesis),
            address(nft),
            address(vrf),
            address(pol),
            address(this),
            vm.getBlockTimestamp(),
            address(this)
        );
        gacha.fundReserve{value: 4 ether}();
        _seedBags();
        vm.warp(vm.getBlockTimestamp() + 3 days);
        for (uint256 i; i < pools.length; ++i) {
            pools[i].setObservation(uint32(vm.getBlockTimestamp()));
        }
    }

    function _seedBags() internal {
        for (uint256 i; i < gacha.MAX_ACTIVE(); ++i) {
            address[] memory tokens = new address[](4);
            uint256[] memory amounts = new uint256[](4);
            for (uint256 k; k < 4; ++k) {
                MockERC20 t = new MockERC20("BAG");
                MockV3Pool pool = new MockV3Pool(address(t), address(weth));
                pools.push(pool);
                factory.setPool(address(t), address(weth), 3000, address(pool));
                t.mint(address(pool), 100 ether);
                weth.mint(address(pool), 100 ether);
                oracle.setPool(address(t), address(pool));
                t.mint(address(this), 0.00125 ether);
                t.approve(address(gacha), 0.00125 ether);
                tokens[k] = address(t);
                amounts[k] = 0.00125 ether;
            }
            gacha.seal(tokens, amounts);
        }
    }

    function testMaximumInventorySnapshotGas() public {
        (uint256 price,) = gacha.spinPrice();
        uint256 beforeGas = gasleft();
        uint256 id = gacha.spin{value: price}();
        uint256 requestGas = beforeGas - gasleft();
        emit log_named_uint("32 Bags / 128 distinct pools request gas (mock observe)", requestGas);
        (uint256[] memory ids,,) = gacha.snapshot();
        assertEq(ids.length, gacha.MAX_ACTIVE());
        assertLt(requestGas, 12_000_000, "snapshot lost its transaction gas margin");
        vrf.fulfill(address(gacha), id, 75);
        beforeGas = gasleft();
        gacha.draw();
        emit log_named_uint("32 Bag draw gas", beforeGas - gasleft());
    }
}
