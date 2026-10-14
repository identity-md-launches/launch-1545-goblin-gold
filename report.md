# Goblin Gold v3.2 — work report

Source-only assignment: fix every critical, high and medium finding of audit 85083c05 plus two lows. Nothing was
deployed or broadcast; `foundry.toml`, `remappings.txt`, `lib/` and `src/GoblinNFT.sol` are untouched.

## What changed

| Finding | Files | Change |
|---|---|---|
| 1 Critical, look-alike gacha | `src/GoldHook.sol` | `bindGacha` requires `GoblinNFT.targetsSet()`, `reserveTarget() == vrfTarget() == gacha`, `polTarget() == gacha.polManager()` (`NotLaunchTarget`), `block.timestamp >= targetsSetAt + 7 days` (`ReviewPending`), then the existing code-hash check plus `gacha.nft()`, `genesis().token()`, `genesis().gacha() == gacha`, `genesis().oracle() == gacha.oracle()` (`GachaMismatch`). `TARGET_REVIEW_PERIOD = 7 days` mirrors the deployed NFT |
| 2 High, POL fee brick | `src/POLManager.sol` | `_addFullRange` takes a positive `amount0`/`amount1` (accrued LP fees netted into the caller delta) so both deltas are always zero at the end of the callback; the ETH is credited to `polBudget` in `addLiquidity`, the GOLD stays for the next add; `FeesCollected` event |
| 3 High, partial-fill charge | `src/GoldHook.sol` | `afterSwap` reverts `PartialFill(realised, expected)` when ETH is specified and the pool's realised ETH leg differs from the ETH handed to it (buy `amount − fee − tax`, exact-output sell `amount + fee`). POLManager's swaps already used the extreme limit; documented |
| 4 High, JIT depth | `src/GoldHook.sol`, `src/TwapOracle.sol` | `Observation.liquidity` recorded in `beforeSwap`; `liquidityAt(secondsAgo)`; the oracle uses `min(current L, liquidityAt(30 min))` and `genesisEthHeld(L, √P)` (ETH held up to tick 887220, ≤ the virtual reserve) for the 1 ETH bound and the 5% cap |
| 5 Medium, one-window push | `src/TwapOracle.sol`, `src/BagGacha.sol` | `tokensForEth(GOLD)` = `Math.min` of the two token amounts; new `genesisValueAndCap(tokens)` values at the 4-hour TWAP; `_commitGenesis` caps with it |
| 6 Medium, `MIN_OUT_BPS` | `src/POLManager.sol` | `10_000 − 125 − 100 − 300 = 9475` |
| 7 Low, exact-output fee base | `src/GoldHook.sol` | `gross = ethIn · BPS / (BPS − 100 − taxBps)`, `fee = gross / 100`, `tax = gross − fee − ethIn`; the buy cap checks the gross |
| 8 Low, VRF lock | `src/BagGacha.sol` | `cancelRequest()` after `CANCEL_DELAY = 24 h` without fulfilment: refunds `req.paid` as credit, releases the liability, uncommits Genesis tokens, clears the stored VRF id (late word ignored); `AlreadyFulfilled` / `CancelNotDue` / `NoDrawPending`; `SpinCancelled` event |
| Re-pin | `src/GoldHook.sol` | `GACHA_RUNTIME_CODE_HASH = 0x2db1143638494d63cd5b4b807bd3dfe333d590ea58e7204ab7fd0c5cf415c4cd` from the final v3.2 `BagGacha` under the launch profile (`testPinnedGachaRuntimeCodeHash` passes there) |
| Tests | `test/Audit85083c05.t.sol` (new, 10 tests on the real vendored PoolManager + the BagGacha fixture: `testBindGachaLookalike`, `testPolFeeBrick`, `testPartialFillFee`, `testJitPayoutCap`, `testGenesisDepthIsBoundedByTheEthTheLiquidityHolds`, `testShortWindowPushNoLongerInflatesGenesisBags`, `testMinOutBpsMatchesTheFeeSchedule`, `testMinOutFloorBehaviour`, `testUnfulfilledRequestCanBeCancelledAfterADay`, `testCancelledFreeSpinRefundsNothingButReleasesTheGenesisTokens`); `GoldHook.t.sol` bind/exact-output/depth tests updated to the new rules; `TwapOracle.t.sol` recorded-liquidity and held-ETH boundaries; mocks gained `liquidityAt`/`setRecordedLiquidity` and `genesisValueAndCap`; the gacha invariant handler gained a `cancel` action; `V4Fixture` makes the test contract the etched NFT's owner and names launch targets; the v4 fork test quotes the live pool price, exercises the fee-delta add and the JIT cap |
| Docs | `README.md`: v3.2 table, accepted low 9 / info 10, hook/oracle/POL/lifecycle sections, runbook reordered (launch 1 → launch 2 → `setLaunchTargets` → review → `bindGacha` → `release`), both launch objectives, after-launch steps, responsibilities, assumptions |

## Checks run (2026-10-14)

| Check | Result |
|---|---|
| `FOUNDRY_VIA_IR=false FOUNDRY_BYTECODE_HASH=none forge build` / `forge test` with `FOUNDRY_FUZZ_SEED=0xb7a2878b…bdbd7c` | pass, 160 tests, 2 fork tests skipped |
| `forge fmt --check` | pass |
| `forge test --fork-url https://ethereum-rpc.publicnode.com --match-path "test/fork/*"` (launch profile) | 3 passed at block 26188827: v4 fork (live PoolManager + deployed GoblinNFT: initialize as factory, seed, swap, fee, flush, POL add + burn against the 9475 bps floor at the live pool price, a second add settling the positive fee delta, TWAP after 4 h, JIT seed leaves the cap unchanged) and the two v2 fork tests |
| `forge build --skip test --skip script` with the protected `foundry.toml` (`via_ir = true`) | pass (`src/` compiles) |
| `forge build` / `forge test` with the protected `foundry.toml` on the whole tree | **not completed here**: solc was OOM-killed by this sandbox's 1.5 GB cgroup limit, for the pristine v3.1 tree as well (verified by stashing the changes). v3.1 reported this run passing on its machine; repeat on a larger one |
| `testPinnedGachaRuntimeCodeHash` | the pinned hash equals `keccak256(type(BagGacha).runtimeCode)` under the launch profile |

Tools run: forge build/test/fmt only. No Slither/Mythril in this environment.

## Decisions worth reviewing

1. **Exact-output sell partial-fill rule.** The brief says the realised leg must equal `amount`; the pool is handed
   `amount + fee` (the fee is taken out of the pool's output so the swapper receives `amount`), so the check is
   `realised == amount + fee`. The intent, no charge on ETH the pool never produced, is met exactly.
2. **ETH-held bound direction.** ETH is currency0, held between the current price and the *upper* tick of the
   ETH-denominated v4 price, i.e. down to the lowest usable GOLD price; the bound is computed up to tick 887220 and is
   a few wei under the virtual reserve at ordinary prices (rounded down like Uniswap's amount0). Boundary tests now
   use `genesisEthHeld` as the reference.
3. **Genesis buyback value** is the 4-hour value of the min-quoted tokens, which is always ≤ (1−d)P, so the 88%
   buyback can never exceed what the spin paid.
4. **Cancelled free spins keep their coupon used** and the VRF fee stays spent in every cancel; the request does not
   record the token id and a refund of VRF money the wrapper already took is not possible.
5. **Genesis lane liveness.** The first observation records zero liquidity (the pool is seeded after initialization in
   the same transaction), so GOLD is priceable only once a swap at least 30 minutes old has recorded the seeded
   liquidity; documented in the runbook.

## Open items before any funded step

- Repeat `forge build && forge test` under the protected `via_ir = true` profile on a machine with more than 1.5 GB
  for solc.
- Independent adversarial review of the v3.2 changes (bind preconditions against the deployed NFT, the partial-fill
  rule for integrators, the recorded-liquidity bound, the cancel path's interaction with Curator pauses).
- Confirm with IMD which remainder path (A: paying wallet, B: `$contract:GoldHook`) the manifest accepts.
