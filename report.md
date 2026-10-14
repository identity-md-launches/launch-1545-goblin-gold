# Goblin Gold v3.4 — audit 1f9510eb repair report

Source-only repairs against commit `170070d52968fc43f73cf54c7a535917a31b78da`, preserving the existing design.
The [audit](https://github.com/Identity-md/research/blob/main/jobs/1f9510eb-0355-4d2a-8bb7-cf1b35b6a096/files/AUDIT.md)
contains two executable proofs plus written reproductions for the other findings. Both executable proofs were
adapted into permanent tests; every written reproduction now has success/failure regression coverage.
Nothing was deployed, broadcast, installed or re-minted. The deployed NFT source, protected build configuration,
dependencies and remappings are unchanged. No production address or recipient was invented.

## Repairs and evidence

| Finding | Repair | Permanent evidence |
|---|---|---|
| 1 High: odds escalation | Empty-tier odds move only to the nearest lower populated tier. If small-tier weight is zero, clear the regular snapshot/capped-split epoch and its liability; use Genesis only or revert NothingToDraw before paying VRF | `test/audit1f9510eb/OddsEscalation.t.sol`: original 0.059 ETH Bag attack now reverts; reserve/credits/VRF stay unchanged; Genesis fallback has no regular liability; all tier subsets fuzzed, large odds <= 700 |
| 2 Medium: dust tick | Walk at most eight initialized crossings each direction; carry min(L, max(0, L +/- liquidityNet)); skip exact-price boundaries after applying a reverse crossing when necessary; discard unvisited tail | Original `DustTick.t.sol` proofs pass (one dust position retains >=50%, parked tick stays live); both slot0 representations, negative ticks, zero-depth side of a boundary; `BandScale.t.sol` covers oracle liveness, signed net changes and read budget |
| 3 Medium: POL wires | Add mintEscrow and poolManager to IHookPOL and the shared GachaMismatch gate; explicitly mirror checks before preflight naming | `LaunchPreflight.t.sol`: actual POL deployments with wrong escrow/manager fail preflight and binding before/after review; `testBindCheckChecksEveryWireWithoutWaitingForReview` extended with both getters |
| 4 Low: band scaling | Require at least 1 ETH unscaled WETH released in the walked band in addition to the 5 ETH liquidity-equivalent threshold; cap payout at min(5% of equivalent depth, 1x released WETH); update Curator policy | `BandScale.t.sol`: auditor's ~0.25 ETH capital pool rejected even with donations; boundary/rounding and both token orders; fuzzed caps bounded by released capital |
| 5 Low: Genesis liveness | README and dedicated runbook require startTime >= first post-seed swap + 4 hours, plus an operator-funded keeper dust GOLD swap every <=50 minutes | `GenesisDark.t.sol`: T1+4h-1 fails despite fresh swaps; exact boundary succeeds; stale oracle/Genesis/POL recover after keeper swap |
| 6 Low: funding grief | Preflight rejects only balance < genesisSupply; console logs surplus in token base units | Exact balance and one-wei donation pass; one-wei deficit fails before naming; no vault impersonation to remove surplus |
| 7 Low: VRF / constructor words | Preflight takes independent expected wrapper, Curator and startTime arguments; checks vault Curator too; calls spinPrice and requires fee >0 and total >fee | Wrong/missing wrapper, live quote failure, zero fee, total <=fee and mismatched expected words all fail before naming |
| Launch identity | Re-pin BagGacha runtime under the launch profile; keep REQUIRED_FLAGS 0x38CC | `testPinnedGachaRuntimeCodeHash`, full 14-field core hook-permission test, v4 integration |

The regular settlement fixtures now include small-tier inventory where required. Tests targeting a specific
large/capped Bag choose a valid mocked VRF word for that branch; independent odds tests exercise arbitrary words
and tier subsets. The existing invariant handlers still run. No production randomness mechanism changed.

## Verification

Compiler: pinned Solidity **0.8.26**, optimizer **200**, EVM **Cancun**.
Launch overrides: **FOUNDRY_VIA_IR=false FOUNDRY_BYTECODE_HASH=none**. The protected default profile remains intact.
All fuzz/invariant runs use the requested seed:
`0x44e199c77c16e387f85689c22588a4b823e5fbf3bb560f5836968f2f2a9cb85c`.

| Check | Result |
|---|---|
| Launch profile `forge build` | Pass |
| Launch profile seeded `forge test` | **226 passed, 0 failed, 2 fork-only suites skipped offline** |
| Protected default profile `forge build` | Pass; final incremental build confirms current sources |
| Protected default profile seeded `forge test` | **226 passed, 0 failed, 2 fork-only suites skipped offline** |
| Launch profile mainnet fork, block **26,190,197**, `--match-path 'test/fork/*' -vv` | **3 passed, 0 failed**: canonical v3 pricing/depth, real VRF wrapper request/callback routing, live v4 PoolManager and deployed NFT |
| `forge fmt --check`, `git diff --check` | Pass |
| Launch artifact hashes, library links, runtime sizes, all 14 hook permission bits | Pass; no external links, every launch runtime <24,576 bytes, flags **0x38CC** |
| Protected paths and `src/GoblinNFT.sol` | Unchanged |

The 28 new audit regression tests all pass under both profiles, including the exact-price reverse-crossing
edge cases found during implementation review. Fork RPC: `https://ethereum-rpc.publicnode.com`. Its older
historical state at block 26,189,273 was unavailable, so verification used the available newer block above.
No tests contain RPC URLs, environment reads/writes, FFI or broadcast calls. Launch and default artifacts were
kept in separate output/cache directories during final checks; the compiler settings were not changed on disk.

## Artifact hashes and sizes

The complete creation/runtime hash inventory, including internal-only library artifacts and the unchanged NFT,
is in [docs/build-hashes.json](docs/build-hashes.json). Hashes are keccak256 of the compiled launch-profile bytes.
Creation hashes exclude ABI constructor arguments. Runtime hashes for contracts with immutables are compiler
**template** hashes: the actual deployed hash depends on constructor values. BagGacha has no immutables, so its
runtime hash is the exact deployable binding pin. No external library links exist.

`GACHA_RUNTIME_CODE_HASH = 0xb1a5cbbca856aef754bdb7d19c2d81b8599e14ee88c3084ffb55f6c6adeb490a`.

| Contract | Creation bytes | Runtime bytes | Creation hash | Runtime template hash |
|---|---:|---:|---|---|
| BagGacha | 23,854 | 23,205 | `0x8e18a600b12228c883a3a00a4cc1c623bdeae565ec72717535052c6caf17f5f9` | `0xb1a5cbbca856aef754bdb7d19c2d81b8599e14ee88c3084ffb55f6c6adeb490a` |
| Curator | 18,061 | 16,723 | `0xcc0f02de17d4b3ea0566a992c3cf94a6e0a0ca43a833cbd862034517ed9445c4` | `0x81b60fed9741b919304fc14adde48f787730c34f8cb891581a764dd09a6f168f` |
| GenesisVault | 5,965 | 5,347 | `0x1281442881bbf4125cd82b54f4384243735a01efb1227931160c8c11003804e2` | `0x2694ca36ef5efb3befbd5b0faf1ed4e0eeca21379aef1bdc8ead4ccf5967a9f6` |
| GoblinNFT | 21,345 | 20,653 | `0x683d478f3ebd55b67c27bb639c8388883d1afa925e6427e050f5fe7cdd7f2d08` | `0x270daf73d98f9a0aab6b102e725ad745edb2412306782d222e1cf495c6951f85` |
| GoldHook | 14,729 | 14,265 | `0x1513e8dd8d2bd2b3196d6dadf420c4f64d6e2818e54762b4f958d540b980bee6` | `0x7dcb9925a8eef7bbbc60af094f368c9c2e7fb0b1f7c15d6e155d0d43a664f6d7` |
| POLManager | 9,579 | 9,000 | `0xd6f258210b771b5e3c2f968c9a7edf208f85364cf7239d4a8e9845845771d8f7` | `0xcd2d03d7cd54bcd7dac8b16fd4d4b91dfc9286827d2baeffc6d174c6e7573cc3` |
| TwapOracle | 13,839 | 13,138 | `0xa362ef8855e56cde800f2a501bba7b20467107d764e3a63247e487290dbbd724` | `0x2fdaedfa66d3efc0e0e32874c4927ae79495da4f4c45ca6e62e7b260a6b5261d` |

Every launch-profile application runtime is below 24,576 bytes. Each internal-only library artifact is 44 runtime bytes;
its creation hash is `0x03f00af6a2c1e216c5142290f5a7c5a73b7dca9ff4182f298fb7a6b46fc82bef` and runtime hash is
`0x324d2f77e170e519647f21af4dd0b9d0c4677a0d6fe8cd1d41c195a62780eeba`. The JSON lists each library by name.
The deployed NFT remains untouched and is not part of any new deployment. The protected default profile is
for compatibility checks only: its unchanged GoblinNFT artifact is 30,889 bytes and must not be deployed.
Under the required launch profile that same source is 20,653 bytes. The six other application runtimes are
also below the limit under the default profile (BagGacha 22,026; Curator 13,820; GenesisVault 5,109;
GoldHook 12,266; POLManager 8,013; TwapOracle 12,269).

## Deployment parameters and operational responsibilities

- Use the existing two-launch flow, with the same deployed GoblinNFT and the same project token. The NFT owner
  names the reviewed targets; no new admin or rescue path was added. No launch manifest was fabricated.
- Resolve team, genesisSupply, dividend budget, startTime and inter-contract references before deployment as in
  the [README constructor table](README.md#launch-2--the-gacha-set). Independently pass the verified chain VRF
  wrapper, resolved Curator and agreed startTime to CheckLaunch; do not derive expected words from the candidate.
- The launch operator records T1 (first later-block post-seed swap), chooses startTime >= T1+4h with review/funding
  headroom, funds and monitors a keeper swap every <=50 minutes, and handles retries. See [docs/runbook.md](docs/runbook.md).
  A timestamp comparison in preflight verifies the agreed parameter, not that the operator chose a live schedule.
- Fund at least genesisSupply before naming. A donation does not increase emission budgets or block preflight.
  Verify artifacts and all wires while the seven-day review still permits corrections; release is permissionless
  and can race binding. The deployed NFT owner can retarget until release, but must not retarget after binding.
- Regular draws need mature, priceable small-tier inventory. Without it the lane is Genesis-only, or unavailable
  if Genesis is unavailable. Curator reviews the explicit liquidity-equivalent threshold and 1 ETH in-band floor.
- The eight-crossing budget intentionally excludes unvisited depth. Many nearby initialized ticks can still
  exhaust it and make a token temporarily unpriceable; depositors retain the existing withdrawal/settlement paths.
  Positive liquidityNet changes never lift credited L. Rounding and the harmonic bound can underestimate depth.
  Caps/TWAPs limit per-request exposure but do not guarantee settlement liquidity or prevent sustained manipulation.
- The wrapper fork proof uses a local coordinator impersonation to test routing, not production proof generation.
  Tests are not a new independent audit; obtain the network's independent adversarial review before funded launch.
  Tools used: Foundry build/test/fmt, read-only RPC/HTTP, and local code/bytecode inspection. Slither/Mythril were not run.
