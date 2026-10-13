# Goblin Gold: GoblinNFT mint + Bag gacha (code)

This job **deploys only `GoblinNFT`** (Ethereum mainnet, via the launch). Everything else in `src/`
(`BagGacha`, `GenesisVault`, `TwapOracle`, `POLManager`) is written and tested as code and is **not deployed**.
No token actions. Parameters follow research 20ccee81 §3.7, safety design follows b7e0e298.

`forge build`, `forge test` (21 tests) and `forge fmt --check` pass with solc 0.8.26 (pinned, `via_ir`).
Dependencies (OpenZeppelin v5.1.0, forge-std v1.9.4) are vendored under `lib/`.

## GoblinNFT (deployed now)

| Item | Value |
|---|---|
| Supply / price | 10,000 at 0.001 ETH (`PRICE`, `MAX_SUPPLY`) |
| Per wallet | max 20 minted per address (refunds do not restore the allowance) |
| Constructor | `GoblinNFT(address owner_)` — `owner_` = `$owner` (the launch owner). One argument, no external calls. |
| Art | fully on-chain 32x32 SVG: skin, ears, face, outfit, headwear, bag type, what peeks out, held item, background, rarity (common 60 / uncommon 25 / rare 10 / epic 4 / legendary 1 %), glow on epic and legendary. Rarity is cosmetic only. |

**Trait assignment.** Traits are a hash of a collection seed and the token id. The seed is fixed by
permissionless `reveal()` from the hash of the block after the sellout block, so no minter knows any token's
traits at mint time and cannot pick rare ids. If more than 256 blocks pass, `reveal()` arms a fresh future block
instead of using an empty hash. A block proposer could bias the seed slightly; acceptable because traits carry no
economic value. Before reveal, `tokenURI` shows an unrevealed silhouette.

**Escrow (ownerless funds).**
- Before sellout anyone can `refund(tokenId)`: the token burns and 0.001 ETH returns. Burned slots can be re-minted, so sellout stays reachable.
- At sellout minting closes and refunds close.
- The owner's **only** power: `setLaunchTargets(pol, reserve, vrf)`, before release. Every call starts a **7-day review** during which holders may refund again, so a bad destination can always be exited.
- After the review, anyone calls `release()`: 50% POL / 40% payout reserve / 10% VRF budget, booked as pull credits; each destination calls `claimRelease()` (ETH always goes to the caller).
- If nothing was released 90 days after sellout, refunds reopen (until a release happens).
- No withdraw, sweep, pause or upgrade function exists.

**Holder revenue.** After release, anyone may `depositRevenue()`; `claimRevenue(ids)` pays the current
owner per token (accumulator; dust stays in the contract). The gacha's 15%/3% NFT-holder shares arrive here.
Free spins (2 per NFT) and the 48 h holder window are enforced by `BagGacha` using `ownerOf`.

## After launch

| Setting | Setter | What to set | Where it comes from |
|---|---|---|---|
| Escrow destinations | `GoblinNFT.setLaunchTargets(pol, reserve, vrf)` (owner) | `pol` = deployed `POLManager`; `reserve` and `vrf` = deployed `BagGacha` | the later gacha deployment job. Until set, `release()` reverts `TargetsNotSet`. |
| Release | `GoblinNFT.release()` (anyone) | — | after sellout and the 7-day review |
| Pull shares | `BagGacha.pullMintEscrow()`, `POLManager.pullMintEscrow()` | — | after release |
| Token pools | `TwapOracle.setPool(token, v3Pool)` (owner) | canonical Uniswap v3 token/WETH pool per listed token | curator review (token safety, ≥50 ETH per side) |

Operational responsibilities: someone must call `reveal()` after sellout, `release()`/pulls after review,
`draw()` after each VRF answer, `finalize()` after 5-minute windows, `flush()` to forward holder/POL/burn
shares, and `buyAndBurn`/`addLiquidity`/`recycle` on POLManager. All are permissionless.

## Gacha contracts (code only)

**Entry.** `spin()` pays `P = 0.01 ETH + VRF fee` where the fee is `calculateRequestPriceNative` from the
Chainlink VRF v2.5 wrapper (direct funding, native). Excess is credited. During the first 48 h only
`holderSpin(tokenId)` works (GoblinNFT holders, 5 per NFT, Genesis d = 3%). `freeSpin(tokenId)` — 2 per NFT,
Genesis lane only, keep only, VRF paid from the mint's 10% VRF budget.

**Round transitions (b7e0e298).** One outstanding draw at a time. The request transaction values every mature
listed Bag at the oracle (min of 30 m / 4 h TWAP), fixes tiers, 1/sqrt(value) weights, effective tier odds
(an empty tier's odds go to the nearest lower non-empty tier, else higher; jackpot off while reserve < 20 × 70P),
the Genesis lane probability (g = 60%, 100% if no regular Bags, 0% if Genesis is unavailable) and the Genesis
quote (tokens reserved in GenesisVault). The VRF callback `rawFulfillRandomWords` only stores the word (wrapper
only, never reverts on stale/duplicate). Anyone then calls `draw()`, which selects from the committed snapshot.
The winner has 5 minutes to `choose(keep|buyback)`; after that anyone `finalize()`s as keep. Bags mature 24 h
after sealing or after a buyback before they are drawable. **No timeout reroll, no refund of a pending request,
no admin rescue**: if VRF never answers, the pending draw (and the listed Bags it locks from withdrawal) stays
stuck. This is the accepted liveness trade-off of b7e0e298.

**Payout.** Keep: winner pulls the Bag's tokens (`claimBag`), depositor credited 95% of the committed value (5%
stays in reserve). Buyback: winner credited 88%, Bag returns to the pool and re-matures. Genesis keep: tokens via
`GenesisVault.claim()`; Genesis buyback 88%, tokens return to the vault. All ETH is pull-based (`withdrawCredit`).

**Funding / reserve.** Internal only: 88% of regular spins, 30% of Genesis spins, 40% of the mint, depositor
fees and the 0.5% exit fee. `receive()` accepts ETH only from GoblinNFT. Splits: Genesis 40 POL / 30 reserve /
15 holders / 15 team; regular 88 reserve / 4 burn / 3 holders / 2 POL / 3 team. Invariants: a Bag ≤ 5% of
reserve at seal and at snapshot; spins revert while reserve < 2P × open requests; the worst-case payout of the
committed snapshot is earmarked (`locked`) before VRF is asked, and replaced by the exact allocation payout at
draw. Tests assert `balance == reserve + locked + vrfBudget + accrued shares + credits + held spin` after every step.

**Genesis.** `tokens = min((1−d)·P / minTWAP, schedule-decayed, remaining)`, d = 8% (3% holders), linear
540-day schedule, ×0.9 per whole day ahead, closed at ≥ 3 days ahead (`maxAheadDays`). Dividends: 2% of supply
(`dividendBudget`) streamed linearly over 540 days to `sqrt(value)` shares of listed Bags, paid to depositors.

**Valuation.** `TwapOracle`: Uniswap **v3** pools only (v4 pools have no built-in observation history);
min(30 m, 4 h) TWAP; ≥ 50 ETH WETH balance and ≥ 50 ETH token-side value in the pool; latest observation ≤ 1 h
old. Unpriceable Bags are skipped by the snapshot and may exit without the exit fee.

**Administrative powers.** GoblinNFT owner: escrow destinations (with review window). TwapOracle owner: token
pool listing. Nothing else: no pause, no parameter setters, no upgrade, no sweep, no VRF coordinator migration
(the consumer does not inherit `ConfirmedOwner`).

### Deployment parameters for the later job (assumptions)
- `GenesisVault(token, oracle, gacha, startTime, genesisSupply, dividendBudget)` — `gacha` is the precomputed
  `BagGacha` address (deploy GenesisVault immediately before BagGacha); `dividendBudget` = 2% of token supply.
- `BagGacha(oracle, genesis, goblinNFT, vrfWrapper, polManager, team, startTime)` — `vrfWrapper` is Chainlink's
  VRF v2.5 wrapper on mainnet (verify on chain before use; not verified in this job); `team` is the requester's.
- `POLManager(weth, token, fee, tickSpacing, swapRouter02, positionManager, oracle, goblinNFT)`.
- `TwapOracle(owner, weth)`.

### Deviations and open items
- Kept regular Bags are delivered as their tokens (pull), not as a tradable sealed Bag NFT.
- Fee-on-transfer/rebasing tokens must be kept out by curation (`setPool`); `seal` does not measure balance deltas.
- Tier odds, g and d are constants (no curator oracle).
- Dividend slices streamed while no shares exist stay unassigned in the vault.
- Static analysis (slither 0.11.4, run locally): no high findings; one medium false positive remains in
  `TickMath` (divide-before-multiply on the shift-and-multiply chain inherited from Uniswap's tick math).
- Tests use mocks for the oracle, VRF wrapper and POL; they do not prove production randomness or pricing.
  POLManager swap/LP paths are untested against real Uniswap contracts.
- This is not an audit. The gacha holds other people's funds and needs an independent adversarial review before
  any deployment. Gambling/securities questions noted in 20ccee81 §6 need counsel.
