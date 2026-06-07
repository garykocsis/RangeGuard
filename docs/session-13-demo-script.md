# Session 13 — Demo Script + Live End-to-End Proof

**Branch:** `feat/demo-script` · **Date:** 2026-06-06/07

This session built the Sepolia fork integration tests, the Option-B live broadcast tooling, and the
Option-A recorded demo script; then drove the live end-to-end round-trip on Sepolia ⇄ Reactive Lasna.
In the process it found and fixed **two** non-obvious Reactive Omni-fork integration blockers.

---

## 1. Opening prompt (verbatim)

> RangeGuard — Session 13: Demo Script + Live End-to-End Proof
> Branch: feat/demo-script (already created — do not create a new branch)
> Mandatory first steps: Read spec.md, context.md, CLAUDE.md, project-status.md; src/RangeGuardHook.sol;
> script/HelperConfig.s.sol; script/DeployRangeGuardHook.s.sol; docs/session-12-reactive-deployment.md;
> src/RangeGuardReactive.sol. After reading, produce a written Session Review before touching any file,
> covering: current deployed state; what the Sepolia fork tests must prove and why; what the live
> broadcast proves that the fork tests cannot; what the demo script does differently from the live
> broadcast; gaps/risks/improvements; additional recommended test cases. Wait for confirmation.
> Do not write closing documents until explicitly prompted at the end of the session.
> First code change: update HelperConfig.s.sol LP_ROUTER_SEPOLIA = 0x0c478…b0a (PoolModifyLiquidityTest),
> SWAP_ROUTER_SEPOLIA = 0x9b6b46…6eee (PoolSwapTest).
> Phase 1 — Sepolia Fork Integration Tests: SepoliaBaseTest + Liquidity/Swap/Checkpoint/Withdraw/EndToEnd,
> bound to the live deployed addresses (do not deploy). Native ETH = currency0; MockUSDC = currency1;
> fee 0x800000; tickSpacing 60; positionKey = keccak256(abi.encode(owner, tickLower, tickUpper, 0)).
> Phase 2 — Live Broadcast (Option B): script/LiveEndToEnd.s.sol + script/LiveWithdraw.s.sol, pre-flight
> reactive pause/rGas checks, reactive callback verification checklist.
> Phase 3 — Option A: script/RangeGuardDemo.s.sol (vm.warp lifecycle, spec §14 narrative).
> Session closer (when prompted): docs/session-13-demo-script.md, docs/demo-run-output.md,
> docs/demo-narrative.md, docs/reactive-evidence.md; update project-status.md, CLAUDE.md, context.md, Makefile.
>
> (Live addresses provided: hook 0xFead…a7C0; PoolId 0x3e2f93…aa61a; MockUSDC 0x04feCef…428CA;
> PoolManager 0xE03A…3543; PoolModifyLiquidityTest 0x0c478…b0a; PoolSwapTest 0x9b6b46…6eee;
> RangeGuardReactive (Lasna) 0xC0e6…B70b; deployer 0x193D…4A1d; Sepolia Callback Proxy 0xc9f3…7bDA.)

---

## 2. Session Review (produced before any code)

**Current deployed state:** hook `0xFead…a7C0` (immutable auth → proxy `0xc9f3…7bDA`); PoolId
`0x3e2f93…aa61a` (ETH/USDC, DYNAMIC_FEE_FLAG, ts 60); MockUSDC `0x04feCef…428CA`; PoolManager
`0xE03A…3543`; reactive `0xC0e6…B70b` (Lasna, chainId 5318007, Cron10, interval 120, 0.05 lREACT);
buffer 10,000 USDC; deployer/owner `0x193D…4A1d`. Config: base 3000 + buffer 1000 = 4000 (0.40%),
coverageApr 0.50e18, A/365F, minHold 300, minCheckpoint 120, IL cap 50%, buffer cap 10%, accrual
ceiling 3×, target buffer 100k.

**What the fork tests must prove (and why):** the live committed config + token wiring behave per
spec on the deployed bytecode — registration/dt0 baseline, per-swap buffer skim and derived fee 4000,
range-gated accrual, the rate limit, the three caps + CEI settlement, and the buffer self-consistency
invariant. A locally-deployed harness hook can't attest to the *live* deployment.

**What the live broadcast proves that fork tests cannot:** the Reactive round-trip — Lasna actually
observing Sepolia events and the Callback Proxy actually delivering callbacks back to the hook
(`msg.sender == proxy`), which can only happen on real chains, not in an isolated fork EVM.

**What the demo script does differently:** Option A runs on a fork with `vm.warp` to compress the
spec-§14 45-day narrative into one clean terminal render; it uses permissionless `checkpoint()` at
transitions (never the `onlyServiceProvider` emit fns) and *simulates* the Reactive callbacks via
print lines.

**Gaps/risks flagged (and resolved):** (1) the hook has **no** spec-§11 view functions → read public
mappings + parse events (carry-in added). (2) v4 keys the position by `sender` = the **router**, not
the deployer → positionKey owner = router and payout → router (Option 1 for fork tests/demo). (3) fork
tests can't inherit `BaseRangeGuardTest` (it deploys a fresh hook) → documented deviation. (4) faucet
address in the prompt was malformed → used the correct one. (5) `vm.store` slot for `bufferBalanceStable`
located + verified (slot 3) rather than guessed.

**Decisions taken with the user:** Option 1 (stock router, owner=router, payout→router) for fork tests
and `RangeGuardDemo`; for the two LIVE scripts only, a minimal standalone **`DemoLPRouter`** that is its
own `unlockCallback` (so it's the position owner) and auto-forwards principal + IL payout to the
deployer EOA inside the same unlock.

**Extra test cases added beyond spec:** fee-override differential, checkpoint monotonicity across an
out-of-range gap, the `CheckpointTooSoon` 119/120 boundary, a reconciled `ClaimSettled` (IL_CAP), and
the seed-conservation invariant asserted on every settling test.

---

## 3. Phase 1 — Sepolia fork integration tests (14 passing)

`forge test --match-path "test/integration/sepolia/*" --fork-url $SEPOLIA_RPC_URL` → **14 passed, 0 failed**.
(Existing non-fork suite remains **278 passed**.)

| Suite | Test | Result |
|---|---|---|
| SepoliaLiquidityTest | `test_Sepolia_WhenInRangeDeposit_RegistersPositionAtDt0Baseline` | ✅ |
| SepoliaSwapTest | `test_Sepolia_WhenBothDirections_FundsBufferAndUpdatesTick` | ✅ |
| SepoliaSwapTest | `test_Sepolia_WhenSwap_BufferSkimMatchesRealizedStableLeg` | ✅ |
| SepoliaCheckpointTest | `test_Sepolia_WhenInRangeCheckpoint_AccruesCoverage` | ✅ |
| SepoliaCheckpointTest | `test_Sepolia_WhenCheckpointTooSoon_Reverts` (119/120 boundary) | ✅ |
| SepoliaCheckpointTest | `test_Sepolia_WhenOutOfRangeCheckpoint_NoAccrual` | ✅ |
| SepoliaCheckpointTest | `test_Sepolia_WhenInRangeThenOut_CoverageMonotonicAndGated` | ✅ |
| SepoliaWithdrawTest | `test_Sepolia_WhenPartialWithdrawal_Reverts` | ✅ |
| SepoliaWithdrawTest | `test_Sepolia_WhenMinHoldNotMet_IneligibleNoPayout` | ✅ |
| SepoliaWithdrawTest | `test_Sepolia_WhenBufferDrained_PartialPayoutBufferCap` (vm.store, slot verified) | ✅ |
| SepoliaWithdrawTest | `test_Sepolia_WhenLongHoldWithIL_ClaimSettledReconciles` (IL_CAP) | ✅ |
| SepoliaWithdrawTest | `test_Sepolia_WhenHeld_SettlesAndCloses` | ✅ |
| SepoliaEndToEnd | `test_Sepolia_FullCoverageLifecycle` (in→out→in + buffer invariant) | ✅ |
| SepoliaDemoRouterTest | `test_Sepolia_DemoRouter_ForwardsPayoutAndPrincipalToDeployer` | ✅ |

---

## 4. Phase 2 — re-runnability note

Each run of `LiveEndToEnd.s.sol` opens a fresh demo position; the pool, buffer, MockUSDC, and the
persistent `DemoLPRouter` survive across runs. MockUSDC is freely mintable; the buffer accumulates.
The wide background-liquidity position is added once and reused. Bump `RUN_SALT` for an overlapping
position. After a run, wait 5 minutes (minHold = 300s) then run `LiveWithdraw.s.sol`. Each execution is
an independent lifecycle. **Mandatory once per hook deploy:** `make fund-hook-proxy` (proxy reserve).

---

## 5. Phase 2 — Option-B live tx hashes

**Sepolia (`LiveEndToEnd` re-run, blocks 11005722–730):** deposit (DemoLPRouter)
`0x69e31cbe8305b9f54a5ba9afac6ba8002202b70a17af69ed4b530fae7c2d9691`; in-range swap
`0x57083e0d3defe89e99d3e3e43936e7416723483238b41a9279902f1a24d32421`; out swap
`0x62f9106e6daf90213b5e0523ba4c47be167cebaecffb30e5990dbdc4b4e9e901`; back-in swap
`0xae215915d1a0939dbabfe91bf735c3ac85301a322fd49cb1bc29ed257b76609d`.

**Diagnostic / fix txs (Sepolia):** ineffective direct hook funding
`0x6f6b694d1e3f7a59a582a6f514acb0189c128ca9d6c7b6007839f729d3ddf5de`; **proxy reserve fix**
`0xc5ff1526f166daa6d6dd9fbbe961919396183a3ead9597f060323921e5b1991b`; fresh out swap
`0x775a66d9ea842b3f8d1c3a712def4dcfa160435b7ca16c0a13ffdd36e630e25a` (blk 11005866); back-in swap
`0x3c385b2c6060edcfa630d59ac15c0519da723cd34f4317c5eeda1c3acd63380a` (blk 11005952); out swap
`0x38abe69cbb56b2180676c9974b926b40de0dabd9367e2379d01028625faa9430` (blk 11005977, observation stalled).

**Settlement (Sepolia):** `LiveWithdraw`
`0x3dbc8b6630bbde937f8b6e41641c69e2ff62c6bbad1efd7fa508f2ebf513b515` →
`PartialPayout` COVERAGE_CAP (IL_covered 1.14 USDC, payout 0.016 USDC) + `PositionClosed`.

**Lasna:** new reactive deploy
`0xd119be4e787f0c0a1dee11b2219c1462626b6a962ed606494fbf15bb5f7fb659` (→ `0x5eb9c8C0…Fee1`); old
reactive failed `react()` "VM only" `0x0077c0a021bf8d3212c21e318b2042f0fc86f9d9b552026c1d0aebbf61d8b5d2`;
old reactive pause `0xda75aef24c1f5dc42fd3ed7dccaf94b159c9d842c50eb60be5ce96eda0868cd4`; lREACT top-up
`0x86410af2781c1893230ce6deadeea336371a4494caf355509a146a8d0110fec3`; new reactive pause
`0xbdd4ea20963da2ce81407658673f4e743148ad91b7022472061424149465ce3f`.

**Live demo positionKey** (DemoLPRouter `0xEA30…1FEa`, demo range, salt 0):
`0x62e2311b3a51692f0f8ce68f4cd03882e163b37aa357431ad14a4f5b41462d88` (used by the frontend to query
the coverage report).

---

## 6. Reactive callback verification checklist

| # | Check | Result |
|---|---|---|
| 1 | `PositionTracked` on Lasna after LP deposit | ✅ reactive `activeKeysLength=1`, position tracked (state read) |
| 2 | `RangeTransitionDetected` (inRange=false) after out-of-range swap | ✅ `lastKnownInRange` true→false; rGas charged (dispatch) |
| 3 | `PositionOutOfRange` on Sepolia from Callback Proxy | ⏳ not landed — testnet observation stall (not contract) |
| 4 | `RangeTransitionDetected` (inRange=true) after back-in swap | ✅ `lastKnownInRange` false→true; rGas charged |
| 5 | `PositionBackInRange` on Sepolia from Callback Proxy | ⏳ not landed — testnet observation stall |
| 6 | `HeartbeatCheckpointFired` on Lasna after Cron10 | ⏳ Cron did not fire during the window |
| 7 | `Checkpointed` on Sepolia from Callback Proxy | ⏳ not landed |
| 8 | `PositionUntracked` on Lasna after PositionClosed | ⏳ (close emitted on Sepolia; observation stalled) |
| 9 | Reactive contract paused after withdrawal | ✅ `pause()` tx `0xbdd4ea20…` (Cron unsubscribed) |

The detection + dispatch half of every range item (1,2,4) is proven on Lasna; the delivery half
(3,5,7) was blocked by the host-chain observation stall described in `reactive-evidence.md` §"the
remaining gap". Two integration blockers were found and fixed en route (see §8).

---

## 7. Demo Script Output

Captured from `forge script script/RangeGuardDemo.s.sol --fork-url $SEPOLIA_RPC_URL` (full lifecycle,
spec-§14 arc, ending in a real `ClaimSettled` / IL_CAP). See also `docs/demo-run-output.md`.

```
============================================================
   RangeGuard - IL Coverage Demo (Sepolia Fork)
   "Protect your liquidity. Guard your range."
============================================================
[Pool Configuration]
  Hook:                  0xFead6CeaD66f86101f0D0fc5A9B97888FA54a7C0
  baseLpFeeBps:          3000 (0.30%)
  bufferBps:             1000 (0.10%)
  totalFee:              4000 (0.40%)
  coverageApr (1e18):    500000000000000000 (50%)
  minHoldSeconds:        300
  minCheckpointInterval: 120
------------------------------------------------------------
[Setup] Pool live + seeded on Sepolia fork
  Buffer balance: 10000.80 USDC (10% of target)
------------------------------------------------------------
[Day 0] LP deposits a mix of ETH + USDC (Case B - price in range)
  Entry notional: 228.38 USDC  |  Range: [$1,800, $2,200]
  PositionRegistered ok
------------------------------------------------------------
[Day 3] Swap: ETH -> USDC (in range)
  BufferFunded +0.01 USDC  |  buffer: 10000.82 USDC
[Day 7] Swap: USDC -> ETH (in range)
  BufferFunded +0.02 USDC  |  buffer: 10000.84 USDC
[Day 12] Swap: ETH -> USDC (in range)
  BufferFunded +0.01 USDC  |  buffer: 10000.86 USDC
[Day 15] Checkpoint
  AccrualUpdated: +4.69 USDC (isInRange: true)  |  total coverage: 4.69 USDC
[Day 18] Large swap: ETH -> USDC crosses tickLower DOWN
  Position is now OUT OF RANGE (tick -204721 < tickLower)
  [Reactive Network] checkpointAndEmitOutOfRange fires on live Sepolia (simulated here)
  BufferFunded +0.14 USDC (buffer grows regardless of range)
[Day 20] Checkpoint
  AccrualUpdated: +0.00 USDC (isInRange: false)  |  total coverage: 4.69 USDC
[Day 22] Large swap: USDC -> ETH crosses tickLower UP
  Position is BACK IN RANGE (tick -200438)
  [Reactive Network] checkpointAndEmitBackInRange fires on live Sepolia (simulated here)
  BufferFunded +0.15 USDC | accrual resumes
[Day 30] Swap: ETH -> USDC (in range, price drifts toward $1,850)
  BufferFunded +0.11 USDC  |  buffer: 10001.26 USDC
[Day 38] Swap: ETH -> USDC (in range)
  BufferFunded +0.03 USDC  |  buffer: 10001.30 USDC
[Day 43] Swap: USDC -> ETH (nudge back in range)
  BufferFunded +0.03 USDC | tick back in range
[Day 45] Checkpoint
  AccrualUpdated: +7.82 USDC (isInRange: true)  |  total coverage: 12.51 USDC
------------------------------------------------------------
[Day 45] LP withdraws the full position
  IL_raw: 4.47 USDC  |  Payout: 2.23 USDC
  Limiting Factor: IL_CAP  |  ClaimSettled ok
------------------------------------------------------------
[Final Summary]
  Fees skimmed:    1.34 USDC
  Paid out:        2.25 USDC
  Buffer balance:  9999.09 USDC (9% of target)
  Buffer retained 99% of the 10,000 USDC seed - coverage is self-funding.
============================================================
```

> Note: demo amounts/outcomes are computed from live fork state (not hardcoded spec numbers), so the
> exact figures and the settlement branch (ClaimSettled vs NoClaim vs PartialPayout) vary with the
> pool's current price. For the recording, run when the live pool sits in-range (~$2,000).

---

## 8. Deviations from plan

1. **Reactive contract redeployed (vmOnly bug).** The Session-12 reactive `0xC0e6…B70b` used the
   pre-Omni `vm = extcodesize(0x8888)==0` ReactVM detection, which is permanently `false` on Lasna
   Omni → `react()`'s `vmOnly` reverted on every event. Fixed `react()` to `onlySystem`; redeployed as
   `0x5eb9c8C0…Fee1` (old one paused/superseded). Tests updated (prank as SYSTEM); 278 pass.
2. **Callback-Proxy reserve funding (the big gotcha).** Callbacks dispatch on Lasna but only land on
   Sepolia if the hook holds a reserve on the Callback Proxy (`depositTo`, not raw balance). Added
   `make fund-hook-proxy` + `make reserves-hook`; documented in CLAUDE.md, `LiveEndToEnd.s.sol`
   pre-flight, and `reactive-evidence.md`.
3. **`LiveEndToEnd` checkpoint step is eligibility-guarded** — in one broadcast bundle `dt < 120`, so
   a direct `checkpoint()` would revert `CheckpointTooSoon`; it is skipped in-bundle with a note (the
   Cron heartbeat is the real driver).
4. **Live round-trip not fully closed** — after both fixes the reactive dispatched correctly, but a
   transient Lasna→Sepolia observation stall (after Sepolia block ~11005952) prevented a callback from
   landing. Documented as a testnet infrastructure issue in `reactive-evidence.md`.
5. **Settlement on the live withdrawal was `PartialPayout`/COVERAGE_CAP** (not `ClaimSettled`) because
   no reactive checkpoints accrued extra coverage (delivery stall), so earned coverage was the binding
   cap — the correct outcome given the circumstances.

---

## 9. Demo-recording prep — `ResetPoolTick.s.sol`

**Why it exists.** The live broadcast, the diagnostic swaps, and the in→out→in transition dance all
moved the **real** Sepolia pool price. By the end of the session the pool tick sat at **-201257** —
inside the demo range `[-201420, -199320]` but pressed right up against `tickLower` (~163 ticks of
room down, ~1937 up). `RangeGuardDemo.s.sol` opens its position at whatever the live tick is and then
swaps both ways; starting from a boundary makes the "in-range" swaps cross out and breaks the scripted
narrative (this is exactly what broke 3 fork tests mid-session until their IL swaps were flipped to
swap *up*). For a clean recording the pool needs to start **centred at ~$2,000**.

**What it does.** `script/ResetPoolTick.s.sol` re-centres the pool to `TARGET_TICK = -200340` (~$2,000,
the centre of the demo range) with a **single bounded swap**: it sets `sqrtPriceLimitX96` to the centre
tick's sqrt price, so the swap moves the price toward the centre and **stops exactly there** — the
router refunds the unused input. Direction is chosen automatically: tick below centre → USDC→ETH
(USDC is freely minted and the received ETH is returned to the deployer, so it's ~free); tick above
centre → ETH→USDC with the limit capping how much ETH is spent. If the tick is already within
`TARGET ± 120` it no-ops, and it **reverts unless the final tick is inside the demo range** — so a
bad run can't leave the pool in a worse state for recording.

**Verified (fork dry-run):** `tick before: -201257 → tick after: -200340` (exact centre).

**Usage / Makefile.** `make reset-pool-tick` (broadcasts the single swap). Run it, confirm the printed
`tick after:` is centred, then record `RangeGuardDemo.s.sol`. This is now the first item in the
`docs/demo-narrative.md` **pre-recording checklist**:

```
□ make reset-pool-tick           # tick → ~$2,000 (centre); reverts if not left in range
□ confirm tick is in range       # script prints "tick after:"; manual: StateLibrary getSlot0
□ forge script script/RangeGuardDemo.s.sol --fork-url $SEPOLIA_RPC_URL -vv
```

**Design note.** A single swap with the price limit set to the target is more robust than a
swap-and-re-check loop: it can't overshoot (the limit halts it at centre), needs exactly one tx, and
its cost is bounded (USDC is minted; ETH spend is capped by the limit). It also makes the demo
**re-recordable** — re-run it any time the live pool drifts.
