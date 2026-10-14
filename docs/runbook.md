# Goblin Gold v3.4 launch and keeper runbook

This is a source-only delivery. The network's launch operator executes the later launches; this assignment
sends no transactions. Preserve the live GoblinNFT and any existing GOLD token. The full constructor table,
addresses, economic parameters and trust assumptions are in [README](../README.md#launch-runbook).

1. Build with Solidity 0.8.26, optimizer 200, Cancun, `FOUNDRY_VIA_IR=false FOUNDRY_BYTECODE_HASH=none`.
   Compare the artifacts with [build-hashes.json](build-hashes.json). GoldHook's required low address bits remain
   `0x38CC`; its `getHookPermissions()` must match [hook-permissions.json](hook-permissions.json).
2. Launch GOLD + GoldHook through the existing platform flow. Seed full-range liquidity `[-887220, 887220]`
   with more than 1 ETH depth and rounding headroom. The paying wallet retains path-A custody of the remainder.
3. In a later block, execute the **first post-seed dust GOLD swap** and record its timestamp **T1** and receipt.
   Initialization records zero liquidity: seeding alone does not begin the four-hour liquidity history.
4. **Start the keeper now.** The launch operator supplies its gas and GOLD and monitors it. It executes a small
   exact-input GOLD sell through the canonical v4 swap router **at least every 50 minutes**, confirms inclusion,
   and checks `GoldHook.lastObservationTimestamp()` advanced. Set minimum output and deadline appropriate to the
   live price; choose enough input to execute after fees and rounding. Retry failures and alert before the gap
   reaches 60 minutes. Anyone may perform this operation; no new privileged role or contract is introduced.
5. Resolve the gacha-set deployment parameters before launch 2: **startTime >= T1 + 4 hours**, with extra time
   for funding and the seven-day NFT holder review; exact genesisSupply from the recorded remainder; dividend
   budget; requester's team recipient; chain wrapper; and resolved Curator/other contract addresses. Use the
   same intended startTime for BagGacha and GenesisVault. The schedule is an operator responsibility: preflight
   compares the agreed time but cannot infer T1 from an arbitrary supplied timestamp.
6. Launch the gacha set with that profile and constructor table. The paying wallet transfers genesisSupply GOLD
   into GenesisVault. Verify `balanceOf(vault) >= genesisSupply` before activity or naming. Keep the receipt.
   Unsolicited surplus is harmless to preflight, is logged in base units, and does not enlarge emission budgets.
7. Compare the actual deployed BagGacha runtime hash with `GoldHook.GACHA_RUNTIME_CODE_HASH()` and verify the
   artifacts and constructor words for the entire set. Run this simulation before the NFT owner names targets:

   ```sh
   FOUNDRY_VIA_IR=false FOUNDRY_BYTECODE_HASH=none forge script script/CheckLaunch.s.sol:CheckLaunch \
     --fork-url "$RPC" --sig 'run(address,address,address,address,uint256)' \
     "$HOOK" "$GACHA" "$WRAPPER" "$CURATOR" "$START_TIME"
   ```

   WRAPPER comes from the verified Ethereum chain reference (the direct-funding wrapper, not the coordinator);
   CURATOR comes from the resolved launch and START_TIME from step 5. Do not copy these expected values out of
   the contract under test. No private key or `--broadcast` is used. The script checks sufficient funding,
   POL mintEscrow == deployed NFT, POL poolManager == hook poolManager, wrapper/Curator/startTime, vault Curator,
   and a live `spinPrice()` with fee > 0 and total > fee. It simulates naming, full `bindCheck`, and post-review binding.
8. Only after successful simulation, the NFT owner calls `setLaunchTargets(POLManager, BagGacha, BagGacha)`.
   Require real `bindCheck == 0` immediately and repeat checks before review expiry. Holders have seven days to
   review/refund; renaming restarts review. Simulate then submit `bindGacha` at the boundary. Permissionless NFT
   release can occur first, so every structural check must already pass. Pull escrow after release as in README.
9. Keep the 50-minute keeper running throughout operations. Before starting paid/holder/free spins and POL buys,
   verify both the four-hour history and latest swap freshness through real oracle quotes. A missed hour makes
   Genesis and POL unavailable; a fresh successful swap restores a seasoned ring. Before T1 + four hours,
   continued swaps maintain freshness but cannot replace the missing history.
10. Monitor and service permissionless flush, escrow pulls, draw/finalize, claims, and overdue VRF cancellation.
    Regular draws also require a mature, priceable **small-tier** Bag. Without one, only Genesis can draw; if it
    is unavailable the request fails `NothingToDraw` without spending a VRF fee. Never retarget the NFT after
    hook binding: the deployed NFT owner can retarget until release, but hook binding is permanent.

Regular v3 listing policy is 5 ETH liquidity-equivalent depth per side **plus a 1 ETH in-band capital floor**
in released WETH. The payout cap is at most 5% of equivalent depth and at most **1x** released WETH. Tick walks
are bounded at eight crossings per direction; densely initialized pools can still fail closed. Keep this limit
in pool monitoring and Curator review. Validate the whole immutable set before the review freezes it; the
contracts have no owner rescue for a misconfigured launch.
