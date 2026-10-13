# Goblin Gold v2 implementation report

## Scope and configuration conflict

Implemented source changes and local tests only. No deployment, broadcast, production transaction,
project-token issuance, credential access or launch manifest. Existing dependencies and protected
configuration are unchanged.

**Item 1 cannot be applied to the file under this assignment's overriding rule.** That rule explicitly
protects `foundry.toml`; item 1 requests editing it. The file still pins solc 0.8.26, optimizer 200,
Cancun and `via_ir = true`, with the default metadata hash. The complete source is also checked with:

```sh
FOUNDRY_VIA_IR=false FOUNDRY_BYTECODE_HASH=none forge build
FOUNDRY_VIA_IR=false FOUNDRY_BYTECODE_HASH=none forge test -vv
```

`forge config --json` under those process-local overrides confirms solc 0.8.26, optimizer enabled,
200 runs, `via_ir: false`, `evm_version: cancun`, `bytecode_hash: none`.
An authorized next task must change `[profile.default]` to `via_ir = false` and
`bytecode_hash = "none"` before the imported-launch check. This submission does not pretend the
protected configuration requirement has been completed.

## Changes

- **NFT revenue:** deposits at any time, including zero supply and before sellout. New mints start
  at the current accumulator. Accumulation uses whole wei per live token, with explicit remainder
  retention. Burned tokens' unclaimed revenue and zero-supply deposits are retained and logged.
  Aggregate deposits, claims and retained amounts are auditable; mint refunds and release are
  separately backed. Transfers carry unpaid entitlement; repeated IDs cannot claim twice.
- **NFT owner/release:** destinations require deployed code and remain immutable after release.
  Every target update restarts a seven-day refund review. Ownership renunciation is gated until
  release. README explicitly explains the full-mint-ETH exit throughout every review, the 90-day
  fallback, and the review/end boundary.
- **Metadata/compiler:** removed every `abi.encodePacked` use from production source, including
  `tokenURI` and art assembly. String/bytes concatenation preserves the JSON/SVG and removes the
  previous submission's reported multi-dynamic packed-encoding finding. Split art assembly to
  avoid legacy compiler stack-depth failures.
- **Ownerless Curator:** immutable production signer
  `0x5598Aa9146215Bc13eb26f2c692Ad1461Fd32982`; canonical 15-field EIP-712 attestation in its own
  domain; fixed question/policy templates; absolute-window question hashes pinned before purchase;
  only self-created Intake request IDs accepted; minimum panel 30/quorum 20; freshness and expiry;
  UUID replay protection; separate stored approvals and permissionless execution. Resource revisions
  prevent stale concurrent approvals overwriting newer state. Negative answers, unsigned failures,
  timeouts, unsupported callers, malformed answers and payment ceilings have safe outcomes.
- **Bounded changes:** only Curator may list/delist canonical v3 WETH pools, pause/resume one token,
  set regular Genesis discount to 5–12%, or change each tier's odds by at most 10% relative once per
  rolling 24 hours. Odds remain positive and total 10,000 bps. Holder discount is now 5%, replacing
  v1's 3% to satisfy the same requested band. Gacha contracts contain no owner or owner setters.
- **Pool checks:** immutable factory identity; code, pair, observations and both TWAP windows;
  50 ETH per side enforced at listing and every quote, using balances capped by active virtual
  reserves. One `observe` reads both windows; prices are reused for depth checks and valuation.
  Pool safety is rechecked when an approved listing executes.
- **Early launch:** permissionless irrevocable reserve/VRF donations bootstrap the gacha without
  using refundable mint proceeds. `flush()` pays NFT holders before release. End-to-end day-one
  paid-spin, revenue claim and NFT refund is tested.
- **Gacha repairs:** stored VRF request ID must match the callback; old IDs cannot settle new requests.
  Free spins clear old snapshots and always use Genesis; unavailable Genesis cannot route them into
  regular Bags. An unavailable Genesis quote does not block regular draws. Token receipt deltas
  reject fee-on-transfer Bags. Pending snapshots retain original odds and valuations during curation.
- **Refund-cycle protection:** paid early spins remain available, but free coupons unlock only
  after NFT escrow release. Otherwise a caller could mint, consume free Genesis coupons, refund
  the NFT and remint new IDs indefinitely. Review refunds remain unrestricted; the new early-launch
  regression verifies that refundable IDs cannot consume coupons even with a donated VRF budget.
- **Genesis:** individual commitments cannot jump past target plus three days of distributable supply;
  the linear schedule, daily decay, remaining supply, dividend backing and bounds are tested.
- **Gas bound:** the 64-Bag/256-token benchmark used 18,430,425 request gas with mock pool histories,
  already above the 16,777,216 cap specified by [EIP-7825](https://eips.ethereum.org/EIPS/eip-7825).
  Active capacity is reduced to **32 Bags**, and redundant TWAP reads removed. The replacement
  32-Bag/128-distinct-pool benchmark uses 8,279,235 request gas and asserts a 12-million ceiling.
  Actual v3 history traversal remains a fork-validation item, not proven by mocks.
- **POLManager:** constructor now rejects missing addresses, identical WETH/token, zero fee and
  invalid tick spacing. No owner or administrative setter added.

## Verification

Final checks passed:

| Check | Result |
|---|---|
| `forge build` (protected default profile, IR enabled) | Pass, solc 0.8.26 |
| `forge test -vv` (default profile) | 96 passed, 0 failed, 1 skipped fork setup; 16 suites |
| `forge build` with `FOUNDRY_VIA_IR=false FOUNDRY_BYTECODE_HASH=none` | Pass, solc 0.8.26 |
| `forge test -vv` with the same overrides | 96 passed, 0 failed, 1 skipped fork setup; 16 suites |
| `forge fmt --check` | Pass |
| `git diff --check` | Pass |

Both profiles ran the full unit, fuzz and invariant suite. Test harness time/height reads use the
Foundry getters across `warp`/`roll` calls so optimizer caching cannot invalidate simulated boundary
checks; the cross-chain signature test pins its test chain explicitly. Protected configuration,
dependency and repository-control paths were not changed.

The full legacy/no-hash run passed **96 tests, 0 failures**, with the optional mainnet fork suite
reported as **one skipped setup** (it contains two fork tests). Four stateful invariants each ran
128 sequences of 64 calls: **32,768 generated handler calls**. Six fuzz tests ran 256 cases each.
No unexpected invariant-handler reverts were reported. Some generated handler calls intentionally
return when their action's preconditions do not hold.

| Coverage | Evidence |
|---|---|
| Mint caps, refunds, reviews, 90 days, release, revenue, transfers | `test/GoblinNFT.t.sol`, `test/GoblinNFTV2.t.sol` |
| Independent per-token revenue/refund model; sellout escrow/review/release model | `test/GoblinNFT.invariant.t.sol`, `test/GoblinEscrow.invariant.t.sol` |
| Reserve equality, locked liabilities, Bag token custody, no double payout, draw/choose/finalize | `test/BagGacha.t.sol`, `test/BagGachaV2.t.sol`, `test/BagGacha.invariant.t.sol` |
| Early launch and pre-sellout holder payment | `EarlyGachaTest` in `test/BagGachaV2.t.sol` |
| Genesis curve, huge-quote cap, discounts, claims and dividend backing | `test/GenesisVault.t.sol` and gacha invariant |
| Curator authorization, bounds, replay, domain separation, stale/negative/failure answers, timeouts, reentry | `test/Curator.t.sol`, `test/Curator.invariant.t.sol` |
| Unmodified protocol digest/signature vector, canonical callback selector, real crypto verification | `test/OracleConsumerConformance.t.sol` |
| Canonical pools, both liquidity sides, inactive liquidity, stale/unavailable histories and pause | `test/TwapOracle.t.sol` |
| Maximum inventory and bounded snapshot gas | `test/GasBench.t.sol` |

The mock Intake makes result callbacks with an actual **200,000 gas limit**. Test-only signer
injection exists exclusively in `test/mocks/CuratorMocks.sol`; production Curator always pins the
requested attester. The unmodified protocol vector is verified through the same inherited verifier;
a separately signed bool vector exercises the actual Curator callback. Mock question hashes use a
simplified body hash; production must use the protocol's canonical question-document hash, as
explained in README. No paid live oracle request was made.

The all-10,000-refunds test pauses gas metering for its mass setup/refund loop because it simulates
thousands of independent user transactions in one test transaction. Its reported aggregate test gas
is therefore not a deployment or production transaction estimate.

### Fork coverage gap

`test/fork/MainnetFork.t.sol` provides opt-in tests for the actual Ethereum Uniswap v3 USDC/WETH
pool, native-payment VRF wrapper requests, and wrapper routing of a locally simulated coordinator
callback. It reads no environment variables and performs no network calls without CLI fork setup.
Default offline tests skip its setup when chain ID is not 1.

Attempted:

```sh
FOUNDRY_VIA_IR=false FOUNDRY_BYTECODE_HASH=none forge test \
  --match-path test/fork/MainnetFork.t.sol \
  --fork-url https://rpc.flashbots.net --fork-block-number 26183757 \
  --fork-retries 0 --fork-retry-backoff 1 -vv
```

**Could not run:** fork creation returned HTTP 504. That endpoint answered `eth_blockNumber` but
rejected `eth_call` as “rpc method is not whitelisted”; `cast code` also returned HTTP 504.
Publicnode, LlamaRPC, Cloudflare, MEV Blocker, dRPC, 1RPC, BlockPI and Blast endpoints returned HTTP
403 for the attempted reads; Ankr required authentication. No live code/identity verification is
claimed. Retry the fork suite with an authorized working archive RPC and a confirmed block before
any gacha launch. Even a passing local coordinator-impersonation test would verify wrapper ABI and
routing, not a live cryptographic VRF fulfillment.

Fork addresses were checked against the
[official Chainlink v2.5 network table](https://docs.chain.link/vrf/v2-5/supported-networks) and
[official Uniswap Ethereum deployments](https://developers.uniswap.org/docs/protocols/v3/deployments/v3-ethereum-deployments),
plus the supplied address reference. Wrapper: `0x02aae1A04f9828517b3007f83f6181900CaD910c`;
coordinator: `0xD7f86b4b8Cae7D942340FF628F82735b7a20893a`; factory:
`0x1F98431c8aD98523631AE4a59f267346ea31F984`. These remain **unverified on chain in this job** and
are only test fixtures/configuration candidates, not deployed application settings.

### Static checks

`forge lint src --severity high` ran. It reports four `reentrancy-eth` warnings at the NFT refund,
release claim, revenue claim, and gacha credit withdrawal calls. Each clears/updates its liability
before sending ETH and is protected by the existing OpenZeppelin `nonReentrant` guard. Refund and
credit-withdrawal malicious-receiver tests verify rollback and blocked reentry. These lint warnings
are recorded, not suppressed or represented as a clean independent audit.

Normal build lint also flags deliberate time comparisons, bounded external-call loops, casts,
raw ERC721 mint to the caller, and guarded external interactions/events. All production packed
encoding was removed. The existing TickMath reciprocal/shift algorithm is unchanged; its known-value
unit tests pass. Slither and Mythril are not installed and were not run. No dependencies were installed
or modified to bypass the protected paths.

## Gas and bytecode

Solc 0.8.26, optimizer 200, Cancun, **IR disabled, metadata hash none**. Representative successful
calls from `forge test --gas-report` (mock services, state-dependent costs; exclude reverted calls):

| Operation | Measured gas |
|---|---:|
| NFT mint, quantities 1–20 | 132,246–703,845 |
| NFT depositRevenue | 41,940–93,240 |
| NFT claimRevenue, one token | 84,675 |
| NFT refund, one token | 69,486 |
| NFT setLaunchTargets | 143,574 |
| NFT release | 101,449 |
| Regular Bag seal, one token | 370,986 |
| Regular spin, one mature Bag / mock oracle | 569,895 |
| Holder Genesis spin / mock oracle | 422,197 |
| Draw | 268,298–317,680 |
| Choose keep | 102,507–223,984 |
| Withdraw ETH credit | 45,072 |
| Curator discount proposal / mock Intake | 1,079,014 |
| Curator successful discount execution | 76,861 |
| Maximum 32-Bag / 128-pool snapshot request | 8,279,235 |
| Draw from that 32-Bag snapshot | 415,600 |

Proposal gas includes the mock storing the complete request body and is not a live Intake fee or gas
quote. Every attestation callback tested fits the protocol stipend. Gas report deployment costs of
zero from Foundry's dynamic test linking are deliberately not treated as real deployment estimates.

| Production contract | Runtime bytes | Initcode bytes (before arguments) |
|---|---:|---:|
| GoblinNFT | 20,352 | 21,044 |
| BagGacha | 21,670 | 22,608 |
| GenesisVault | 5,347 | 5,965 |
| Curator | 16,792 | 18,323 |
| TwapOracle | 6,870 | 7,295 |
| POLManager | 5,569 | 6,354 |

All fit runtime/initcode limits and have no external library link placeholders. Rebuild bytecode
from the final authorized launch configuration; do not use artifacts from the other compiler mode.

## Known issues, assumptions and operational responsibilities

- Protected compiler-file change remains outstanding; the imported-launch check is not satisfied
  merely by the successful process-local override checks.
- A missing VRF answer permanently locks the pending draw and listed-Bag exits. No refund/reroll,
  wrapper migration or administrative rescue was added. Independent review must explicitly assess
  this inherited tradeoff before funding the gacha.
- Oracle correctness depends on its panel and attester key. Bounds constrain approved actions;
  they do not make a compromised attester truthful. Signer, action and Intake are immutable to
  honor “no gacha owner”; protocol migration requires a separately reviewed replacement system.
- Mainnet pool/wrapper behavior, worst-case real observation traversal, real oracle request-body
  acceptance and POLManager swap/LP paths remain unverified against live deployments. Local mocks
  and conformance vectors are not a substitute for these checks.
- The whole-wei retention policy permanently keeps division remainders, zero-supply deposits and
  refunded tokens' unclaimed revenue. A holder should claim revenue before refunding. There is no
  administrative sweep. Forced unsolicited ETH similarly has no withdrawal route.
- Pool balances/active virtual reserves are screening criteria, not guaranteed executable depth.
  Rebasing, upgradeable malicious or transfer-blocking assets can still break token delivery and
  must be excluded by curation. Pauses affect future admission/snapshots, not already committed wins.
- Pre-sellout reserve and VRF funding is donated, not borrowed from mint escrow. Free spins need released NFT escrow,
  platform-token inventory and funded VRF budget. There is no automatic replenishment guarantee.
- Holder discount changes from 3% to 5%, and active capacity from 64 to 32, are explicit v2 behavior
  changes. Odds use integer bps and round the maximum relative step down.
- NFT cosmetic reveal remains block-hash based and biasable; economic draws exclusively use VRF.
  No deployment claim is made for the source-only project history.
- Operators must supply the actual existing platform token, team recipient, start times, inventory,
  canonical network contracts and precomputed circular references for any later gacha deployment.
  No guessed values or production placeholder addresses were inserted. README lists every
  constructor, funding action, owner-only NFT setting and permissionless keeper action.
- This is implementation testing, not an independent adversarial audit. No deployment is authorized
  by this report. A separate reviewer should assess the complete bytecode, dependencies, oracle
  policies, funding and launch manifest before money is accepted.

## Exact GoblinNFT launch objective for the next step

> After explicit authorization to edit the protected compiler configuration, set solc 0.8.26,
> optimizer enabled with 200 runs, Cancun, `via_ir = false` and `bytecode_hash = "none"`; rebuild,
> test and independently review the final artifacts. Prepare the separate launch manifest and
> deploy **only `GoblinNFT(address owner_)` on Ethereum mainnet (chain ID 1)**, with
> **`owner_ = $owner` supplied by the launch**. Launch the Goblin Gold / GOBLIN collection with
> 10,000 maximum live NFTs, 0.001 ETH mint price and 20 lifetime mints per address, using its
> built-in refundable mint escrow and day-one holder revenue. Make no token issuance/replacement
> and deploy no gacha, Curator, oracle, GenesisVault or POLManager in that step. Leave release
> targets unset until the actual independently reviewed gacha/POL contracts exist, then let the
> NFT owner name those contracts and expose the full seven-day refund review before release.

The next launch must use the requester's actual owner, never the factory, launch service or an
invented address. The constructor and deploy helper are tested with an explicitly supplied owner.
