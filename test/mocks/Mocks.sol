// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory n) ERC20(n, n) {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

/// @dev Prices every token at a settable ETH-per-token (1e18 scale). The payout cap per token is settable too
///      (0 = unlimited), standing in for 5% of the token pool's ETH-side depth.
contract MockOracle {
    mapping(address => uint256) public price;
    mapping(address => bool) public broken;
    mapping(address => uint256) public cap;

    function set(address t, uint256 p) external {
        price[t] = p;
    }

    function setCap(address t, uint256 c) external {
        cap[t] = c;
    }

    function breakToken(address t, bool b) external {
        broken[t] = b;
    }

    function isPriced(address t) external view returns (bool) {
        return price[t] > 0;
    }

    function valueInEth(address t, uint256 a) external view returns (uint256) {
        require(!broken[t] && price[t] > 0, "unpriced");
        return (a * price[t]) / 1e18;
    }

    function valueAndCap(address t, uint256 a) external view returns (uint256, uint256) {
        require(!broken[t] && price[t] > 0, "unpriced");
        return ((a * price[t]) / 1e18, cap[t] == 0 ? type(uint256).max : cap[t]);
    }

    function tokensForEth(address t, uint256 e) external view returns (uint256) {
        require(!broken[t] && price[t] > 0, "unpriced");
        return (e * 1e18) / price[t];
    }

    /// @dev The genesis token of the fixture using this mock: set once so `genesisValueAndCap` can price it.
    address public genesisToken;

    function setGenesisToken(address t) external {
        genesisToken = t;
    }

    function genesisValueAndCap(uint256 a) external view returns (uint256, uint256) {
        address t = genesisToken;
        require(!broken[t] && price[t] > 0, "unpriced");
        return ((a * price[t]) / 1e18, cap[t] == 0 ? type(uint256).max : cap[t]);
    }
}

interface IConsumer {
    function rawFulfillRandomWords(uint256 requestId, uint256[] memory words) external;
}

contract MockVRFWrapper {
    uint256 public fee = 0.0005 ether;
    uint256 public lastId;
    uint256 public requests;

    function calculateRequestPriceNative(uint32, uint32) external view returns (uint256) {
        return fee;
    }

    function requestRandomWordsInNative(uint32, uint16, uint32, bytes calldata) external payable returns (uint256) {
        require(msg.value >= fee, "fee");
        requests++;
        lastId = uint256(keccak256(abi.encode(requests)));
        return lastId;
    }

    function fulfill(address consumer, uint256 id, uint256 word) external {
        uint256[] memory w = new uint256[](1);
        w[0] = word;
        IConsumer(consumer).rawFulfillRandomWords(id, w);
    }
}

contract MockPOL {
    uint256 public pol;
    uint256 public burn;

    function depositPOL() external payable {
        pol += msg.value;
    }

    function depositBurn() external payable {
        burn += msg.value;
    }
}

contract RejectingReceiver {
    receive() external payable {
        revert("no");
    }
}

/// @dev Settable stand-in for the GoldHook observation ring and v4 pool reads used by TwapOracle.
contract MockGoldHook {
    bool public initialized = true;
    uint160 public sqrtPriceX96 = 1 << 96;
    int24 public tick;
    uint128 public liquidity = 100 ether;
    uint32 public lastObservationTimestamp = uint32(block.timestamp);
    int24 public shortTick;
    int24 public longTick;
    bool public noHistory;

    /// @dev Liquidity recorded 30 minutes ago; `useRecorded` false means it tracks the current liquidity.
    uint128 public recordedLiquidity;
    bool public useRecorded;

    function setState(uint160 sqrtPrice, uint128 liq) external {
        sqrtPriceX96 = sqrtPrice;
        liquidity = liq;
    }

    function setRecordedLiquidity(uint128 liq, bool use) external {
        recordedLiquidity = liq;
        useRecorded = use;
    }

    function liquidityAt(uint32) external view returns (uint128) {
        return useRecorded ? recordedLiquidity : liquidity;
    }

    function setInitialized(bool v) external {
        initialized = v;
    }

    function setTicks(int24 s, int24 l) external {
        shortTick = s;
        longTick = l;
    }

    function touch() external {
        lastObservationTimestamp = uint32(block.timestamp);
    }

    function setNoHistory(bool v) external {
        noHistory = v;
    }

    function slot0() external view returns (uint160, int24) {
        return (sqrtPriceX96, tick);
    }

    function observe(uint32[] calldata secondsAgos) external view returns (int56[] memory c) {
        require(!noHistory, "OLD");
        c = new int56[](secondsAgos.length);
        // cumulative at now is 0; the mean tick over each window is the configured tick
        c[0] = -int56(shortTick) * int56(uint56(secondsAgos[0]));
        c[1] = -int56(longTick) * int56(uint56(secondsAgos[1]));
    }
}
