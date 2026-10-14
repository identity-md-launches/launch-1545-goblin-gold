# Goblin Gold v3.4 — source only

This assignment changes and tests contracts locally. **Nothing is deployed or broadcast.** GoblinNFT is already
live on Ethereum at `0xC5d5F314da6d4a433F9BF897a2cC24A537576cB1`; `src/GoblinNFT.sol` is the exact file of
identity-md-launches/launch-1616-goblin-gold-nft-mint commit `dbd66796c56c6df8ab9b5d58686b86ef1111ae5d` and must
never change again. Every gacha contract uses that address as the NFT.

v3 ports the gacha to an IMD Uniswap v4 genesis token (GOLD): `GoldHook` (TWAP ring, hook fee, launch tax),
`TwapOracle` prices GOLD only from the hook, `POLManager` works through the v4 PoolManager, and the launch is split
into two IMD launches. Path A sends the launch remainder to the paying wallet, which funds GenesisVault before naming targets. Everything else from v2
stays: ownerless Curator through the IMD oracle, bounded changes, VRF, free spins only after release, 32 Bags,
Genesis schedule and splits.

v3.4 fixes all seven findings of [audit 1f9510eb](https://github.com/Identity-md/research/blob/main/jobs/1f9510eb-0355-4d2a-8bb7-cf1b35b6a096/files/AUDIT.md), against commit `170070d`.

| Finding | Implemented behavior | Regression in `test/audit1f9510eb/` |
|---|---|---|
| High: upward odds escalation | Empty-tier odds move only down. Without mature, priceable small-tier inventory the regular lane is empty: Genesis-only or `NothingToDraw` | `OddsEscalation.t.sol`: auditor proof, Genesis fallback, fuzzed tier subsets |
| Medium: dust-tick griefing | Walk up to eight initialized crossings per direction, carry conservative liquidityNet, skip exact-price boundaries already crossed | `DustTick.t.sol`, `BandScale.t.sol`: original proofs, both directions, reductions, read budget |
| Medium: POL wiring | Require POL mintEscrow == deployed NFT and POL poolManager == hook poolManager in binding and preflight | `LaunchPreflight.t.sol`: actual miswired deployments; every-wire checks extended |
| Low: band scaling | 5 ETH liquidity-equivalent depth per side **plus a 1 ETH in-band capital floor**; payout <= min(5% of depth, 1x released WETH) | `BandScale.t.sol`: auditor's quarter-ETH pool fails, boundary, both token orders and cap fuzzing |
| Low: Genesis liveness | startTime >= first post-seed swap + 4 hours; keeper makes a dust GOLD swap at least every 50 minutes | `GenesisDark.t.sol`: exact readiness boundary, cadence, stale recovery |
| Low: donated GOLD blocks preflight | Refuse underfunding only; log surplus in base units | `LaunchPreflight.t.sol`: exact funding, one-wei deficit/donation |
| Low: unchecked constructor words / VRF | Expected wrapper, Curator and startTime are script arguments; exercise spinPrice and require fee > 0, total > fee | `LaunchPreflight.t.sol`: wrong/missing wrapper, price failures, zero fee and mismatched arguments |

See [the launch runbook](docs/runbook.md), [verification report](report.md), and [build hashes](docs/build-hashes.json).
The launch profile and deployed NFT source remain unchanged. No new administrative power is introduced.

v3.3 fixes all eight findings of [audit 930ea061](https://github.com/Identity-md/research/blob/main/jobs/930ea061-8714-4c90-9af4-892a151310cb/files/AUDIT.md), reviewed at commit `8b769ee`.

| Finding | Implemented behavior | Regression |
|---|---|---|
| 1 High: concentrated Genesis depth | `beforeAddLiquidity` permits only `[-887220, 887220]`; hook flags `0x38CC` | Auditor's `ConcentratedDepth.t.sol`: both narrow adds are explicitly refused |
| 2 High: inverted POL floor | `polTokensForEth(eth)` uses the larger GOLD quote; vault quotes still use the smaller | Auditor's `PolFloorInverted.t.sol`: both burn and liquidity buys revert `Slippage` after the 31-minute pump |
| 3 Medium: v3 JIT / parked WETH | 30-minute harmonic active liquidity and fixed-band depth, never raw pool balances | `V3Depth.t.sol`: JIT, narrow range, both token orders, harmonic counter wrap, removals, fuzzed bitmap ranges |
| 4 Medium: Genesis spot depth | Maximum of spot/4-hour sqrt prices; minimum of current/30-minute/4-hour L; GOLD refused by `seal` | `GenesisAndBinding.t.sol`: four-hour pump attack cannot create a regular GOLD Bag; same-tx thin-pool gate stays closed |
| 5 Medium: permanent bind lock-out | Shared `bindCheck` and fork preflight before naming; exact launch runtime hash checked | `BindPreflightTest`, `script/CheckLaunch.s.sol` |
| 6 Low: cancel race | New fulfilments ignored at or after the 24-hour deadline | `CancelRace.t.sol`: deadline ±1 second, both orderings, arbitrary words, paused prices |
| 7 Info: incomplete wiring checks | Check oracle hook/token and POL oracle/hook/token; document NFT-owner retarget trust | `BindPreflightTest`: every wire, malformed dependencies, post-bind retarget |
| 8 Info: remainder custody | Path A only; exact vault funding verified before targets are named | `testPathAFundingAndPreflightBeforeOwnerNamesTargets` |
| IMD v4 template | Public pure `getHookPermissions()` with core field order and ABI, matching all 14 flags | `testHookPermissionsMatchCoreABIAndEveryFlag` |

The two executable auditor proofs are preserved, adapted for the new flags and stronger rejection assertions, in
`test/audit930ea061/`. The audit's remaining written reproductions have permanent tests there too. The older
v3.1/v3.2 history below describes earlier changes; the operational sections describe v3.4; later repairs supersede the historical descriptions.

v3.1 (fixes before audit, nothing else):

1. **No IMD protocol address is a constructor word.** The Ethereum IMD Intake v2
   (`0xa43e6F75ee006411F79Ac1C84120606C2330DE82`) and the IMD payment token
   (`0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7`) moved from the Curator constructor into the compiled-in library
   `src/IMDProtocol.sol`, beside the oracle signer and action id. Both were checked against the pinned
   oracle-consumer reference and live on mainnet on 2026-10-13 (`priceOf(action, IMD)` = 0.5 IMD, `symbol()` = IMD).
   `Curator(oracle, genesis, gacha)` now takes only this project's own contracts.
2. **Thresholds for a new project.** Regular v3 Bag pools need 5 ETH of active liquidity per side (was 50); the
   GOLD/ETH v4 pool needs an ETH-side depth of 1 ETH (was 50 per side). TWAP windows and staleness are unchanged.
   To keep thin pools safe against TWAP manipulation, **a single draw pays at most 5% of each token pool's current
   ETH-side depth**, valued at the TWAP: when a win would exceed that, the capped portion is paid from the Bag and
   the rest stays in the Bag (see [Payout cap](#payout-cap-v31)).

v3.2 (audit 85083c05: every critical, high and medium finding plus two lows, nothing else):

| # | Severity | Finding | Fix | Permanent test |
|---|---|---|---|---|
| 1 | Critical | `GoldHook.bindGacha` accepted any look-alike with the pinned code | Binds only the gacha the NFT owner named through the holder-reviewed `setLaunchTargets` (reserve and VRF target, its `polManager()` as POL target), after the 7-day review, and only if `gacha.nft()`, `genesis().token()`, `genesis().gacha()` and `genesis().oracle()` match | `testBindGachaLookalike` |
| 2 | High | `POLManager._addFullRange` never settled a positive fee delta: once the position had earned more LP fees than an add needed, every add reverted | Positive deltas are taken: the ETH is recycled into the POL budget at once, the GOLD stays for the next add (`FeesCollected`) | `testPolFeeBrick` |
| 3 | High | Fee and tax were charged on ETH the pool never consumed when a price limit bounded a swap with ETH specified | `afterSwap` reverts `PartialFill` unless the pool's realised ETH leg equals the ETH it was handed (buy: `amount − fee − tax`; exact-output sell: `amount + fee`). Internal POLManager swaps use the extreme limit | `testPartialFillFee` |
| 4 | High | JIT liquidity inflated the genesis depth and the 5% payout cap | Each hook observation records the active liquidity; the oracle uses `min(current L, L recorded 30 minutes ago)` and bounds the ETH side by the ETH that liquidity holds up to the last usable tick | `testJitPayoutCap` |
| 5 | Medium | The Genesis quote followed the cheaper of the two TWAP windows | `tokensForEth(GOLD)` is the smaller token amount of the two windows and the genesis cap values the quote at the 4-hour TWAP (`genesisValueAndCap`), so both windows must be moved | `testShortWindowPushNoLongerInflatesGenesisBags` |
| 6 | Medium | `MIN_OUT_BPS` used 1250 bps for the 1.25% LP fee | `MIN_OUT_BPS = 10_000 − 125 − 100 − 300 = 9475` | `testMinOutBpsMatchesTheFeeSchedule`, `testMinOutFloorBehaviour` |
| 7 | Low | Exact-output buys paid the 1% fee on the net input | `gross = ethIn · BPS / (BPS − 100 − taxBps)`, `fee = 1% of gross`, `tax = gross − fee − ethIn` | `testExactOutputBuyChargesFeeAndTaxOnTopOfTheEthConsumed` |
| 8 | Low | An unfulfilled VRF request locked the gacha forever | After 24 hours anyone may `cancelRequest()`: the spin price is refunded as a credit, the earmark released, the Genesis tokens uncommitted; the VRF fee stays spent; a late word is ignored | `testUnfulfilledRequestCanBeCancelledAfterADay`, `testCancelledFreeSpinRefundsNothingButReleasesTheGenesisTokens` |

Accepted and documented, no change: **low 9**, the 0.5% withdraw fee is waived while a Bag is unpriceable (a depositor whose
tokens were delisted, paused, stale or thin should not be held to a fee computed from a price that does not exist;
the fee is small and the exit is the safety valve); **info 10**, the 0.5 ETH first-hour buy cap is per swap, not per
wallet (a wallet limit is trivially split across addresses; the cap only bounds the size of a single sandwichable
fill during the launch tax window).

`GACHA_RUNTIME_CODE_HASH` is re-pinned from the final v3.4 launch build.

## Build and verification

Solidity 0.8.26, optimizer 200, Cancun; dependencies vendored in `lib/`. Uniswap v4-core (BUSL/MIT, commit of the
`main` branch on 2026-10-13, package version 1.0.2) is vendored **for tests only** under `test/v4-core/`; `src/`
compiles against the ABI-identical shim `src/v4/V4Minimal.sol` and `src/v4/Hooks.sol`. The latter mirrors core's permissions struct; an ABI round-trip and core's permission validator test every field.

```sh
export FOUNDRY_FUZZ_SEED=0x7b7530bacf0fb10f39cdc83ef3417042968a940fe0c136f823421b92327b104d
forge build
forge test
forge fmt --check
# Launch profile: mandatory for BOTH launch artifacts, including launch 2.
FOUNDRY_VIA_IR=false FOUNDRY_BYTECODE_HASH=none forge build
FOUNDRY_VIA_IR=false FOUNDRY_BYTECODE_HASH=none forge test
# Live mainnet integration, no broadcast; provide the RPC URL as a shell argument.
FOUNDRY_VIA_IR=false FOUNDRY_BYTECODE_HASH=none forge test --fork-url "$RPC" --match-path "test/fork/*"
```

`foundry.toml` is protected and unchanged (`via_ir = true`). Its default artifact is **not a launch artifact**.
Launch 2 must use Solidity 0.8.26, optimizer 200, Cancun, `via_ir = false`, `bytecode_hash = none`; the hook refuses
other runtime code. `testPinnedGachaRuntimeCodeHash` asserts equality under the launch profile and verifies that
the default build is refused. Tests do not read/set environment variables or use FFI. Dependencies remain vendored
as ordinary files. See `report.md` for the actual checks and fork block.

## GoldHook (launch 1, `univ4_hook`)

| Item | Value |
|---|---|
| Constructor | `GoldHook($poolManager, $token, $factory)`; no owner, no setter, no rescue |
| `TARGET_REVIEW_PERIOD` | 7 days, GoblinNFT's holder review; `bindGacha` waits for it |
| Pool | `currency0 = ETH (0x0)`, `currency1 = $token`, fee `12500`, tick spacing `60`, hooks = GoldHook |
| Required hook flags | `0x38CC`: beforeInitialize, afterInitialize, beforeAddLiquidity, beforeSwap, afterSwap, beforeSwapReturnsDelta, afterSwapReturnsDelta. The launch must deploy the hook at an address whose low 14 bits are exactly these (`hasRequiredFlags()`); the PoolManager refuses any other |
| Initialization | `beforeInitialize` accepts only `sender == $factory`, only the platform pool above, once. Any other pool or caller reverts |
| Liquidity ranges | `beforeAddLiquidity` rejects every range except `[-887220, 887220]`. Launch seed and POL positions already use it. Removals remain available to their owners; POL has no removal function |
| Permissions ABI | `getHookPermissions()` returns the 14-field v4-core `Hooks.Permissions` tuple; disabled fields are false |
| Preflight | `bindCheck(candidate)` returns zero when every bind precondition except the review timer passes; otherwise `AlreadyBound`, `CodeMismatch`, `NotLaunchTarget` or `GachaMismatch` selectors. Simulate naming first when targets are not yet set |
| Hook fee | 1% of the ETH side of every swap, on top of the 1.25% LP fee: 50% `holderAccrued` (GoblinNFT holders), 50% `reserveAccrued` (BagGacha reserve) |
| Launch tax (buys only) | 90% for minutes 0–10, 50% for 10–20, 25% for 20–30, then 0; 100% to `reserveAccrued`. ETH in (incl. fee and tax) over 0.5 ETH per buy reverts during the first hour |
| Accounting | Fee/tax are taken as v4 hook deltas and minted as currency-0 ERC6909 claims to the hook inside the PoolManager. The swap path does nothing else |
| `flush()` | Permissionless, batched: burns the claims, takes the ETH, pays `GoblinNFT.depositRevenue()` and, once bound, `BagGacha.fundReserve()`. Before binding only the holder share moves; the reserve share waits in the PoolManager |
| `bindGacha(gacha)` | One-time, permissionless. Requires `gacha.codehash == GACHA_RUNTIME_CODE_HASH`; `GoblinNFT.targetsSet()` with `reserveTarget() == vrfTarget() == gacha` and `polTarget() == gacha.polManager()` (else `NotLaunchTarget`); the 7-day review ended (`targetsSetAt + 7 days`, else `ReviewPending`); `gacha.nft() == GoblinNFT`, `gacha.genesis().token() == $token`, `genesis().gacha() == gacha`, `genesis().oracle() == gacha.oracle()`, oracle `goldHook() == this` / `genesisToken() == token`, POL `oracle() == gacha.oracle()` / `hook() == this` / `token() == token` / `mintEscrow() == NFT` / `poolManager() == address(poolManager)` (else `GachaMismatch`). Then forwards every GOLD the hook holds to that GenesisVault. The NFT owner's holder-reviewed choice is the only way to name the gacha; the hook cannot be pointed at a look-alike |
| Observations | v3-style ring (`observations`, cardinality grows to 4096): the pre-swap tick **and the active liquidity** are recorded once per block in `beforeSwap`; `observe(secondsAgos)` has Uniswap v3 semantics and `liquidityAt(secondsAgo)` returns the liquidity recorded by the observation in force then; both revert `OldObservation` before the ring covers the window. Liquidity changes are only recorded by the next swap in a later block |
| Partial fills | When ETH is the specified currency the charge is taken in `beforeSwap` on the whole amount, so `afterSwap` reverts `PartialFill(realised, expected)` unless the pool realised exactly the ETH it was handed. Swappers must use the extreme price limit (or a limit the pool will not reach) and bound price with a minimum output instead |

**Why a runtime-code hash.** A contract address cannot prove its creation code; the on-chain checkable equivalent
is the runtime code hash. `BagGacha` therefore keeps its wiring in storage set once in the constructor (no
immutables) so every deployment has identical runtime code. `GACHA_RUNTIME_CODE_HASH` is
`0xb1a5cbbca856aef754bdb7d19c2d81b8599e14ee88c3084ffb55f6c6adeb490a`, the hash of the v3.4 `BagGacha` built with the
imported-launch profile (solc 0.8.26, optimizer 200, `via_ir = false`, `bytecode_hash = none`).
`testPinnedGachaRuntimeCodeHash` checks it under that profile and prints the current value; **any change to
`BagGacha.sol` or to the compiler settings changes the hash and must be re-pinned before launch 1**, since the hook
is immutable once launched.

Buy semantics per swap type (ETH is currency0): exact-input buy and exact-output sell charge on the specified ETH
amount in `beforeSwap`; exact-output buy and exact-input sell charge on the ETH leg of the pool delta in
`afterSwap`. For an exact-output buy the pool consumes `ethIn` and the swapper pays `gross = ethIn / (1 − 1% − t)`,
of which the fee is 1% of gross and the tax `gross − fee − ethIn`, exactly the shares an exact-input buy pays.

## TwapOracle

Regular Bag tokens use canonical Uniswap v3 token/WETH pools listed by the Curator: lower of the 30-minute and
4-hour ETH marks, latest observation at most one hour old, and at least **5 ETH liquidity-equivalent depth per
side plus a 1 ETH in-band capital floor in released WETH**. Liquidity-equivalent depth is a bound on L, not a
claim that 5 ETH was deposited. `observe` returns tick and seconds-per-liquidity cumulatives. The latter give the
30-minute harmonic mean active liquidity; the depth calculation starts with `min(current L, harmonic L)`.
Counter subtraction uses v3's wrapping semantics; donations and raw token balances never count.

`src/v3/V3Depth.sol` measures what this bounded liquidity releases in the fixed sqrt-price band
`[sqrtP / 1.05, sqrtP * 1.05]` (approximately -9.3% / +10.25% price). It walks at most **eight initialized ticks
per direction**, reading each tick's `liquidityNet`. At a crossing, compute `L' = L + net` upward or `L - net`
downward and carry `min(L, max(0, L'))` into the next segment. Thus new liquidity across a boundary cannot increase
the bound; a reduction lowers it immediately. A boundary whose price equals the starting price is treated as
already crossed for the bitmap search in either v3 slot0 representation, `(price(T), T)` or `(price(T), T-1)`.
When walking back to the opposite side of that boundary, its liquidityNet is applied first, as in a zero-length
v3 crossing. This preserves dust-tick liveness without crediting liquidity on an empty side.

Each segment rounds down. Released amounts are scaled by the **fixed band's** fraction of a full-range reserve
and capped at the initial virtual reserve to obtain liquidity-equivalent depth. The unscaled WETH released must
also be at least **1 ETH**. The regular-token payout cap is
`min(equivalentWethDepth * 500 / 10000, releasedWeth * 1)`; `IN_BAND_PAYOUT_MULTIPLE = 1` is fixed in code.
At price 1 with constant L across the band, released WETH is approximately `L / 21`; allow rounding headroom
above `L = 21 ETH` to pass the capital floor. Curator policy states both the equivalent-depth and capital bounds.

Empty bitmap words are skipped. The eight-crossing budget discards the unvisited tail, so densely initialized
pools can still be conservatively rejected. One dust position cannot truncate the whole depth at its first tick;
many nearby ticks can exhaust the bounded walk. Operators must monitor actual quotes after listing. The bound
protects capital per request and is not a guarantee of executable liquidity at settlement.

GOLD is priced only from the GoldHook ring. It cannot be given a v3 pool or sealed into a regular Bag: GOLD payouts
use the Genesis lane only. Full-range positions enforced by the hook justify `genesisEthHeld`. With
`L = min(current L, liquidityAt(30 minutes), liquidityAt(4 hours))` and
`S = max(spot sqrtPrice, sqrtPriceAtTick(4-hour mean tick))`, the ETH held up to tick 887220 is
`L * 2^96 * (sqrtMax - S) / (S * sqrtMax)`. It must be at least **1 ETH**, else `ThinPool(hook)`.
Liquidity additions need a later-block swap to record them and four hours of history before the new amount can
count; a removal or unfavorable spot move tightens the bound immediately. The first initialized observation has
zero L, so seed liquidity must be recorded by a subsequent swap and age for four hours before Genesis opens.
**startTime must be at least four hours after that first post-seed swap**, not merely four hours after seeding.
A keeper must make a dust GOLD swap at least every **50 minutes**, starting with that first swap and continuing
after launch. After 3600 seconds without a swap Genesis and POL quotes go stale; a fresh swap restores a seasoned
ring. This permissionless keeper must be funded and monitored by the launch operator; the contracts do not schedule it.

`valueAndCap(token, amount)` returns the lower-window ETH value and the cap above (Genesis: 5% of conservative ETH-side depth).
`payoutCap(token)` exposes the cap alone. WETH is 1:1 and uncapped. Paused, unlisted, stale or thin tokens revert.
`isPriced(GOLD)` only reports initialized/unpaused status; it does not waive history or depth checks.

`tokensForEth(GOLD, eth)` uses the **smaller** window token amount for GenesisVault. `genesisValueAndCap(tokens)`
values it at the 4-hour TWAP: the Genesis value cannot exceed the discounted spin spend. POL buys instead call
`polTokensForEth(eth)`, the **larger** window token amount, before applying the 9475 bps floor. A one-window pump
cannot lower that floor. A sustained price move can eventually move both windows and the depth cap; this is not a
permanent historical price anchor. Excluding GOLD from regular Bags prevents the audit's repeated regular-bag
extraction after a four-hour pump, while Genesis payouts retain their discounted-spend bound.

### Payout cap (v3.1)

Thin-pool TWAPs can be manipulated, so the gacha bounds what any one draw can extract from a pool:

- At request time the snapshot values every mature Bag with `bagPayout(id)`: each token is capped at its pool's cap
  (`amount · cap / value` when `value > cap`). The snapshot value, tier, weight and the reserve earmark are those of
  the **capped** payout. A Bag whose capped value falls under 0.3P is not drawable in that snapshot. The split is
  stored only for Bags where a cap binds, tagged with the snapshot epoch so a stale split can never reach a later draw.
- When such a Bag is drawn, `draw()` **splits** it (`BagSplit` event): the capped amounts become a new Bag id (same
  depositor, status `Drawn`) that the winner keeps or sells back exactly like any Bag; the remainder stays listed in
  the original Bag with its maturity, active slot and withdrawal rights unchanged, and will be capped again the next
  time it is drawn. Dividend shares (`sqrt(value)`) move with the won portion pro rata.
- Keep pays the depositor 95% of the capped value and the winner pulls the capped tokens; buyback pays the winner 88%
  of the capped value and relists only the won portion (it matures again; without a free slot it becomes claimable by
  the depositor). A token line can round to zero in a won portion; zero lines are skipped on transfer.
- The Genesis Bag is capped the same way (`_commitGenesis`, valued with `genesisValueAndCap` at the 4-hour TWAP):
  the vault commits its full quote and the surplus above the cap is returned to it in the same transaction, so
  `emitted` only counts the capped tokens. Free spins included.
- Changing pool depth after the request does not rewrite a committed split or value. The cap is read from the pool
  *at request time*, which bounds the extraction per draw but is not a guarantee of executable depth.
- Regular tokens need both equivalent-depth and capital gates; a 70P payout needs at least 14 ETH of equivalent
  WETH depth and the 1 ETH in-band capital floor. GOLD's minimum 1 ETH depth gives a 0.05 ETH (5P) cap.

## POLManager (v4)

`POLManager(poolManager, token, hook, oracle, mintEscrow)`; fee 12500 and spacing 60 are constants. `buyAndBurn`
and `addLiquidity` run inside `PoolManager.unlock` with this contract as the callback: exact-input ETH→GOLD swaps
with a minimum output of the larger window's token quote net of the 1.25% LP fee, the 1% hook fee and 3%
(`MIN_OUT_BPS = 9475`; launch tax or a price outside that floor makes them revert), full-range (`±887220`) positions owned by POLManager
inside the PoolManager and never removed (there is no function that can), leftover ETH recycled to the POL budget,
leftover GOLD used by the next add. The swaps use the extreme price limit (the hook refuses limit-bounded fills).
Adding to the position returns its accrued LP fees inside the caller delta; when a side comes back positive it is
taken (`FeesCollected`): the ETH joins the POL budget at once, the GOLD waits for the next add, so the callback
always leaves both currencies at zero. No router, no position manager, no owner.

## GoblinNFT

| Parameter | Value |
|---|---|
| Constructor | `GoblinNFT(address owner_)`, owner supplied by the launch as `$owner` |
| Collection | Goblin Gold / GOBLIN; original on-chain 32×32 SVG goblin traders |
| Supply | 10,000 live tokens maximum; sequential IDs are never reused |
| Mint price | 0.001 ETH each; exact payment |
| Per-address mint cap | 20 lifetime mints; transfers and refunds never restore the allowance |
| Refund amount | 0.001 ETH per burned token, paid to its current holder |
| Release | 50% POL / 40% reserve / 10% VRF, using only `liveSupply * PRICE` |

Before sellout, refunding frees supply capacity, with new mints receiving new IDs. At the first
sellout, minting closes permanently, even if later refunds reduce live supply. Refunds normally
close at sellout. **Minters/current holders can always exit with their full mint ETH during any
7-day target review**, including reviews after sellout. Selling the NFT transfers that right to
the buyer. After 90 days from sellout, refunds also reopen until release. At the exact review end,
release becomes possible; at the exact 90-day boundary, the fallback refund becomes possible.
Once released, mint refunds close permanently.

The owner can call `setLaunchTargets(pol, reserve, vrf)` only before release. Every address must
have deployed code. Every call, even with unchanged targets, restarts a full seven-day review.
The code-size check proves a destination is a contract, not that its behavior is safe: holders
must inspect all three destinations during review. Shared destinations are supported; they pull
the sum of their shares. The owner can transfer ownership, and can `renounceOwnership()` **only
after release**. The owner has no withdrawal, pause, mint-rescue, metadata-setting or upgrade power.

Anyone may call `release()` after sellout and review. Destinations pull with `claimRelease()`;
a failed ETH transfer restores the credit. Revenue and retained dust never enter the release split.
The constructor takes one address, calls no external contract and requires no external code.
`script/DeployGoblinNFT.s.sol` is a local reference helper, with an explicit owner argument and no
broadcast call. Do not use a factory's `msg.sender` as the owner.

### Revenue (deployed behaviour)

`depositRevenue()` accepts positive ETH at any time. **Before `release()` it is pooled in `deferredRevenue`**: no
token is credited while its mint is still refundable, `pendingRevenue(id)` shows only a provisional equal share,
`claimRevenue` settles nothing and returns 0, and a refund forfeits nothing (the pool stays for the remaining
holders). At `release()` the pool is split equally across the tokens live at that moment, with whole-wei dust
retained. After release, deposits accrue immediately per live token (`revenuePerToken`), a new mint can no longer
happen, claims belong to the current holder and travel with transfers. `retainedRevenue` (dust and zero-supply
deposits) stays in the contract forever. GoldHook flushes and the gacha's holder share use this path from day one.

Art traits remain hidden until permissionless `reveal()` fixes the collection seed from the block
after sellout. If the block hash aged out, reveal schedules a fresh future block. Rarity is cosmetic,
not payout randomness; proposers/reveal callers can bias it. Metadata uses string/bytes concatenation,
not ambiguous packed encodings, and compiles without IR.

## Ownerless gacha and Curator

`BagGacha`, `GenesisVault`, `TwapOracle`, `POLManager` and `Curator` have **no owner, owner setter,
upgrade, arbitrary execution or rescue function**. Only the immutable Curator can change pools,
token pause status, Genesis discount and tier odds. No one can use Curator to redirect a payout.

`Curator` inherits the supplied canonical `OracleAttestationConsumer`: all 15 fields, the full
type hash, and EIP-712 domain name `IdentityMD Oracle`, version `2`, current chain ID and **the
Curator's own address**. The signer is fixed to
`0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982`. There is no signer-rotation function. Since v3.1 the
intake (`0xa43e6F75ee006411F79Ac1C84120606C2330DE82`, Intake v2) and the payment token
(`0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7`, IMD) are compiled-in constants of `src/IMDProtocol.sol` too,
exposed as `INTAKE` / `PAYMENT_ASSET` (`intake()` / `paymentAsset()`); only that intake can answer a callback.
The supplied code was copied, with its newer `SignatureChecker.isValidSignatureNowCalldata`
call adapted to the vendored OpenZeppelin 5.1 `isValidSignatureNow` equivalent. Protocol digest
and signature vectors test compatibility independently of self-signed mocks.

### Making an oracle-governed change

1. Choose an action and ABI payload from the table below, and an absolute block window. The closing
   block must be 12–300 blocks behind the current block, and the opening block no later than closing.
2. Read `requestBody(kind, data, window)`. This generates the entire question and policy from fixed
   templates; callers cannot supply their own wording or definitions. It includes this Curator,
   chain, exact operation and current resource revision.
3. Use the IMD protocol's `oracleQuestionHash` for that question, chain, resolved **absolute** window
   and definitions. Supply this hash to `propose(kind, data, window, questionHash, maxFee)`. Do **not**
   use `keccak256(requestBody)` in production: that simplification exists only in the mock tests.
   Re-read the preview if another action changes the same resource's revision before submission.
4. Approve the payment asset to Curator for the quoted fee first. Curator reads `Intake.priceOf`,
   enforces `maxFee`, pulls exactly that payment from the proposer, and asks via v2
   `requestWithFailure`. It cannot spend a general treasury. The action is the right-padded
   `bytes32("oracle.request@oracle-1")`, not a keccak hash. A spent fee is not refundable.
5. Intake calls `onOracleResult(bytes32, Attestation, bytes)`. Only Intake and an ID created by
   this Curator can answer a pending request. The signed question hash, chain and block window
   must match the pin. A pin alone cannot substitute a different paid question: the callback must
   also belong to the locally generated request. Unknown, duplicate and consumed UUIDs fail.
6. The callback verifies and stores under the **200,000 gas** budget. Panel size must be at least
   30, quorum at least 20, agreement at least quorum and no greater than panel size. `issuedAt`
   must be after proposal creation, not in the future, and at most one hour old; expiry and the
   300-block closing-window age are checked. A signed `false` stores rejection successfully.
7. Anyone calls `execute(id)` for a still-fresh approval. It rechecks the resource revision, pool
   identity/liquidity and parameter bounds. Effects precede external calls and execution is guarded.
   Execution cannot be repeated. Already committed VRF snapshots keep their original terms.

| Kind | Exact payload | Allowed effect / hard limit |
|---|---|---|
| `Pool` (0) | `abi.encode(token, pool)` | List canonical factory pool for token/WETH; pool zero means intentional delisting, never a missing configuration placeholder |
| `Discount` (1) | `abi.encode(uint256(bps))` | Genesis regular discount 500–1200 bps, initially 800 |
| `Odds` (2) | `abi.encode(uint256[4](odds))` | Positive tiers totaling 10,000 bps, each changes at most **10% relative**; one execution per rolling 24 hours |
| `Pause` (3) | `abi.encode(token, bool(paused))` | Pause/resume new Bags and snapshots involving that token, including its Genesis lane |

Initial odds are `[7500, 1800, 650, 50]`. Thus the first jackpot adjustment is at most 5 bps,
not 1,000 bps. Same-resource concurrent approvals become unusable after one executes; a new
proposal must assess the new state. During the first 48 hours, the fixed holder discount is
**5%**, replacing v1's 3% to respect the requested universal 5–12% band.

Unsigned failure callbacks only close the matching pending request and never change settings.
If no result arrives, anyone can `clear(id)` after one day. Expired approvals can also be cleared.
Intake errors, a wrong question hash, missing callbacks or no panel agreement lose only the
proposer's oracle fee and leave live settings unchanged. Curator requests do not lock user funds.
The fixed signer/action and immutable Intake are intentional deviations from the reference's
owner-settable migration example, required by this task's **no gacha owner** rule. Protocol migration
would require a separately reviewed new system; there is no administrative back door.

### Pricing and pauses

`TwapOracle` values tokens using the lower of the 30-minute and 4-hour Uniswap **v3** TWAPs.
It checks factory `getPool(token, WETH, fee)`, token identities and code, both observation windows,
and latest observation no more than an hour old. At listing **and every quote**, each side needs
at least 5 ETH liquidity-equivalent depth under the harmonic-liquidity and fixed-band bounds described above,
plus at least 1 ETH unscaled in-band WETH capital;
donations and parked out-of-range balances never satisfy the bound. Token amounts use native token
units, so e.g. USDC's six decimals are preserved. WETH is valued 1:1 unless paused. The Curator's
question policy names both bounds and the fixed 1x in-band capital payout limit.

Paused, delisted, stale or thin tokens cannot be sealed into new Bags or enter a new snapshot.
An affected depositor may still withdraw after the normal 24-hour lock without an exit fee,
provided no VRF draw is pending. A pause cannot rewrite a pending draw or cancel a won Bag;
settlement and token claims continue. Liquidity bounds, TWAPs and the per-draw payout cap reduce
manipulation risk but are not guarantees of executable depth or token safety. Rebasing/hostile-transfer
tokens must remain excluded by the oracle panel; fee-on-transfer receipts are additionally rejected on chain.

## Game lifecycle and funding

- **Early funding:** anyone can donate with `fundReserve()` and `fundVRF()`. These are irrevocable
  donations with no withdrawal right. Thus paid spins and holder revenue
  can operate before NFT sellout, while all mint ETH stays refundable in GoblinNFT. Reserve
  donations of at least `2P` and adequate payout backing, plus inventory, are needed before spins.
- **Entry:** `P = 0.01 ETH` plus `calculateRequestPriceNative` from the immutable Chainlink VRF v2.5
  direct-funding wrapper. Overpayment becomes a pull credit. First 48 hours: `holderSpin(id)`,
  at most five per NFT. Afterwards: public `spin()`. Two `freeSpin(id)` per NFT, Genesis-only,
  keep-only; their VRF fees use `vrfBudget`. **Free coupons unlock only after NFT escrow release**,
  preventing mint/refund/new-ID cycling for unlimited free tokens. Paid early spins remain available.
  All per-NFT limits persist across transfers.
- **Bags:** one to four distinct listed ERC20s, excluding GOLD, at most 32 active Bags. Value 0.3–70 times P and
  no more than 5% of available reserve. Bag maturity is 24 hours. Values split into small
  `[0.3P,0.7P)`, medium `[0.7P,2P)`, large `[2P,6P)`, jackpot `[6P,70P]`.
- **Request:** one pending draw; mature inventory, capped payout values, weights, effective odds and Genesis
  tokens are committed before requesting VRF. Bag weights are inverse square-root of (capped) value.
  Empty-tier odds move only to the nearest lower nonempty tier. If small-tier weight is zero, the entire regular
  lane is empty for that request: its snapshot and liability are cleared. Genesis is then 100%, or the request
  reverts `NothingToDraw` before a VRF fee is spent when Genesis is unavailable. Each tier can receive only its own
  odds plus higher empty-tier odds; mature, priceable small-tier inventory is necessary for regular draws.
  Jackpot needs reserve at least `20 * 70P = 14 ETH`. Genesis lane is normally 60%, 100% with no eligible regular
  lane, 0% if unavailable. Free spins always clear prior snapshots and force Genesis.
- **Reserve lock:** worst-case committed payout is moved from reserve to `locked` before requesting.
  The callback accepts **only the stored wrapper request ID**, once, and merely stores a word.
  Unknown/stale/duplicate/expired IDs are ignored; other callers revert. No timestamp/block-derived
  randomness determines valuable payouts.
- **Draw/settlement:** anyone calls `draw()`. If the drawn Bag's payout cap binds, the capped portion is split
  off into a new Bag id first (the allocation's `bagId`), the rest staying listed. Winner has five minutes to
  `choose(keep)` or buyback; afterwards anyone `finalize()`s as keep. Keep credits the regular depositor 95% of
  the (capped) snapshot value and winner pulls the tokens; buyback credits winner 88%, returns the (won) Bag and
  restarts its maturity. Genesis keep credits vault tokens, buyback returns their commitment. All ETH is
  pulled with `withdrawCredit`; token claims and settlement cannot repeat.
- **VRF failure:** no reroll and no admin rescue. If the wrapper has not delivered the word within 24 hours
  (`CANCEL_DELAY`), anyone may `cancelRequest()`: the spin price (plus any overpayment) becomes the spinner's credit,
  the worst-case earmark returns to the reserve, the committed Genesis tokens return to the vault, the snapshot is
  discarded and withdrawals reopen. The VRF fee was paid to the wrapper and is not refunded; a free spin refunds
  nothing and its coupon stays used. At `requestedAt + CANCEL_DELAY` or later a new word is ignored even if cancel
  has not run: transaction ordering cannot choose between refund and fulfilment. A request fulfilled strictly before
  that deadline can never be cancelled, only drawn, even if drawing happens after the deadline.
- **Revenue splits:** regular paid spins: 88% reserve / 4% burn / 3% NFT holders / 2% POL / 3% team.
  Genesis: 40% POL / 30% reserve / 15% NFT holders / 15% team. `flush()` forwards the NFT share
  immediately, including before sellout/release. Regular withdrawal fee is 0.5% of current value.
- **Genesis:** regular quote uses `(1-d)P` at the less favourable of the two TWAPs (fewer tokens), a 540-day linear emission schedule, 0.9 decay
  per whole day ahead, remaining inventory, and a hard ceiling of target plus three days of supply.
  Even a single extremely large quote cannot jump past that ceiling. The separate dividend budget
  streams linearly to sqrt-value Bag shares; slices with no shares and rounding dust stay in the vault.

The active inventory cap is reduced from v1's 64 to 32 after a maximum-inventory gas regression;
TWAP windows are fetched together once per quote. Real-pool gas still needs fork validation.

The ETH invariant is `balance = reserve + locked + vrfBudget + holderAccrued + polAccrued +
burnAccrued + totalCredits + heldSpinPayment` (forced unsolicited ETH can add a surplus).
Fulfilling randomness, drawing and settling are separate transactions. Quote or token transfer
failures roll back state and credits; recipients with rejecting fallbacks cannot block other users.

## Launch runbook

Two IMD launches, path-A vault funding covering genesisSupply, a fork preflight, the NFT owner's naming transaction, a 7-day review,
then permissionless binding and release. No transaction is authorized or broadcast by this source-only assignment.
Do not redeploy the existing NFT or replace/remint any already launched project token.

### Launch 1 — GOLD + GoldHook (`univ4_hook`)

- Pool: native ETH / GOLD, fee `12500`, spacing `60`, full range `[-887220, 887220]`.
- `GoldHook($poolManager, $token, $factory)`. The factory initializes inside the launch transaction.
- Mine the hook address to low 14 bits **`0x38CC`**, replacing the old `0x30CC`. In the generated `launch.json`,
  enable `beforeAddLiquidity` along with the existing before/after initialize, before/after swap and both swap
  return-delta permissions. All seven other permissions must be false. The exact 14-field tuple is in
  `docs/hook-permissions.json` and is exposed by `getHookPermissions()`. This checkout has no `launch.json` or
  manifest schema; the separate manifest step must apply these values to its complete manifest. The JSON file in
  `docs/` is a permissions fragment, not a launch manifest.
- The hook pins BagGacha runtime hash
  `0xb1a5cbbca856aef754bdb7d19c2d81b8599e14ee88c3084ffb55f6c6adeb490a`.
- **Path A only:** `remainderTo` is the paying wallet `0xA7e99BB7155D7477E0C838E201b16E62B9c0b5Ac`.
  Read the exact remainder from the launch record; use it as `genesisSupply` for launch 2. The paying wallet is
  responsible for transferring that exact amount to GenesisVault before targets are named. Hook custody is not
  part of this runbook. The existing bind-time forwarding of unsolicited GOLD remains available.
- Platform 1% goes to the same paying wallet through `LaunchFactory.claimFees`, outside these contracts.
- Seed more than 1 ETH of full-range ETH depth, allow rounding headroom, and record it with a swap in a later
  block. Record the timestamp T1 of this **first post-seed swap**. Set `startTime >= T1 + 4 hours`, allowing
  funding and the seven-day review to finish too. Initialization time alone is not the readiness anchor.
- **Keeper step:** the launch operator provisions a funded keeper to make a dust GOLD swap at least every
  50 minutes from T1 onward, confirms successful inclusion and monitors `lastObservationTimestamp`. A small
  exact-input GOLD sell through the canonical v4 router avoids the early-buy tax; use an appropriate minimum
  output and deadline. The amount must be sufficient to execute at the pool's price and fee. Alert before
  60 minutes elapse and retry failed transactions. No special keeper privilege or new contract is required.

### Launch 2 — the gacha set

Build **only** with `FOUNDRY_VIA_IR=false FOUNDRY_BYTECODE_HASH=none` (Solidity 0.8.26, optimizer 200, Cancun).
Do not use the default `foundry.toml` artifact for launch 2. Verify the runtime hash from the actual deployed code,
not merely the local artifact, before naming targets. All relationships below are immutable or constructor-set;
`bindCheck` verifies the vault, oracle and POL links against the candidate and launch-1 hook/token.

No constructor word is an IMD protocol address: those remain compiled into `src/IMDProtocol.sol`. `<GOLD>` and
`<GoldHook>` come from launch 1; `$contract:` references are resolved by the launcher.

| Contract | Constructor words, in source order |
|---|---|
| `TwapOracle` | `$contract:Curator`, WETH `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2`, v3 factory `0x1F98431c8aD98523631AE4a59f267346ea31F984`, `<GOLD>`, `<GoldHook>` |
| `GenesisVault` | `<GOLD>`, `$contract:TwapOracle`, `$contract:BagGacha`, `startTime`, `genesisSupply`, `dividendBudget`, `$contract:Curator` |
| `BagGacha` | `$contract:TwapOracle`, `$contract:GenesisVault`, `0xC5d5F314da6d4a433F9BF897a2cC24A537576cB1`, VRF v2.5 wrapper `0x02aae1A04f9828517b3007f83f6181900CaD910c`, `$contract:POLManager`, `team`, `startTime`, `$contract:Curator` |
| `Curator` | `$contract:TwapOracle`, `$contract:GenesisVault`, `$contract:BagGacha` |
| `POLManager` | `$poolManager`, `<GOLD>`, `<GoldHook>`, `$contract:TwapOracle`, `0xC5d5F314da6d4a433F9BF897a2cC24A537576cB1` |

Deployment parameters are resolved before the separate launch: `startTime` (at least T1 + four hours, also allowing funding/review time),
`genesisSupply` (exact launch remainder), `dividendBudget` (2% of total token supply, below genesisSupply), and `team`
(the requester's recipient). This code-only repair introduces no guessed recipient, key or deployment id.
A protocol migration requires a new Curator build; no administrative setters are added.

### After launch 2 — before naming anything

1. The paying wallet transfers **exactly `genesisSupply` GOLD** to GenesisVault. Verify on chain that
   `balanceOf(vault) >= genesisSupply`. Retain the transfer receipt. Check this before funding game activity or
   naming targets, so no already-withdrawn inventory complicates the preflight. Underfunding is rejected; unsolicited
   surplus is logged in base units and does not block launch. Surplus does not increase the configured emission budget.
2. Check on-chain `extcodehash(BagGacha) == GoldHook.GACHA_RUNTIME_CODE_HASH()` and verify the launch-1 permissions.
   Fetch runtime code with `cast code "$GACHA" --rpc-url "$RPC"` and hash it with `cast keccak`; compare to
   `cast call "$HOOK" 'GACHA_RUNTIME_CODE_HASH()(bytes32)' --rpc-url "$RPC"`.
3. **Before sending `setLaunchTargets`, run the prospective naming and `bindCheck == 0` in a fork simulation:**

   ```sh
   FOUNDRY_VIA_IR=false FOUNDRY_BYTECODE_HASH=none forge script script/CheckLaunch.s.sol:CheckLaunch \
     --fork-url "$RPC" --sig 'run(address,address,address,address,uint256)' \
     "$HOOK" "$GACHA" "$WRAPPER" "$CURATOR" "$START_TIME"
   ```

   Supply WRAPPER from the verified chain table (Ethereum wrapper above), CURATOR from the resolved deployment,
   and START_TIME from the agreed launch schedule; do not derive expected values from gacha getters.
   This script never broadcasts and needs no private key. It checks code hash, flags, initialization, sufficient
   vault funding (logs surplus), POL mintEscrow/PoolManager, expected wrapper/Curator/startTime, and vault Curator.
   It calls `spinPrice()` and requires fee > 0 and total > fee, catching a disabled/misconfigured wrapper. The
   script impersonates the NFT owner locally to name the proposed targets, requires `bindCheck == 0`, then simulates
   the actual bind at the review boundary. A direct check against the as-yet-unnamed on-chain state correctly returns
   `NotLaunchTarget`; ignoring target checks would weaken the requested preflight. Do not add `--broadcast`.
4. Only after the simulation succeeds does the NFT owner send
   `GoblinNFT.setLaunchTargets(POLManager, BagGacha, BagGacha)`. Re-read the on-chain targets and require the real
   `GoldHook.bindCheck(BagGacha) == 0` immediately, while the review still permits corrections.
5. Holders review for 7 days with refunds available. A renaming restarts the timer. Before the boundary, repeat the
   preflight against the current named contracts and bytecode. After the boundary, simulate `bindGacha` with
   `eth_call`, then anyone submits `bindGacha(BagGacha)` and verifies `GoldHook.gacha()`.
6. Anyone may `release()` once sold out and reviewed, then call `POLManager.pullMintEscrow()` and
   `BagGacha.pullMintEscrow()`. Release is permissionless and **can race binding**: the runbook cannot enforce their
   order. All structural checks and funding must already have passed before the review expires. For a valid set,
   binding still works if release happens first. Pre-release NFT revenue remains deferred until release.

### Operational responsibilities and trust assumptions

- Permissionless operators call hook/gacha `flush`, `bindGacha`, `reveal`, Curator proposals/execute/clear, escrow
  pulls, POL `addLiquidity`/`buyAndBurn`/`recycle`, `draw`/`finalize`, and cancellation after an unfulfilled 24-hour
  deadline. Fees and payouts wait for these calls; no privileged keeper is introduced.
- The launch operator maintains the 50-minute dust GOLD swap keeper and alerts on failed inclusion. Monitor
  pool history and freshness: GOLD needs both 30-minute and four-hour recorded liquidity, four-hour tick
  history and a swap within the last hour. The ring has 4096 entries; if activity overwrites the required history,
  quotes fail closed. Regular v3 pools need both windows and adequate harmonic and band depth.
- The paying wallet controls the remainder until its path-A transfer. Sufficient funding verification before naming is
  an operational commitment, not a new contract escrow. Do not name unfunded targets.
- The deployed NFT owner remains the naming authority. **Even after GoldHook binds, that owner can call
  `setLaunchTargets` again until NFT release.** Hook fees keep going to the first bound gacha, while NFT escrow can
  go to the newly reviewed targets. The owner must not retarget after binding; holders must monitor every naming
  event and use the renewed review/refund window. No source change here can remove that power from the deployed NFT.
- `bindCheck` validates fixed relationships and code identity; it cannot establish honesty of mutable or malicious
  substitutes for the oracle, vault or POL. Verify the actual deployed artifacts for the whole set. A bad set frozen
  by release is not recoverable; preflight is a prerequisite, not an admin rescue mechanism.
- Depth/cap bounds reduce manipulation exposure; they do not guarantee execution liquidity at settlement time.
  Sustained manipulation of both windows remains possible. GOLD is Genesis-only, with value bounded by `(1-d)P`.
- Partial fills with ETH specified revert; integrators use the extreme sqrt-price limit and a minimum output.
  POL's floor is the larger window quote times 9475 bps, accounting for LP fee, hook fee and allowed impact.
- VRF fees stay spent and cancelled free coupons stay used. Once the 24-hour deadline passes, an unfulfilled
  request must be cancelled; waiting for a later word cannot revive it. A pre-deadline fulfilment remains drawable.
- Verify constructor values and chain contract identities at deployment; preserve the deployed NFT and existing
  build configuration. Obtain independent adversarial review of these repairs before any funded launch.
