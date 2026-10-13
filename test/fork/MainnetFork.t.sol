// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {TwapOracle, IUniswapV3Factory} from "../../src/TwapOracle.sol";
import {IVRFV2PlusWrapper} from "../../src/BagGacha.sol";
import {MockERC20, MockGoldHook} from "../mocks/Mocks.sol";

interface IRealWrapper is IVRFV2PlusWrapper {
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata words) external;
    function typeAndVersion() external view returns (string memory);
}

interface IMainnetToken {
    function symbol() external view returns (string memory);
}

contract ForkVRFConsumer {
    IVRFV2PlusWrapper public immutable wrapper;
    uint256 public requestId;
    uint256 public word;
    bool public fulfilled;

    constructor(address wrapper_) {
        wrapper = IVRFV2PlusWrapper(wrapper_);
    }

    function request() external payable {
        requestId = wrapper.requestRandomWordsInNative{value: msg.value}(
            100_000, 3, 1, abi.encodeWithSelector(bytes4(keccak256("VRF ExtraArgsV1")), true)
        );
    }

    function rawFulfillRandomWords(uint256 id, uint256[] calldata words) external {
        require(msg.sender == address(wrapper) && id == requestId && !fulfilled, "bad callback");
        word = words[0];
        fulfilled = true;
    }
}

/// @notice Offline-safe: no RPC or environment reads in tests. Opt in with forge test --fork-url URL
/// --match-path test/fork/MainnetFork.t.sol. These are documentation-sourced mainnet addresses, checked
/// for code and identity when a fork is supplied; no transaction is ever broadcast.
contract MainnetForkTest is Test {
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address constant WRAPPER = 0x02aae1A04f9828517b3007f83f6181900CaD910c;
    address constant COORDINATOR = 0xD7f86b4b8Cae7D942340FF628F82735b7a20893a;

    function setUp() public {
        if (block.chainid != 1) vm.skip(true);
        assertGt(WETH.code.length, 0, "WETH absent on fork");
        assertGt(FACTORY.code.length, 0, "factory absent on fork");
        assertGt(WRAPPER.code.length, 0, "wrapper absent on fork");
    }

    function testRealV3PoolHistoryLiquidityAndUSDCDecimals() public {
        assertEq(IMainnetToken(WETH).symbol(), "WETH");
        assertEq(IMainnetToken(USDC).symbol(), "USDC");
        address pool = IUniswapV3Factory(FACTORY).getPool(USDC, WETH, 500);
        assertGt(pool.code.length, 0);
        TwapOracle oracle =
            new TwapOracle(address(this), WETH, FACTORY, address(new MockERC20("GOLD")), address(new MockGoldHook()));
        oracle.setPool(USDC, pool);
        uint256 value = oracle.valueInEth(USDC, 1_000e6);
        assertGt(value, 0);
        assertLt(value, 100 ether);
        uint256 roundtrip = oracle.tokensForEth(USDC, value);
        assertApproxEqAbs(roundtrip, 1_000e6, 2, "USDC decimal-aware conservative quote roundtrip");
    }

    function testRealWrapperNativeRequestAndLocalCoordinatorCallback() public {
        vm.txGasPrice(10 gwei);
        assertGt(bytes(IRealWrapper(WRAPPER).typeAndVersion()).length, 0);
        uint256 fee = IVRFV2PlusWrapper(WRAPPER).calculateRequestPriceNative(100_000, 1);
        assertGt(fee, 0);
        ForkVRFConsumer consumer = new ForkVRFConsumer(WRAPPER);
        consumer.request{value: fee}();
        assertGt(consumer.requestId(), 0);
        assertFalse(consumer.fulfilled());
        uint256[] memory words = new uint256[](1);
        words[0] = 0xBEEF;
        // Local fork impersonation exercises wrapper routing only, not VRF proof verification.
        uint256 id = consumer.requestId();
        vm.prank(COORDINATOR);
        IRealWrapper(WRAPPER).rawFulfillRandomWords(id, words);
        assertTrue(consumer.fulfilled());
        assertEq(consumer.word(), words[0]);
    }
}
