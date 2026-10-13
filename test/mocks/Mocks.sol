// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory n) ERC20(n, n) {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }
}

/// @dev Prices every token at a settable ETH-per-token (1e18 scale).
contract MockOracle {
    mapping(address => uint256) public price;
    mapping(address => bool) public broken;

    function set(address t, uint256 p) external {
        price[t] = p;
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

    function tokensForEth(address t, uint256 e) external view returns (uint256) {
        require(!broken[t] && price[t] > 0, "unpriced");
        return (e * 1e18) / price[t];
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
