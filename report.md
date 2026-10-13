# Goblin Gold v3 — work report

Source-only assignment: port the gacha to an IMD Uniswap v4 genesis token. Nothing was deployed or broadcast; the
deployed GoblinNFT (`0xC5d5F314da6d4a433F9BF897a2cC24A537576cB1`) is untouched and its exact source
(launch-1616 commit `dbd66796c56c6df8ab9b5d58686b86ef1111ae5d`, fetched from GitHub and copied byte for byte) now
lives in `src/GoblinNFT.sol`. It differs from v2's source: pre-release revenue is deferred until `release()`.

## What changed

| Area | Change |
|---|---|
| `src/GoblinNFT.sol` | Replaced by the deployed file (deferred revenue); never to change again |
| `src/GoldHook.sol` (new) | Ownerless v4 hook: factory-only initialization of the ETH/GOLD 12500/60 pool, v3-style observation ring with `observe`, 1% ETH hook fee split 50/50 holders/reserve, 90/50/25% buy tax for 30 minutes and 0.5 ETH buy cap for the first hour, ERC6909-claim accounting in the swap path, batched permissionless `flush`, one-time `bindGacha` pinned to BagGacha's runtime code hash + NFT + token match, forwarding of held GOLD to the vault |
| `src/v4/V4Minimal.sol` (new) | ABI-identical shim of the v4 PoolManager surface used by `src/` (no v4 dependency in `src/`) |
| `src/TwapOracle.sol` | Genesis token priced only from GoldHook observations (same windows, staleness and 50 ETH depth bound on v4 active liquidity); v3 pools refused for it |
| `src/POLManager.sol` | Rewritten for the v4 PoolManager unlock callback: exact-input buys with fee-aware TWAP minimum, full-range positions held forever, no router/position manager |
| `src/BagGacha.sol` | Wiring moved from immutables to constructor-set storage so every deployment has identical runtime code (needed for the hook's pin); logic unchanged |
| Tests | `GoldHook.t.sol` (13 unit/fuzz tests against the real vendored PoolManager), `GoldHook.invariant.t.sol` (fee ledger invariant), `GoblinNFTDeployed.t.sol` (deferred-revenue semantics), `MainnetV4Fork.t.sol` (live PoolManager + deployed NFT), v2 suites adapted to the deployed NFT and the new constructors |
| `test/v4-core/` | Uniswap v4-core (`main` on 2026-10-13, package 1.0.2) vendored as ordinary files for tests only, plus solmate `Owned` and the v4 test routers; licences included |

## Checks run (2026-10-13)

| Check | Result |
|---|---|
| `FOUNDRY_VIA_IR=false FOUNDRY_BYTECODE_HASH=none forge build/test` | pass, 113 tests, 2 fork tests skipped |
| `forge build/test` with the protected `foundry.toml` (`via_ir = true`) | pass, 113 tests |
| `forge test` with `FOUNDRY_FUZZ_SEED=0x5a34eb6b…b7d8` under the launch profile | pass |
| `forge fmt --check` | pass |
| `forge test --fork-url https://ethereum-rpc.publicnode.com --match-path "test/fork/*"` | v4 fork test passed against the live PoolManager `0x000000000004444c5dc75cB358380D2e3dE08A90` and the deployed GoblinNFT (initialize as factory, seed, swap, fee accrual, flush into `deferredRevenue`, POLManager add/burn, TWAP after 4 h). The v2 VRF-wrapper fork test had a `vm.prank` ordering bug (the prank was consumed by a view call); fixed and both v2 fork tests pass. The public RPC is not an archive node, so the fork runs at the latest block only |
| `testPinnedGachaRuntimeCodeHash` | the pinned hash `0xa84c1923…9fbc` matches `keccak256(type(BagGacha).runtimeCode)` under the launch profile; under `via_ir = true` the test logs the mismatch and returns, as documented |

Tools run: forge build/test/fmt only. No Slither/Mythril in this environment.

## Design decisions worth reviewing

1. **Runtime-code pin instead of creation-code pin.** A deployed address cannot prove its creation code on chain;
   pinning the runtime code of an immutable-free BagGacha is the checkable equivalent. The hash depends on the exact
   compiler profile; it must be re-pinned after any BagGacha change and before launch 1.
2. **Fee mechanics.** Charges are v4 hook deltas: on the specified side in `beforeSwap` when ETH is specified, on
   the unspecified side in `afterSwap` otherwise; every charge is minted as a currency-0 claim to the hook, so the
   swap path only accounts. `flush()` burns and takes in one `unlock`, then pays the NFT and (once bound) the gacha.
3. **Remainder custody.** If IMD accepts `remainderTo = $contract:GoldHook`, no wallet ever holds the genesis
   supply: the hook forwards it to the verified vault at `bindGacha`. Otherwise the paying wallet transfers it after
   launch 2. Both paths are implemented; the README gives the runbook for each.
4. **Curator protocol addresses.** `Curator` keeps v2's constructor (`intakeV2`, `paymentAsset`, …). The manifest has
   no placeholder for IMD's Intake or token, so those two words are the reference's Ethereum addresses. If literal
   protocol addresses are refused, fold them into constants in a follow-up (the Curator tests use a mock intake).
5. **Genesis depth bound.** 50 ETH per side, as for regular pools. A thinner GOLD pool makes Genesis quotes revert
   and the Genesis lane unavailable, without affecting regular Bags or settlements.

## Open items before any funded step

- Independent adversarial review of GoldHook delta handling, the observation ring and POLManager settlement.
- Confirm with IMD: hook address mining to flags `0x30CC`, factory-initialization inside the launch transaction,
  whether `remainderTo` may be `$contract:GoldHook`, and how launch 2 references the launch-1 token and hook.
- Re-run the fork tests on an archive RPC at a pinned block and re-pin `GACHA_RUNTIME_CODE_HASH` from the final build.
- v2 VRF liveness tradeoff (no reroll, no refund) is unchanged.
