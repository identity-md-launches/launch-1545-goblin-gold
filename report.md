# Goblin Gold v3.1 — work report

Source-only assignment: two fixes before audit, nothing else. Nothing was deployed or broadcast; `foundry.toml`,
`remappings.txt`, `lib/` and `src/GoblinNFT.sol` are untouched.

## What changed

| Area | Change |
|---|---|
| `src/IMDProtocol.sol` (new) | Compiled-in constants: IMD Intake v2 `0xa43e6F75ee006411F79Ac1C84120606C2330DE82`, IMD token `0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7`, oracle signer, action id. Both addresses match the pinned oracle-consumer reference (Ethereum row) and were verified live on 2026-10-13 through a public RPC: the intake has code and `priceOf(bytes32("oracle.request@oracle-1"), IMD)` returns `500000000000000000`; the token's `symbol()` is `IMD` |
| `src/Curator.sol` | Constructor is `Curator(oracle, genesis, gacha)`; intake and payment token are constants (`INTAKE`, `PAYMENT_ASSET`, `intake()`, `paymentAsset()`), callbacks are accepted from the constant intake only; the question policy names the new 5 ETH per-side bound |
| `src/TwapOracle.sol` | `MIN_LIQUIDITY` 50 → 5 ETH per side for regular v3 pools; genesis pool bound is now `MIN_GENESIS_DEPTH` = 1 ETH on the ETH virtual reserve `L·2^96/√P`; new `valueAndCap` / `payoutCap` (5% of the pool's current ETH-side depth, `PAYOUT_CAP_BPS = 500`); TWAP windows and staleness unchanged |
| `src/BagGacha.sol` | `bagPayout(id)` caps each token of a Bag at its pool cap; snapshots commit capped values and record a `CappedSplit` (epoch-tagged) only where a cap binds; `draw()` splits a capped Bag into a new won Bag id and leaves the remainder listed (`BagSplit` event); Genesis quotes are capped in `_commitGenesis` with the surplus uncommitted back to the vault; zero token lines are skipped on transfer; genesis quoting moved into a helper to stay under the legacy pipeline's stack limit |
| `src/GoldHook.sol` | `GACHA_RUNTIME_CODE_HASH` re-pinned to `0x070f51e4de5f4c7edad282993b737908a0f2764a64f28a60cd9b454a056fafdc` from the final v3.1 `BagGacha` under the launch profile |
| Tests | `PayoutCap.t.sol` (new, 19 tests incl. fuzz): keep/buyback of a split Bag, exact-cap vs one-wei-over boundary, per-token caps, committed splits surviving later depth changes, Genesis cap with vault surplus, free spins, token conservation. `TwapOracle.t.sol`: 4.99/5 ETH regular and 0.99/1 ETH genesis boundaries (unit + fuzz), cap arithmetic, cap reverting where quotes revert. `GoldHook.t.sol`: 0.99/1 ETH genesis boundary and cap on the real vendored PoolManager. `Curator.t.sol`: constants test, impostor intake rejected. Invariant handler gained a cap-changing action. Curator and conformance fixtures etch their mocks at the `IMDProtocol` addresses |
| `README.md` | v3.1 summary, thresholds, payout cap section, Curator constants, runbook with no protocol-address words and both remainder paths spelled out, assumptions |

## Checks run (2026-10-13)

| Check | Result |
|---|---|
| `FOUNDRY_VIA_IR=false FOUNDRY_BYTECODE_HASH=none forge build` / `forge test` with `FOUNDRY_FUZZ_SEED=0x9d6840f9…c235` | pass, 138 tests, 3 fork tests skipped |
| `forge build` / `forge test` with the protected `foundry.toml` (`via_ir = true`), same seed | pass, 138 tests |
| `forge fmt --check` | pass |
| `forge test --fork-url https://ethereum-rpc.publicnode.com --match-path "test/fork/*"` (launch profile) | 3 passed: v4 fork test (live PoolManager `0x000000000004444c5dc75cB358380D2e3dE08A90` + deployed GoblinNFT: initialize as factory, seed, swap, fee accrual, flush into `deferredRevenue`, POLManager add/burn, TWAP after 4 h) and the two v2 fork tests (real v3 pool history with the new 5 ETH bound, real VRF wrapper). Public non-archive RPC, latest block |
| `testPinnedGachaRuntimeCodeHash` | the pinned hash equals `keccak256(type(BagGacha).runtimeCode)` under the launch profile |
| `cast code` / `cast call` on mainnet for the two IMD addresses | code present; `priceOf` = 0.5 IMD; `symbol()` = IMD |

Tools run: forge build/test/fmt and cast only. No Slither/Mythril in this environment.

## Design decisions worth reviewing

1. **Cap applied at request time, not at draw time.** The snapshot already commits values before randomness; the cap
   is read in the same call so that nothing about a payout is decided after the VRF word is known. A depth change
   between request and draw changes neither the value nor the split.
2. **Split instead of forfeiture.** A capped Bag is split into a won Bag (new id, same depositor) and the listed
   remainder, so the existing keep/buyback/claim/withdraw code paths apply unchanged to the won portion and the
   depositor keeps everything above the cap. Dividend shares move pro rata.
3. **Genesis bound on the ETH side only.** The brief asks for a minimum ETH-side depth; the former token-side
   check (valued at the TWAP) was dropped for the genesis pool. The payout cap, also taken from the ETH side, is what
   bounds extraction. Regular v3 pools keep both sides at 5 ETH.
4. **Capped value below 0.3P is not drawable.** A Bag whose capped payout rounds under the small-tier floor is skipped
   in that snapshot (like an unpriceable Bag) rather than paid below the tier floor.
5. **Constants over setters for the IMD addresses**, as the brief asks and as the no-owner design requires; the
   oracle-consumer reference's owner-settable migration path is a documented deviation (unchanged from v2/v3).

## Open items before any funded step

- Independent adversarial review of the split accounting (shares, active-slot handling on buyback of a won portion)
  and of the cap's interaction with the 5% of reserve Bag cap and tier odds.
- The cap is a per-draw bound on extraction from a thin pool, not a liveness or depth guarantee; at the minimum
  depths the caps are 0.25 ETH (regular) and 0.05 ETH (GOLD), so jackpots need deeper pools.
- Confirm with IMD which remainder path (A: paying wallet, B: `$contract:GoldHook`) the manifest accepts.
- Re-run the fork tests on an archive RPC at a pinned block before launch; the v2 VRF liveness tradeoff is unchanged.
