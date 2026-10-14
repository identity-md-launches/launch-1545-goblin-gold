# Goblin Gold v3.3 — work report

Source-only repair of [audit 930ea061](https://github.com/Identity-md/research/blob/main/jobs/930ea061-8714-4c90-9af4-892a151310cb/files/AUDIT.md), against commit `8b769ee90e4d9189996578e1287fcd1ca32d752e`.
Nothing was deployed, broadcast, re-minted or installed. The deployed `src/GoblinNFT.sol`, protected build
configuration, dependencies and remappings are unchanged.

## Delivered changes

| Finding | Repair | Permanent proof / test |
|---|---|---|
| 1 High: concentrated Genesis liquidity | GoldHook requires `[-887220, 887220]` in its PoolManager-only `beforeAddLiquidity`; flags are `0x38CC` | Both auditor `ConcentratedDepthTest` proofs now explicitly require the narrow add to fail; full-range seeding/POL/removal still work |
| 2 High: POL floor | New `TwapOracle.polTokensForEth(ethAmount)` takes the larger window quote; POL uses it; GenesisVault keeps the smaller quote | Auditor `PolFloorInvertedTest` now checks the protective floor and requires both `buyAndBurn` and `addLiquidity` to revert `Slippage` after the 31-minute pump |
| 3 Medium: v3 JIT and parked balances | Decode seconds-per-liquidity cumulatives; min(current, 30-minute harmonic L); measure released amounts before the first initialized tick inside a fixed band, scale to full-range-equivalent depth, cap at virtual reserves; never use raw balances | `V3JitCapTest`: unchanged same-tx full-range JIT cap, narrow positions fail closed, out-of-range/donated balances cannot pass, both token orders, harmonic counter wrap, removals, missing history, negative/word-boundary bitmap ticks, fuzzed ranges |
| 4 Medium: spot Genesis depth | Depth uses max(spot sqrt price, 4-hour sqrt price) and min(current L, 30-minute L, 4-hour L); regular `seal` refuses GOLD | `GenesisSpotDepthTest`, `SameTransactionGenesisGateTest`, four-hour liquidity/price boundary tests; the four-hour pump cannot create a regular GOLD Bag and Genesis value remains bounded by discounted spin spend |
| 5 Medium: bind lock-out | `bindCheck` shares all bind checks except review timing; fork-only `CheckLaunch.s.sol` verifies runtime/funding/flags, simulates naming, requires zero reason and simulates binding after review | `BindPreflightTest`: wrong code/wires caught before naming; valid preflighted set still binds if permissionless release wins the race |
| 6 Low: cancel race | Callback ignores all new words at or after `requestedAt + CANCEL_DELAY` | `CancelRaceTest`: one second before deadline still fulfils; exact deadline ignores; fuzzed late words/orderings have only cancellation outcome; cancellation works when quotes are paused |
| 7 Info: missing wiring checks | Oracle hook/token and POL oracle/hook/token must match; malformed dependency returns a reason; NFT-owner retarget authority documented | `testBindCheckChecksEveryWireWithoutWaitingForReview`, malformed getters, post-bind retarget |
| 8 Info: remainder custody | Runbook uses path A only, exact transfer and `balanceOf(vault) == genesisSupply` before naming; simulation checks equality | Preflight rejects both underfunding and overfunding; exact wallet transfer succeeds |
| IMD template | Public pure `getHookPermissions()` returns the ABI-identical v4-core 14-field tuple | Core `Hooks.validateHookPermissions`, ABI round-trip and every bit tested against `REQUIRED_FLAGS` |
| Runtime pin | `0xbdb13664f85a03997922c0678be6c02e83716a9d7b24e0cd231ae51a3c8af1ad` | Hash equality is mandatory under the launch profile; default-profile code is explicitly tested as refused, with no silent skip on launch mismatch |

The audit's two executable Solidity proofs are adapted in `test/audit930ea061/ConcentratedDepth.t.sol` and
`PolFloorInverted.t.sol`. The written reproductions for findings 3–8 are implemented in the other files in that
directory. Existing v3.2 tests were updated for four-hour liquidity seasoning, conservative integer rounding and
the additional binding relationships. Existing invariant handlers continue to exercise successful binding.

## Verification (2026-10-14)

Fuzz seed: `0x7b7530bacf0fb10f39cdc83ef3417042968a940fe0c136f823421b92327b104d`.
Compiler: the protected `foundry.toml` pins Solidity 0.8.26, optimizer 200, Cancun.

| Check | Result |
|---|---|
| `FOUNDRY_VIA_IR=false FOUNDRY_BYTECODE_HASH=none forge build` | Pass |
| Same launch profile, `forge test` with the specified seed | 198 passed, 0 failed, 2 fork-only suites skipped offline |
| Same launch profile, `forge test --fork-url https://ethereum-rpc.publicnode.com --fork-block-number 26189273 --match-path 'test/fork/*' -vv` | 3 passed, 0 failed: canonical v3 USDC/WETH history/decimals/depth, VRF wrapper routing, live v4 PoolManager + deployed NFT |
| Protected default profile, `forge build` / seeded `forge test` | Pass: build completed in 381 seconds; 198 passed, 0 failed, 2 fork-only suites skipped offline |
| `forge fmt --check` | Pass |
| `git diff --check`; permissions JSON bitmask | Pass; all 14 fields map to `0x38CC` |

The v4 fork verifies factory-only initialization, exact flags, full-range acceptance/narrow-range rejection,
swap fees, holder flush into the deployed NFT, POL full-range additions and burn, fee collection, four-hour TWAP
and JIT cap bounds. The wrapper test impersonates the coordinator locally; it tests routing, not production VRF
proof generation. Fork tests contain no RPC URLs or environment reads and are opt-in via CLI.

Launch runtime sizes: BagGacha 23,332 bytes; GoldHook 14,132; TwapOracle 12,180; POLManager 9,000;
GenesisVault 5,347. All are below EIP-170's 24,576-byte runtime limit. No externally linked library is introduced.
Tools used: Foundry build/test/fmt, code review, and read-only HTTP/RPC access. Slither/Mythril were not run.

## Deployment details and limits

- The checkout contains **no `launch.json`** or manifest schema. No incomplete manifest was fabricated.
  `docs/hook-permissions.json` supplies the exact new permissions tuple; README instructs the separate manifest
  step to use `0x38CC` and enable `beforeAddLiquidity` in its complete `launch.json`.
- Launch 2 is mandatory `via_ir = false`, `bytecode_hash = none`. Compare the actual deployed BagGacha's
  `extcodehash` to the pinned hash before naming; do not infer correctness from its source name.
- `bindCheck` must include the named NFT targets, so it cannot be zero in an unnamed on-chain state. Before
  `setLaunchTargets`, the supplied script simulates the prospective naming on a fork, checks zero, then simulates
  binding at the review boundary. After real naming, require the real on-chain view to return zero immediately.
  Repeat before review expiry; after expiry simulate the actual binding call. Release is permissionless and cannot
  be forced to wait for binding. There is no rescue if a bad set is frozen by release.
- Path A retains wallet custody until the exact funding transfer. Funding verification and the no-retarget-after-bind
  rule are operational responsibilities. The deployed NFT owner can still retarget until release; hook binding
  cannot be changed, so retargeting can split hook-fee and escrow destinations. This trust assumption is explicit.
- v3 depth stops at the first initialized tick, even when liquidity might survive crossing it. This conservative
  choice prevents out-of-range balances from inflating depth and bounds read costs. It may reject otherwise usable
  pools, including after a tiny new position inserts a nearby tick. The cap is based on full-range-equivalent depth,
  not raw balances or the amount released inside the band. Curators must evaluate the actual bound before listing.
- The four-hour Genesis price bound prevents an instant spot pump from lifting the cap. A sustained move can change
  both windows; it is not a permanent baseline. GOLD cannot enter regular Bags, and Genesis quote/value remains
  bounded by `(1-d)P`. Liquidity additions need a later-block observation plus four hours before they can raise depth.
- Deployment choices (`startTime`, `genesisSupply`, dividend budget, team recipient, resolved contract references)
  remain launch inputs, described in README; no guessed production values were added. No new administration or
  recovery authority was introduced. Independent review remains required before a funded launch.
