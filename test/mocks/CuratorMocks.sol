// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Curator, ICuratorIntake} from "../../src/Curator.sol";
import {OracleAttestation} from "../../src/OracleAttestation.sol";

/// @dev Test-only signer injection. The production Curator has no signer setter. The intake and payment token are
///      compiled-in constants, so tests etch their mocks at `IMDProtocol.INTAKE_V2` / `IMDProtocol.IMD`.
contract CuratorHarness is Curator {
    constructor(address o, address g, address b, address signer) Curator(o, g, b) {
        _setOracleSigner(signer);
    }

    function verifyVector(OracleAttestation.Attestation calldata a, bytes calldata sig) external {
        _verifyAttestation(a, sig);
        _consume(a.requestId);
    }
}

contract MockIntake is ICuratorIntake {
    uint256 public price = 0.5 ether;
    uint256 public nonce;
    bytes public lastBody;
    bytes4 public failureSelector;
    mapping(bytes32 => Callback) public callbacks;
    bytes32 public lastId;
    bool public reenter;
    bool public reentered;
    bytes public reentryCall;

    function setPrice(uint256 value) external {
        price = value;
    }

    function priceOf(bytes32, address) external view returns (uint256) {
        return price;
    }

    function armReentry(bytes calldata data) external {
        reenter = true;
        reentryCall = data;
    }

    function requestWithFailure(
        bytes32 action,
        bytes calldata body,
        Callback calldata callback,
        bytes4 onFailure,
        address asset,
        uint256 amount
    ) external payable returns (bytes32 id) {
        require(action == bytes32("oracle.request@oracle-1"));
        require(amount == price && msg.value == 0);
        require(IERC20(asset).transferFrom(msg.sender, address(this), amount));
        lastBody = body;
        failureSelector = onFailure;
        id = keccak256(abi.encode(address(this), ++nonce));
        callbacks[id] = callback;
        lastId = id;
        if (reenter) (reentered,) = msg.sender.call(reentryCall);
    }

    function deliver(bytes32 id, OracleAttestation.Attestation calldata a, bytes calldata sig) external {
        Callback memory c = callbacks[id];
        (bool ok, bytes memory err) = c.target.call{gas: 200_000}(abi.encodeWithSelector(c.selector, id, a, sig));
        if (!ok) {
            assembly ("memory-safe") { revert(add(err, 32), mload(err)) }
        }
    }

    function fail(bytes32 id, uint8 status) external {
        Curator(callbacks[id].target).onOracleFailure(id, status, bytes32("disagreed"), 1, 2, "");
    }
}

contract MockV3Factory {
    mapping(bytes32 => address) private pools;

    function setPool(address a, address b, uint24 fee, address pool) external {
        pools[keccak256(abi.encode(a < b ? a : b, a < b ? b : a, fee))] = pool;
    }

    function getPool(address a, address b, uint24 fee) external view returns (address) {
        return pools[keccak256(abi.encode(a < b ? a : b, a < b ? b : a, fee))];
    }
}

contract MockV3Pool {
    address public token0;
    address public token1;
    uint24 public constant fee = 3000;
    uint128 public liquidity = 100 ether;
    uint128 public historyLiquidity = 100 ether;
    int24 public tickSpacing = 60;
    mapping(int16 => uint256) public tickBitmap;
    mapping(int24 => int128) public liquidityNetOf;
    int24 public spotTick;
    uint160 public shortLiquidityDelta;
    bool public useLiquidityDelta;

    function setLiquidityDelta(uint160 delta, bool use) external {
        shortLiquidityDelta = delta;
        useLiquidityDelta = use;
    }

    function setHistoryLiquidity(uint128 value) external {
        historyLiquidity = value;
    }

    function setSpot(uint160 price, int24 tick) external {
        sqrtPriceX96 = price;
        spotTick = tick;
    }

    function setTickSpacing(int24 value) external {
        tickSpacing = value;
    }

    function setInitializedTick(int24 tick, bool initialized) external {
        require(tick % tickSpacing == 0);
        int24 compressed = tick / tickSpacing;
        int16 word = int16(compressed >> 8);
        uint256 mask = uint256(1) << uint8(uint24(compressed));
        if (initialized) tickBitmap[word] |= mask;
        else tickBitmap[word] &= ~mask;
    }

    function setLiquidityNet(int24 tick, int128 net) external {
        liquidityNetOf[tick] = net;
    }

    function ticks(int24 tick) external view returns (uint128, int128) {
        int128 net = liquidityNetOf[tick];
        uint128 gross = uint128(uint256(net < 0 ? -int256(net) : int256(net)));
        int24 compressed = tick / tickSpacing;
        if (
            gross == 0 && tick % tickSpacing == 0
                && tickBitmap[int16(compressed >> 8)] & (uint256(1) << uint8(uint24(compressed))) != 0
        ) gross = 1; // overlapping positions may initialize a tick with zero net liquidity
        return (gross, net);
    }

    function setLiquidity(uint128 value) external {
        liquidity = value;
    }
    uint32 public lastObservation;
    int24 public shortTick;
    int24 public longTick;
    uint160 public sqrtPriceX96 = uint160(1 << 96);
    bool public noHistory;

    constructor(address a, address b) {
        token0 = a < b ? a : b;
        token1 = a < b ? b : a;
        lastObservation = uint32(block.timestamp);
    }

    function setObservation(uint32 time) external {
        lastObservation = time;
    }

    function setTicks(int24 a, int24 b) external {
        shortTick = a;
        longTick = b;
    }

    function setNoHistory(bool value) external {
        noHistory = value;
    }

    function observations(uint256) external view returns (uint32) {
        return lastObservation;
    }

    function slot0() external view returns (uint160, int24, uint16) {
        return (sqrtPriceX96, spotTick, 0);
    }

    function observe(uint32[] calldata agos) external view returns (int56[] memory values, uint160[] memory spl) {
        require(!noHistory, "OLD");
        values = new int56[](agos.length);
        spl = new uint160[](agos.length);
        for (uint256 i; i < agos.length; ++i) {
            int24 tick = agos[i] == 1800 ? shortTick : longTick;
            values[i] = -int56(tick) * int56(uint56(agos[i]));
            // Model a constant historical liquidity, independent of same-transaction changes to spot liquidity.
            spl[i] = uint160(
                (uint256(uint32(block.timestamp) - agos[i]) << 128) / (historyLiquidity == 0 ? 1 : historyLiquidity)
            );
            if (useLiquidityDelta) {
                // End counter is zero, so this also exercises uint160 wrapping as in the real v3 accumulator.
                unchecked {
                    spl[i] = agos[i] == 0 ? 0 : uint160(0) - shortLiquidityDelta;
                }
            }
        }
    }
}
