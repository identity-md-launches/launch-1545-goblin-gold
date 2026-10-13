// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Minimal, ABI-identical subset of Uniswap v4-core (`PoolKey`, `SwapParams`, `ModifyLiquidityParams`,
///      `IPoolManager`, `IUnlockCallback`). Currencies and hooks are plain addresses: the ABI encoding is the same
///      as the user-defined value types of v4-core. The tests compile against the vendored v4-core itself.

struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

struct ModifyLiquidityParams {
    int24 tickLower;
    int24 tickUpper;
    int256 liquidityDelta;
    bytes32 salt;
}

interface IPoolManagerMinimal {
    function unlock(bytes calldata data) external returns (bytes memory);
    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick);
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes calldata hookData)
        external
        returns (int256 callerDelta, int256 feesAccrued);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external
        returns (int256 swapDelta);
    function sync(address currency) external;
    function take(address currency, address to, uint256 amount) external;
    function settle() external payable returns (uint256 paid);
    function mint(address to, uint256 id, uint256 amount) external;
    function burn(address from, uint256 id, uint256 amount) external;
    function balanceOf(address owner, uint256 id) external view returns (uint256);
    function extsload(bytes32 slot) external view returns (bytes32);
}

interface IUnlockCallbackMinimal {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

library V4Lib {
    uint256 internal constant POOLS_SLOT = 6;
    uint256 internal constant LIQUIDITY_OFFSET = 3;
    uint160 internal constant MIN_SQRT_PRICE = 4295128739;
    uint160 internal constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;

    function poolId(PoolKey memory key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key));
    }

    function amount0(int256 delta) internal pure returns (int128 a) {
        assembly ("memory-safe") {
            a := sar(128, delta)
        }
    }

    function amount1(int256 delta) internal pure returns (int128 a) {
        assembly ("memory-safe") {
            a := signextend(15, delta)
        }
    }

    /// @dev (specified << 128) | unspecified, the v4 BeforeSwapDelta packing.
    function beforeSwapDelta(int128 specified, int128 unspecified) internal pure returns (int256 d) {
        assembly ("memory-safe") {
            d := or(shl(128, specified), and(sub(shl(128, 1), 1), unspecified))
        }
    }

    function slot0(IPoolManagerMinimal manager, bytes32 id) internal view returns (uint160 sqrtPriceX96, int24 tick) {
        bytes32 data = manager.extsload(keccak256(abi.encodePacked(id, POOLS_SLOT)));
        assembly ("memory-safe") {
            sqrtPriceX96 := and(data, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF)
            tick := signextend(2, shr(160, data))
        }
    }

    function liquidity(IPoolManagerMinimal manager, bytes32 id) internal view returns (uint128) {
        bytes32 base = keccak256(abi.encodePacked(id, POOLS_SLOT));
        return uint128(uint256(manager.extsload(bytes32(uint256(base) + LIQUIDITY_OFFSET))));
    }
}
