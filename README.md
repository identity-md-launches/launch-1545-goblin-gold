# Goblin Gold v2 — source only

This assignment changes and tests contracts locally. **Nothing is deployed or broadcast.**
No project token is issued, replaced or re-minted. The later launch objective is **GoblinNFT only**
on Ethereum mainnet; every gacha contract remains a separate, later deployment decision.

## Build and verification

Solidity 0.8.26, optimizer 200, Cancun; dependencies already vendored in `lib/`.

```sh
forge build
forge test
forge fmt --check

# Also check the requested imported-launch compiler settings without changing protected configuration:
FOUNDRY_VIA_IR=false FOUNDRY_BYTECODE_HASH=none forge build
FOUNDRY_VIA_IR=false FOUNDRY_BYTECODE_HASH=none forge test
```

**Configuration conflict:** this assignment's overriding rules prohibit editing `foundry.toml`,
while item 1 requests `via_ir = false` and `bytecode_hash = "none"` there. The existing file is
preserved (`via_ir = true`, default metadata hash). Both compiler modes are checked, but the
actual file change requires an explicitly authorized follow-up **before the imported-launch check**.
Tests use no environment variables, filesystem permissions, FFI or network. Optional fork tests
skip on the default local chain; see `report.md` for attempted network checks and their limitations.

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

### Revenue from day one

`depositRevenue()` accepts positive ETH at any time, including before the first mint and before
sellout. The accumulator is **whole wei per live token**. On each deposit of `D` with `N > 0`
live tokens, every live token earns `D / N`, and `D % N` is added to `retainedRevenue`. A new mint
starts with `revenuePaid[id] = revenuePerToken`, so it receives none of a previous deposit.

Claims belong to the current token owner. Unclaimed revenue travels with transfers; duplicate
IDs in one claim cannot pay twice. A refund burns the NFT and moves **all its unclaimed revenue**
to `retainedRevenue`, emitting `RevenueRetained`. Claim revenue first to avoid forfeiting it.
Deposits at zero live supply are entirely retained. Retained revenue stays in the NFT forever:
there is no sweep and no gift of old deposits to future minters. This explicit whole-wei policy
keeps accounting exact, with less than `liveSupply` wei of dust per nonempty-supply deposit.

Ignoring unsolicited forced ETH, these identities hold:

```text
unclaimed live-token revenue + retainedRevenue
    = totalRevenueDeposited - totalRevenueClaimed
NFT ETH before release = liveSupply * PRICE + unclaimed revenue + retainedRevenue
NFT ETH after release  = polOwed + reserveOwed + vrfOwed + unclaimed revenue + retainedRevenue
```

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
`0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982`. There is no signer-rotation function.
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
at least 50 ETH value. Balances are capped by the pool's current active-liquidity virtual reserves;
donations or inactive positions alone cannot satisfy the bound. Token amounts use native token
units, so e.g. USDC's six decimals are preserved. WETH is valued 1:1 unless paused.

Paused, delisted, stale or thin tokens cannot be sealed into new Bags or enter a new snapshot.
An affected depositor may still withdraw after the normal 24-hour lock without an exit fee,
provided no VRF draw is pending. A pause cannot rewrite a pending draw or cancel a won Bag;
settlement and token claims continue. Liquidity bounds and TWAPs reduce manipulation risk but
are not guarantees of executable depth or token safety. Rebasing/hostile-transfer tokens must
remain excluded by the oracle panel; fee-on-transfer receipts are additionally rejected on chain.

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
- **Request:** one pending draw; mature inventory, prices, weights, effective odds and Genesis
  tokens are committed before requesting VRF. Bag weights are inverse square-root of value.
  Empty-tier odds move to the nearest lower nonempty tier, otherwise higher. Jackpot needs
  reserve at least `20 * 70P = 14 ETH`. Genesis lane is normally 60%, 100% with no regular Bags,
  0% if unavailable. Free spins always clear prior snapshots and force Genesis.
- **Reserve lock:** worst-case committed payout is moved from reserve to `locked` before requesting.
  The callback accepts **only the stored wrapper request ID**, once, and merely stores a word.
  Unknown/stale/duplicate IDs are ignored; other callers revert. No timestamp/block-derived
  randomness determines valuable payouts.
- **Draw/settlement:** anyone calls `draw()`. Winner has five minutes to `choose(keep)` or buyback;
  afterwards anyone `finalize()`s as keep. Keep credits the regular depositor 95% of snapshot
  value and winner pulls the tokens; buyback credits winner 88%, returns the Bag and restarts
  maturity. Genesis keep credits vault tokens, buyback returns their commitment. All ETH is
  pulled with `withdrawCredit`; token claims and settlement cannot repeat.
- **VRF failure:** there is deliberately no timeout reroll, cancellation, refund or admin rescue.
  A permanently missing VRF callback permanently locks the pending draw and listed-Bag withdrawals.
  This inherited liveness tradeoff remains and needs independent review before deployment.
- **Revenue splits:** regular paid spins: 88% reserve / 4% burn / 3% NFT holders / 2% POL / 3% team.
  Genesis: 40% POL / 30% reserve / 15% NFT holders / 15% team. `flush()` forwards the NFT share
  immediately, including before sellout/release. Regular withdrawal fee is 0.5% of current value.
- **Genesis:** regular quote uses `(1-d)P / minTWAP`, a 540-day linear emission schedule, 0.9 decay
  per whole day ahead, remaining inventory, and a hard ceiling of target plus three days of supply.
  Even a single extremely large quote cannot jump past that ceiling. The separate dividend budget
  streams linearly to sqrt-value Bag shares; slices with no shares and rounding dust stay in the vault.

The active inventory cap is reduced from v1's 64 to 32 after a maximum-inventory gas regression;
TWAP windows are fetched together once per quote. Real-pool gas still needs fork validation.

The ETH invariant is `balance = reserve + locked + vrfBudget + holderAccrued + polAccrued +
burnAccrued + totalCredits + heldSpinPayment` (forced unsolicited ETH can add a surplus).
Fulfilling randomness, drawing and settling are separate transactions. Quote or token transfer
failures roll back state and credits; recipients with rejecting fallbacks cannot block other users.

## Deployment parameters and after launch

No launch manifest is written by this assignment. All later addresses must be verified on the
chosen chain and all circular references precomputed and checked. Constructors make no external
calls; this supports empty-chain launch checks and precomputed addresses without dummy values.

| Contract | Constructor arguments / responsibility |
|---|---|
| `GoblinNFT` | `owner_ = $owner` from the launch; the only contract in the next launch objective |
| `TwapOracle` | `(curator, weth, canonicalV3Factory)` |
| `GenesisVault` | `(existingPlatformToken, oracle, gacha, startTime, genesisSupply, dividendBudget, curator)`; fund the full supply; dividend budget intended as 2% of the existing token's supply |
| `BagGacha` | `(oracle, genesis, goblinNFT, vrfWrapper, polManager, team, startTime, curator)`; team is the requester's recipient, never a guessed address |
| `Curator` | `(intakeV2, paymentAsset, oracle, genesis, gacha)`; immutable verified protocol addresses |
| `POLManager` | `(weth, existingPlatformToken, fee, tickSpacing, swapRouter02, positionManager, oracle, goblinNFT)` |

For an Ethereum Curator, the supplied protocol reference identifies Intake v2 as
`0xa43e6f75ee006411f79ac1c84120606c2330de82`, IMD payment asset as
`0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`, and the current fee as 0.5 IMD.
These are inputs to verify before the later gacha deployment, not hardcoded live deployments
made by this job. Pricing is read at each proposal. The existing platform token, funding amounts,
team recipient, start time and pool/fee selection remain later gacha deployment parameters;
none are guessed or needed to launch the NFT by itself.

After the NFT launch, the owner obtains the actual reviewed later deployments and calls
`setLaunchTargets(actualPOLManager, actualBagGacha, actualBagGacha)`. Until then `release()` reverts
`TargetsNotSet`. Holders review and can refund. After sellout and the seven-day review, anyone
calls `release()`, then `POLManager.pullMintEscrow()` and `BagGacha.pullMintEscrow()` to fund their
buckets. Alternatively the gacha can start earlier from explicitly donated reserve and VRF funds.

Unpaid operators/community callers must maintain `reveal`, oracle proposals and their fees,
`execute`/`clear`, `draw`/`finalize`, `flush`, escrow pulls, and POL buy/burn/liquidity/recycle calls.
Individual users pull their own funds. There is no keeper treasury or guaranteed automation.
POL positions remain permanently held by POLManager; remaining LP-token dust is not withdrawable.

Before any funded deployment: independent adversarial review, authorize and apply the protected
compiler-file changes, run real fork tests with a working archive RPC, verify all external code,
review the deployment wiring, and confirm funding and keeper responsibilities. See `report.md`.
