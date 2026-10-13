// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BagGacha} from "../../src/BagGacha.sol";

contract TaxToken is ERC20 {
    constructor() ERC20("TAX", "TAX") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = amount / 100;
            super._update(from, address(0), fee);
            amount -= fee;
        }
        super._update(from, to, amount);
    }
}

contract CreditReceiver {
    BagGacha public gacha;
    bool public reject;
    bool public reentered;

    constructor(BagGacha g) {
        gacha = g;
    }

    function setReject(bool value) external {
        reject = value;
    }

    receive() external payable {
        require(!reject, "rejected");
        try gacha.withdrawCredit() {
            reentered = true;
        } catch {}
    }
}
