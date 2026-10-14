# Goblin Gold v3.2 — source only

This assignment changes and tests contracts locally. **Nothing is deployed or broadcast.** GoblinNFT is already
live on Ethereum at `0xC5d5F314da6d4a433F9BF897a2cC24A537576cB1`; `src/GoblinNFT.sol` is the exact file of
identity-md-launches/launch-1616-goblin-gold-nft-mint commit `dbd66796c56c6df8ab9b5d58686b86ef1111ae5d` and must
never change again. Every gacha contract uses that address as the NFT.

v3 ports the gacha to an IMD Uniswap v4 genesis token (GOLD): `GoldHook` (TWAP ring, hook fee, launch tax),
`TwapOracle` prices GOLD only from the hook, `POLManager` works through the v4 PoolManager, and the launch is split
into two IMD launches with no owner custody beyond the NFT owner's `setLaunchTargets`. Everything else from v2
stays: ownerless Curator through the IMD oracle, bounded changes, VRF, free spins only after release, 32 Bags,
Genesis schedule and splits.

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

`GACHA_RUNTIME_CODE_HASH` was re-pinned from the final v3.2 build.

## Build and verification

Solidity 0.8.26, optimizer 200, Cancun; dependencies vendored in `lib/`. Uniswap v4-core (BUSL/MIT, commit of the
`main` branch on 2026-10-13, package version 1.0.2) is vendored **for tests only** under `test/v4-core/`; `src/`
compiles against the ABI-identical shim `src/v4/V4Minimal.sol` and nothing else.

```sh
forge build && forge test && forge fmt --check
FOUNDRY_VIA_IR=false FOUNDRY_BYTECODE_HASH=none forge build
FOUNDRY_VIA_IR=false FOUNDRY_BYTECODE_HASH=none forge test
# optional, needs an Ethereum RPC (live v4 PoolManager + deployed GoblinNFT):
forge test --fork-url $RPC --match-path "test/fork/*"
```

`foundry.toml` is protected and unchanged (`via_ir = true`). The launch profile (`FOUNDRY_VIA_IR=false
FOUNDRY_BYTECODE_HASH=none`) builds and passes 160 tests (2 fork tests skipped without a fork); the 3 fork tests pass
against mainnet. Under the pinned `via_ir = true` profile `src/` compiles; compiling the whole tree with the vendored
v4-core tests needs more than the 1.5 GB of memory the v3.2 build sandbox had (solc was killed there, for the v3.1
tree as well), so that run is reported from v3.1 and must be repeated on a larger machine. Tests read no environment variables and use no FFI or filesystem access. The Curator tests
etch their intake and token mocks at the compiled-in `IMDProtocol` addresses.

## GoldHook (launch 1, `univ4_hook`)

| Item | Value |
|---|---|
| Constructor | `GoldHook($poolManager, $token, $factory)`; no owner, no setter, no rescue |
| `TARGET_REVIEW_PERIOD` | 7 days, GoblinNFT's holder review; `bindGacha` waits for it |
| Pool | `currency0 = ETH (0x0)`, `currency1 = $token`, fee `12500`, tick spacing `60`, hooks = GoldHook |
| Required hook flags | `0x30CC`: beforeInitialize, afterInitialize, beforeSwap, afterSwap, beforeSwapReturnsDelta, afterSwapReturnsDelta. The launch must deploy the hook at an address whose low 14 bits are exactly these (`hasRequiredFlags()`); the PoolManager refuses any other |
| Initialization | `beforeInitialize` accepts only `sender == $factory`, only the platform pool above, once. Any other pool or caller reverts |
| Hook fee | 1% of the ETH side of every swap, on top of the 1.25% LP fee: 50% `holderAccrued` (GoblinNFT holders), 50% `reserveAccrued` (BagGacha reserve) |
| Launch tax (buys only) | 90% for minutes 0–10, 50% for 10–20, 25% for 20–30, then 0; 100% to `reserveAccrued`. ETH in (incl. fee and tax) over 0.5 ETH per buy reverts during the first hour |
| Accounting | Fee/tax are taken as v4 hook deltas and minted as currency-0 ERC6909 claims to the hook inside the PoolManager. The swap path does nothing else |
| `flush()` | Permissionless, batched: burns the claims, takes the ETH, pays `GoblinNFT.depositRevenue()` and, once bound, `BagGacha.fundReserve()`. Before binding only the holder share moves; the reserve share waits in the PoolManager |
| `bindGacha(gacha)` | One-time, permissionless. Requires `gacha.codehash == GACHA_RUNTIME_CODE_HASH`; `GoblinNFT.targetsSet()` with `reserveTarget() == vrfTarget() == gacha` and `polTarget() == gacha.polManager()` (else `NotLaunchTarget`); the 7-day review ended (`targetsSetAt + 7 days`, else `ReviewPending`); `gacha.nft() == GoblinNFT`, `gacha.genesis().token() == $token`, `genesis().gacha() == gacha`, `genesis().oracle() == gacha.oracle()` (else `GachaMismatch`). Then forwards every GOLD the hook holds to that GenesisVault. The NFT owner's holder-reviewed choice is the only way to name the gacha; the hook cannot be pointed at a look-alike |
| Observations | v3-style ring (`observations`, cardinality grows to 4096): the pre-swap tick **and the active liquidity** are recorded once per block in `beforeSwap`; `observe(secondsAgos)` has Uniswap v3 semantics and `liquidityAt(secondsAgo)` returns the liquidity recorded by the observation in force then; both revert `OldObservation` before the ring covers the window. Liquidity changes are only recorded by the next swap in a later block |
| Partial fills | When ETH is the specified currency the charge is taken in `beforeSwap` on the whole amount, so `afterSwap` reverts `PartialFill(realised, expected)` unless the pool realised exactly the ETH it was handed. Swappers must use the extreme price limit (or a limit the pool will not reach) and bound price with a minimum output instead |

**Why a runtime-code hash.** A contract address cannot prove its creation code; the on-chain checkable equivalent
is the runtime code hash. `BagGacha` therefore keeps its wiring in storage set once in the constructor (no
immutables) so every deployment has identical runtime code. `GACHA_RUNTIME_CODE_HASH` is
`0x2db1143638494d63cd5b4b807bd3dfe333d590ea58e7204ab7fd0c5cf415c4cd`, the hash of the v3.2 `BagGacha` built with the
imported-launch profile (solc 0.8.26, optimizer 200, `via_ir = false`, `bytecode_hash = none`).
`testPinnedGachaRuntimeCodeHash` checks it under that profile and prints the current value; **any change to
`BagGacha.sol` or to the compiler settings changes the hash and must be re-pinned before launch 1**, since the hook
is immutable once launched.

Buy semantics per swap type (ETH is currency0): exact-input buy and exact-output sell charge on the specified ETH
amount in `beforeSwap`; exact-output buy and exact-input sell charge on the ETH leg of the pool delta in
`afterSwap`. For an exact-output buy the pool consumes `ethIn` and the swapper pays `gross = ethIn / (1 − 1% − t)`,
of which the fee is 1% of gross and the tax `gross − fee − ethIn`, exactly the shares an exact-input buy pays.

## TwapOracle

Two sources. Regular Bag tokens keep canonical Uniswap v3 token/WETH pools listed by the Curator with the v2 rules
(min(30 m, 4 h) TWAP, **5 ETH** of active liquidity on each side (`MIN_LIQUIDITY`), latest observation at most one
hour old). The genesis token can never be given a v3 pool (`setPool`/`validatePool` revert `PoolMismatch`): it is
priced only from the GoldHook ring with the same windows and staleness, and a depth check on the v4 pool's active
liquidity: with `L = min(current liquidity, liquidityAt(30 minutes))`, the ETH that liquidity holds up to the last
usable tick (`genesisEthHeld`, `L·2^96·(√Pmax − √P)/(√P·√Pmax)`, never above the virtual reserve `L·2^96/√P` and a
few wei under it at ordinary prices) must be at least **1 ETH** (`MIN_GENESIS_DEPTH`), else `ThinPool(hook)`.
Liquidity added inside a transaction is invisible to this bound until a later block's swap records it and that
observation is 30 minutes old; liquidity removed counts at once. `isPriced(GOLD)` is true once the pool is initialized and GOLD is not paused; the Curator can still
pause it. Constructor: `TwapOracle(curator, weth, v3Factory, genesisToken, goldHook)`.

`valueAndCap(token, amount)` returns the TWAP value together with the token's **payout cap**: `PAYOUT_CAP_BPS`
(5%) of the pool's current ETH-side depth, which is `min(WETH balance, active virtual reserve)` for a v3 pool and
the JIT-proof depth above for the GOLD pool. WETH has no pool and no cap. `payoutCap(token)` exposes the cap alone.
Both revert exactly where `valueInEth` reverts (paused, unlisted, stale, thin).

Genesis quotes (v3.2): `tokensForEth(GOLD, eth)` is the **smaller** token amount of the 30-minute and 4-hour windows,
the quote less favourable to the buyer of a Genesis Bag; `genesisValueAndCap(tokens)` values them at the **4-hour**
TWAP alone beside the cap. The gacha uses both, so one window pushed down hands out no extra tokens and one window
pushed up does not loosen the cap: a Genesis Bag can only be inflated by moving both windows.

### Payout cap (v3.1)

With 5 ETH / 1 ETH of depth a TWAP is cheap to move, so the gacha bounds what any one draw can extract from a pool:

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
- At the minimum depths the caps are 0.25 ETH (25P) per regular token and 0.05 ETH (5P) for GOLD; a 70P jackpot in
  a single token needs 14 ETH of depth in that pool.

## POLManager (v4)

`POLManager(poolManager, token, hook, oracle, mintEscrow)`; fee 12500 and spacing 60 are constants. `buyAndBurn`
and `addLiquidity` run inside `PoolManager.unlock` with this contract as the callback: exact-input ETH→GOLD swaps
with a minimum output of the TWAP quote net of the 1.25% LP fee, the 1% hook fee and 3% (`MIN_OUT_BPS = 9475`; a
launch-tax window or a manipulated pool makes them revert), full-range (`±887220`) positions owned by POLManager
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
at least 5 ETH value. Balances are capped by the pool's current active-liquidity virtual reserves;
donations or inactive positions alone cannot satisfy the bound. Token amounts use native token
units, so e.g. USDC's six decimals are preserved. WETH is valued 1:1 unless paused. The Curator's
question policy still names the depth bound a listed pool must have (5 ETH per side).

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
- **Bags:** one to four distinct listed ERC20s, at most 32 active Bags. Value 0.3–70 times P and
  no more than 5% of available reserve. Bag maturity is 24 hours. Values split into small
  `[0.3P,0.7P)`, medium `[0.7P,2P)`, large `[2P,6P)`, jackpot `[6P,70P]`.
- **Request:** one pending draw; mature inventory, capped payout values, weights, effective odds and Genesis
  tokens are committed before requesting VRF. Bag weights are inverse square-root of (capped) value.
  Empty-tier odds move to the nearest lower nonempty tier, otherwise higher. Jackpot needs
  reserve at least `20 * 70P = 14 ETH`. Genesis lane is normally 60%, 100% with no regular Bags,
  0% if unavailable. Free spins always clear prior snapshots and force Genesis.
- **Reserve lock:** worst-case committed payout is moved from reserve to `locked` before requesting.
  The callback accepts **only the stored wrapper request ID**, once, and merely stores a word.
  Unknown/stale/duplicate IDs are ignored; other callers revert. No timestamp/block-derived
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
  nothing and its coupon stays used. A word arriving after the cancel is ignored (the stored id is cleared), and a
  request that *was* fulfilled can never be cancelled, only drawn.
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

Two IMD launches, then one NFT-owner transaction, a 7-day holder review, then the permissionless binding. **The
order matters (v3.2):** launch 1 (token + hook) → launch 2 (the gacha set) → `setLaunchTargets` → 7-day review →
`bindGacha` → `release()`. The hook refuses to bind anything the NFT owner has not named and reviewed. No launch
wallet ever holds a gacha key: every contract is ownerless and wired by `$contract:` references.

**No constructor word of any launch is an IMD protocol address** (intake, IMD token, delivery contract or signer):
those live in `src/IMDProtocol.sol`. Constructor words are only launch placeholders, `$contract:` references, the
deployed GoblinNFT, Ethereum's canonical WETH / Uniswap v3 factory / Chainlink VRF wrapper, and the requester's own
values.

### Launch 1 — `univ4_hook`: GOLD token + GoldHook

- Objective: launch the project token paired with ETH, platform pool fee `12500`, tick spacing `60`, hook contract
  `GoldHook`, hook address mined to flags `0x30CC`. The hook carries `GACHA_RUNTIME_CODE_HASH`
  `0x2db1143638494d63cd5b4b807bd3dfe333d590ea58e7204ab7fd0c5cf415c4cd` (the v3.2 `BagGacha` under the launch
  profile) and binds nothing until launch 2 is named by the NFT owner and reviewed by holders.
- Constructor words: `GoldHook`: `$poolManager`, `$token`, `$factory`.
- The hook must be initialized by `$factory` inside the launch transaction; it rejects any other initializer.
- Remainder: one of the two paths below. Both are implemented and tested
  (`testFlushBeforeBindPaysHoldersOnlyAndBindRequiresPinnedCode` covers the hook-custody forwarding).
  - **Path A — wallet custody:** `remainderTo` = the paying wallet `0xA7e99BB7155D7477E0C838E201b16E62B9c0b5Ac`,
    which funds GenesisVault in one public transfer right after launch 2. The launch-2 word `genesisSupply` must
    equal that transfer exactly (the vault quotes nothing until `balanceOf(vault) >= genesisSupply − withdrawn`).
  - **Path B — hook custody (no wallet ever holds GOLD), if the manifest allows `remainderTo = $contract:GoldHook`:**
    the hook has no owner and no transfer function; the only way GOLD leaves it is `bindGacha(gacha)`, which forwards
    the entire balance to the GenesisVault of the one BagGacha that matches the pinned code, the NFT and the token.
    `genesisSupply` is then the launch-1 remainder, read from the launch-1 record before launch 2.
- The pool must reach an ETH-side depth of at least 1 ETH before GOLD is priced (Genesis lane, POL buys); the seeded
  liquidity of launch 1 should be at least that. The depth counts only liquidity that a swap has recorded in an
  observation at least 30 minutes old, so GOLD is priceable 30 minutes after the first post-seed swap at the earliest
  (and, as before, 4 hours after initialization).
- Platform 1% goes to the paying wallet through `LaunchFactory.claimFees`, outside these contracts.

### Launch 2 — contracts: TwapOracle, GenesisVault, BagGacha, Curator, POLManager

- Objective: deploy the ownerless gacha set wired to the launch-1 token and hook. Its `BagGacha` must be the exact
  v3.2 build (its runtime code hash is the one pinned in the hook), `GenesisVault.gacha` must be `$contract:BagGacha`
  and vault, gacha and POLManager must share `$contract:TwapOracle`: `bindGacha` checks every one of these. Nothing
  binds or receives escrow until the NFT owner names this set and the review ends.

Constructor words (order as in the sources); `<GOLD>` and `<GoldHook>` are the launch-1 token and hook addresses
read from the launch-1 record:

| Contract | Words |
|---|---|
| `TwapOracle` | `$contract:Curator`, WETH `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2`, Uniswap v3 factory `0x1F98431c8aD98523631AE4a59f267346ea31F984`, `<GOLD>`, `<GoldHook>` |
| `GenesisVault` | `<GOLD>`, `$contract:TwapOracle`, `$contract:BagGacha`, `startTime`, `genesisSupply`, `dividendBudget`, `$contract:Curator` |
| `BagGacha` | `$contract:TwapOracle`, `$contract:GenesisVault`, `0xC5d5F314da6d4a433F9BF897a2cC24A537576cB1`, VRF v2.5 wrapper `0x02aae1A04f9828517b3007f83f6181900CaD910c`, `$contract:POLManager`, `team`, `startTime`, `$contract:Curator` |
| `Curator` | `$contract:TwapOracle`, `$contract:GenesisVault`, `$contract:BagGacha` |
| `POLManager` | `$poolManager`, `<GOLD>`, `<GoldHook>`, `$contract:TwapOracle`, `0xC5d5F314da6d4a433F9BF897a2cC24A537576cB1` |

Values the requester supplies: `startTime`, `genesisSupply` (path A: the planned transfer; path B: the launch-1
remainder), `dividendBudget` (2% of supply), `team` (the requester's recipient). The IMD Intake v2 and the IMD token
are compiled into `Curator` through `IMDProtocol` and appear in no manifest; a protocol migration needs a new
Curator build, there is no setter.

### After launch 2 (in this order)

1. The NFT owner calls `GoblinNFT.setLaunchTargets($contract:POLManager, $contract:BagGacha, $contract:BagGacha)`
   with the launch-2 addresses. This is the one transaction that names the gacha; a look-alike can never be bound.
2. Holders review the three destinations for 7 days (refunds are open during the review). The hook reverts
   `ReviewPending` until `targetsSetAt + 7 days`; any new `setLaunchTargets` call restarts the review.
3. After the review, anyone calls `GoldHook.bindGacha($contract:BagGacha)`: the pinned code, the named targets, the
   NFT, the token and the vault/oracle wiring are verified, the reserve share of hook fees becomes flushable, and
   (path B) the GOLD held by the hook moves to the vault. Until then the reserve share waits in the PoolManager and
   only the holder share flushes.
4. Path A only: the paying wallet transfers exactly `genesisSupply` GOLD to GenesisVault. Until then (either path)
   the vault quotes zero and the Genesis lane is unavailable while regular Bags keep working.
5. Anyone calls `release()` (sold out and reviewed), then `POLManager.pullMintEscrow()` and
   `BagGacha.pullMintEscrow()`. Revenue deposited by `GoldHook.flush()` before release is pooled in the NFT
   (`deferredRevenue`) and split equally across the tokens live at release, as the deployed NFT code dictates.

### Operational responsibilities (unpaid, permissionless)

`GoldHook.flush()` (hook fees do nothing until flushed; the holder share can be flushed from launch 1 onwards),
`bindGacha` once after the review, `reveal`, Curator proposals and their IMD fees, `execute`/`clear`,
`draw`/`finalize`, `cancelRequest` after a day without a VRF word, gacha `flush`, escrow pulls,
`POLManager.addLiquidity`/`buyAndBurn`/`recycle`. GOLD pricing needs a swap on the v4 pool within the last hour, at
least 4 hours of ring history and an observation at least 30 minutes old that recorded the pool's liquidity; before
that, Genesis quotes revert and the Genesis lane is unavailable while regular Bags keep working. The NFT owner's
responsibility is the single `setLaunchTargets` call naming the launch-2 set, and nothing else.

### Assumptions and open items

- The IMD `univ4_hook` launch deploys the hook at an address carrying flags `0x30CC` and initializes the pool from
  `$factory` in the launch transaction. The hook does not check its own flags in the constructor (the launch
  checks run on an empty chain); `hasRequiredFlags()` is a view for the pre-launch check.
- The pinned `GACHA_RUNTIME_CODE_HASH` (`0x2db1…c4cd`, v3.2) is only valid for the imported-launch build profile;
  re-pin after any change.
- `bindGacha` trusts the deployed GoblinNFT's `setLaunchTargets`/review as the naming authority; the NFT owner can
  name a wrong set, which holders can refuse by refunding during the review, and which the hook still refuses unless
  its wiring is self-consistent. The 7-day review is the deployed NFT's constant, mirrored in the hook.
- Partial fills with ETH specified revert: integrators must send the extreme `sqrtPriceLimitX96` and bound price
  with a minimum output. The JIT-proof depth means the Genesis lane opens 30 minutes after the first post-seed swap.
- A cancelled request costs the spinner the VRF fee (and a free coupon); this is the price of liveness without a
  reroll, and a spinner who prefers to wait can simply not cancel (anyone else may, after 24 hours).
- Depth bounds (v3.1): 5 ETH per side for regular v3 pools, 1 ETH of ETH-side depth for the GOLD pool. A thinner
  GOLD pool leaves the Genesis lane unavailable (quotes revert) without affecting regular Bags. The per-draw payout
  cap (5% of the pool's ETH-side depth at request time) bounds what a manipulated TWAP can extract per draw; it does
  not bound what a manipulated TWAP can make the gacha *accept* at seal (the 5% of reserve cap and tiers still
  apply), nor is pool depth at request time a guarantee of executable depth at claim time.
- The IMD intake and token constants are the Ethereum values; a deployment on another chain needs the library
  changed and the Curator rebuilt.
- Fork tests passed on 2026-10-14 against the live Ethereum PoolManager `0x000000000004444c5dc75cB358380D2e3dE08A90`
  and the deployed GoblinNFT through a public non-archive RPC (latest block); see `report.md`.
- Independent adversarial review of the v3.2 changes before any funded step.
