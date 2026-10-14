// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev ABI-identical subset of Uniswap v4-core's Hooks library. Field order is checked against the
///      vendored core in test/GoldHook.t.sol. Kept here so production imports never depend on test code.
library Hooks {
    struct Permissions {
        bool beforeInitialize;
        bool afterInitialize;
        bool beforeAddLiquidity;
        bool afterAddLiquidity;
        bool beforeRemoveLiquidity;
        bool afterRemoveLiquidity;
        bool beforeSwap;
        bool afterSwap;
        bool beforeDonate;
        bool afterDonate;
        bool beforeSwapReturnDelta;
        bool afterSwapReturnDelta;
        bool afterAddLiquidityReturnDelta;
        bool afterRemoveLiquidityReturnDelta;
    }
}
