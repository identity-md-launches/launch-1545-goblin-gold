// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "../src/TickMath.sol";

contract TickMathTest is Test {
    function testKnownValues() public pure {
        assertEq(TickMath.sqrtPriceAtTick(0), 2 ** 96);
        assertEq(TickMath.sqrtPriceAtTick(-887272), 4295128739);
        assertEq(TickMath.sqrtPriceAtTick(887272), 1461446703485210103287273052203988822378723970342);
    }

    function testOutOfRangeReverts() public {
        vm.expectRevert(TickMath.TickOutOfRange.selector);
        this.call(887273);
    }

    function call(int24 t) external pure returns (uint160) {
        return TickMath.sqrtPriceAtTick(t);
    }
}
