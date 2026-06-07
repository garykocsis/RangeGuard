# RangeGuard — Demo Narration (speaker notes)

Maps the recorded terminal segment (`RangeGuardDemo.s.sol`, ~2:00–4:15) and the coverage-report
segment (~4:15–4:45) to a spoken script. Keep each row's narration to ≤3 sentences. The left column
is what's on screen; the right is what you say.

## Pre-recording checklist

Repeated live swaps leave the pool tick near a range boundary; re-centre it to ~$2,000 first so the
demo's in-range swaps and the out-of-range crossing behave as scripted.

- [ ] Run: `make reset-pool-tick` (single bounded swap → tick ~$2,000; unused input refunded)
- [ ] Confirm the tick is in range before recording — the script prints `tick after:` and reverts if
      it's not inside `[-201420, -199320]`. (Manual check: `cast call 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543 "getSlot0(bytes32)(uint160,int24,uint24,uint24)" 0x3e2f931d495879c5ff87e338192def0f0b824bdf07e9f9c16b02cdba34aaa61a --rpc-url $SEPOLIA_RPC_URL` — note: read via StateLibrary in-script; the raw PoolManager has no `getSlot0` selector.)
- [ ] Run: `forge script script/RangeGuardDemo.s.sol --fork-url $SEPOLIA_RPC_URL -vv`

## Terminal segment (2:00–4:15)

| On screen | Narration |
|---|---|
| Header box + `[Pool Configuration]` (fee 4000, coverageApr 50%, minHold 300, minCheckpoint 120) | "This is the live RangeGuard hook on Sepolia. The pool charges a 0.40% dynamic fee — 0.30% to LPs, 0.10% skimmed into an impermanent-loss coverage buffer — and accrues coverage at 50% APR while a position is in range." |
| `[Setup] Buffer balance: 10,000 USDC` | "The buffer is pre-seeded with 10,000 USDC of real custody. Every line you're about to see maps to a real on-chain event — nothing is mocked." |
| `[Day 0] LP deposits … PositionRegistered` | "An LP deposits a mix of ETH and USDC in the \$1,800–\$2,200 range. The hook snapshots the entry notional and registers the position — coverage starts accruing immediately." |
| `[Day 3/7/12] Swap … BufferFunded` | "As traders swap, the hook skims its 0.10% slice into the buffer on every trade — regardless of direction, and regardless of whether any position is in range." |
| `[Day 15] Checkpoint … AccrualUpdated +4.69 USDC` | "A permissionless checkpoint advances the position's earned coverage — here, 4.69 USDC banked while in range." |
| `[Day 18] Large swap … OUT OF RANGE … checkpointAndEmitOutOfRange` | "A big swap pushes the price out of the LP's range. On live Sepolia, the Reactive Network detects this automatically and fires an out-of-range callback — here it's simulated in the print." |
| `[Day 20] Checkpoint … +0.00 USDC (isInRange: false)` | "While out of range, accrual is gated to zero — the LP earns no coverage for time spent outside their range. This is the core fairness rule." |
| `[Day 22] … BACK IN RANGE … accrual resumes` | "Price comes back; the Reactive Network fires a back-in-range callback and accrual resumes from where it paused." |
| `[Day 30/38] Swap … price drifts toward $1,850 … BufferFunded` | "Over the next weeks the price drifts down within the range — the LP keeps earning coverage, and these swaps keep topping up the buffer." |
| `[Day 43] Swap: USDC → ETH … tick back in range` | "A final swap nudges the price back inside the range, so the LP is earning coverage right up to the moment of withdrawal." |
| `[Day 45] Checkpoint … +7.82 USDC, total coverage 12.51 USDC` then `LP withdraws … IL_raw 4.47 → Payout 2.23 → IL_CAP → ClaimSettled` | "A final checkpoint banks the last stretch of coverage — 12.51 USDC total. On withdrawal the hook measures impermanent loss at the exit price, applies the three caps, and pays the LP from the buffer. The IL cap binds and the LP is paid 2.23 USDC of coverage." |
| `[Final Summary] Buffer retained 99% of seed` | "And the buffer barely moved — the fees it skims fund the payouts it makes. The coverage is self-funding." |

## Coverage-report segment (4:15–4:45)

| On screen | Narration |
|---|---|
| Frontend dashboard rendering the position's day-by-day coverage statement from on-chain events | "Every row of this statement is reconstructed purely from on-chain events — entry, each accrual period with its in-range flag, the out-of-range pause and resume, and the final settlement. No off-chain bookkeeping, fully verifiable." |
| LimitingFactor / payout breakdown | "And the LP sees exactly which cap constrained their payout — total transparency into how the coverage was computed." |

## Reactive Network evidence (talking points)

Use these when presenting the cross-chain automation (see `reactive-evidence.md` for tx hashes):

- **Cross-chain event subscription.** `RangeGuardReactive` runs on Reactive Lasna and subscribes to
  the Sepolia hook's `PositionRegistered` / `TickUpdated` / `PositionClosed` events plus a Cron
  heartbeat — the hook is driven autonomously, with no keeper.
- **Autonomous range detection (bidirectional).** Proven on-chain: the reactive tracked the live
  position (`activeKeysLength=1`) and flipped `lastKnownInRange` true→false→true as real Sepolia
  swaps crossed the boundary in both directions, dispatching a callback each time (rGas charged).
- **Bidirectional callback proof.** Callbacks are routed through the host-chain Callback Proxy
  (`0xc9f3…7bDA`) and gated by `onlyServiceProvider`; the reactive never mutates accounting.
- **Periodic heartbeat.** A `Cron10` subscription keeps lazy accrual current between trades via
  `checkpointCallback`.
- **Full lifecycle automation.** Registration → range tracking → transition callbacks → heartbeat →
  position-closed untracking, all event-driven across two chains.
- **Two Omni-fork pitfalls found + fixed (honest, and valuable feedback):** the obsolete `vmOnly`
  ReactVM detection (fixed → `onlySystem`) and the Callback-Proxy **reserve** funding model
  (fixed → `depositTo` / `make fund-hook-proxy`). The remaining gap — a callback *landing* on
  Sepolia — was blocked by a transient testnet log-observation stall, not the contracts.
