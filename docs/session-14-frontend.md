# Session 14 — Frontend Dashboard (Coverage Report)

**Date:** 2026-06-07
**Branch:** `feat/frontend-dashboard`
**Outcome:** Built the RangeGuard coverage-report dashboard — a React 18 + Vite + Tailwind SPA
(viem, no backend) that renders the LP coverage report from **live Sepolia on-chain events**, plus
a clearly-labeled simulated mode for the recorded demo segment. Build compiles, dev server serves,
and the live data path is verified end-to-end against the deployed hook. Not yet committed/deployed
(pending user review).

---

## Opening Prompt

> The full session-opening prompt, copied verbatim (typos included), per the
> session-13 precedent:

```
RangeGuard — Session 14: Frontend Dashboard
Branch: feat/frontend-dashboard (already created — do not create a new branch)
Mandatory first steps — do not skip, do not write any code until complete:

Read spec.md (Pillar 4, Section 10 event inventory, Section 11 view functions)
Read context.md
Read project-status.md
Read docs/demo-narrative.md
Read docs/demo-run-output.md
Read docs/reactive-evidence.md
After reading all six documents, produce a written Session Review covering:

What the coverage report must show and why it is the key differentiator
Which on-chain events map to which coverage report rows
What the buffer health panel needs to display
What the reactive evidence section needs to show
Any risks or gaps you identify before building


Wait for user confirmation before proceeding past the review

Do not write closing documents until explicitly prompted at the end of the session.

What you are building:
A React + Vite single-page application in frontend/ that renders the RangeGuard coveraort from live Sepolia on-chain events. This is the 4:15–4:45 segment of the recorded demo and the primary LP-facing transparency layer of the protocol.
Deployed to: https://range-guard.vercel.app (Vercel, connected to the main branch of the GitHub repo)

Current deployed state (all live on Sepolia — do not redeploy anything):
Component                          Address
RangeGuardHook                     0xFead6CeaD66f86101f0D0fc5A9B97888FA54a7C0
PoolId                             0x3e2f931d495879c5ff87e338192def0f0b824bdf07e9f9c16b02cdba34aaa61a
MockUSDC (token1)                  0x04feCef5110c5e52794fdA3D935BC2Cc0ee428CA
PoolManager                        0xE03A1074c86CFeDd5C142C4F04F1a1536e203543
DemoLPRouter                       0xEA30a770E6B3C3d30074908Af13b930d6d451FEa
Callback Proxy (Lasna→Sepolia)     0xc9f36411C9897e7F959D99ffca2a0Ba7ee0D7bDA
RangeGuardReactive (Lasna)         0x5eb9c8C021fB3474aA1f2d9EE5f53f6DbA5fFee1
Deployer / owner                   0x193D1F3E085efc80e1027891FaA770E81ECC4A1d
Live demo positionKey: 0x62e2311b3a51692f0f8ce68f4cd03882e163b37aa357431ad14a4f5b41462d88

Tech stack:

React 18 + Vite
Tailwind CSS for styling
viem for Sepolia RPC calls and everies (not ethers.js — viem is the modern standard for v4 ecosystem tooling)
No backend — all data from public Sepolia RPC calls
Deployed on Vercel via GitHub main branch auto-deploy


Project structure:
frontend/
  index.html
  package.json
  vite.config.js
  tailwind.config.js
  src/
    main.jsx
    App.jsx
    hooks/
      usePositionEvents.js    — fetches all hook events for a positionKey
      useBufferHealth.js      — reads poolState public mapping
      usePositionSummary.js   — reads positions public mapping
    components/
      CoverageReport.jsx      — the main coverage report table (KEY DIFFERENTIATOR)
      BufferHealthPanel.jsx   — buffer balance, skimmed, paid out, health %
      PositionSummary.jsx     — entry notional, earned coverage, estimated payout
      ReactiveEvidencePanel.jsx — cross-chain automation status
      EventRow.jsx            — single row in the coverage report table
    lib/
      events.js               — event ABIs + topic0 constants
      formattC formatting, tick→price, timestamp→date
      rpc.js                  — viem client setup (Sepolia public RPC)

Coverage report table — the key differentiator (spec §4 Pillar 4)
Every row maps to a real on-chain event. The table must show:
Date  Event  Details  Coverage Earned
Day 0   Position Opened   Entry: 228.38 USDC | Range: [$1,800–$2,200]   —
Day 15  Checkpoint        In range ✓   +4.69 USDC
Day 18  Out of Range ⚠    Reactive Network detected tick crossing   Paused at 4.69 USDC
Day 20  Checkpoint        Out of range ✗   +0.00 USDC
Day 22  Back In Range ✓   Reactive Network detected recovery   Resumed
Day 43  Checkpoint        In range ✓   +7.82 USDC
Day 45  Claim Settled     IL: 4.47 USDC | Payout: 2.23 USDC | IL_CAP   2.23 USDC

Event → row mapping:

PositionRegistered → Position Opened row
AccrualUpdated → Checkpoint row (show delta, isInRange, earnedCoverageStable)
PositionOutOfRange → Out of Range row (show earnedCoverageAtPause)
PositionBackInRange → Back In Range row (show earnedCoverageAtResume)
ClaimSettled → Claim Settled row (show IL_raw, pay merge with matching AccrualUpdated (same tx, same timestamp)


Buffer health panel:
Read poolState[poolId] public mapping directly (no view functions — they were not implemented in the deployed hook):

bufferBalanceStable — current balance
totalSkimmedStable — cumulative fees collected
totalPaidOutStable — cumulative payouts

Display:
Buffer Health
Balance:   9,999.09 USDC    [████████░░] 10.0%
Target:   100,000.00 USDC
Skimmed:       1.34 USDC (lifetime fees)
Paid out:      2.25 USDC (lifetime payouts)
Compute health % as bufferBalanceStable * 100 / targetBufferSize from poolConfig[poolId].

Position summary panel:
Read positions[poolId][positionKey] public mapping:

Entry notional, deposit time, tick range
Current earnedCoverageStable
active status

Simulate live getEarnedCoverage by computing accrual to block.timestamp in the frontend (same formula as _accrue in the hook — delta = entryNotional * coverageApr * dt / secondsPerYear).

Reactive evidence panel:
Show the cross-cnks to the live explorers:

Sepolia hook: link to Etherscan
Lasna reactive: link to https://lasna-omni.reactscan.net/address/0x5eb9c8C021fB3474aA1f2d9EE5f53f6DbA5fFee1
For each confirmed round-trip from reactive-evidence.md: show the Sepolia tx hash as a clickable Etherscan link
Note on the testnet observation stall — honest, as documented in reactive-evidence.md


Real-time updates:

Poll Sepolia every 30 seconds for new events
Show a "Last updated: X seconds ago" indicator
Show a loading state on first load


Vercel deployment:
After the frontend is built and running locally (npm run dev), configure Vercel:

Framework preset: Vite
Root directory: frontend
Build command: npm run build
Output directory: dist
No environment variables needed — all RPC calls use public Sepolia endpoints

Add a vercel.json in frontend/:
json{
  "rewrites": [{ "source": "/(.*)", "destination": "/index.html" }]
}
After deployment confirm https://range-guard.vercel.app loads and shows the coverage report.

Styling requirementslean, professional — this is a portfolio piece and a demo artifact
Dark theme preferred (easier on screen during recording)
RangeGuard branding: tagline "Protect your liquidity. Guard your range." in the header
Color coding: green for in-range/positive, amber for out-of-range, red for zero accrual
Mobile responsive — not required but nice to have


Critical constraints:

No backend — pure frontend reading public Sepolia RPC
No ethers.js — use viem throughout
Read poolConfig and poolState directly from public mappings — do not call spec §11 view functions (they were not implemented in the deployed hook)
The positionKey 0x62e2311b3a51692f0f8ce68f4cd03882e163b37aa357431ad14a4f5b41462d88 is hardcoded as the demo position — also support a URL parameter ?positionKey=0x... so any position can be viewed
All USDC amounts displayed with 2 decimal places (divide by 1e6)
Timestamps displayed as readable dates (Jun 06, 2026) not Unix timestamps
Tick values converted to prices using 1.0001^tick with decimal r ETH/USDC (token0=ETH 18 dec, token1=USDC 6 dec)


Session closer — do not execute until explicitly prompted:
When prompted:

Update project-status.md — tick frontend checkbox, record Vercel deployment URL
Update CLAUDE.md current session state
Update context.md Section 2 — remove frontend, add recorded demo as final target
Update README.md — add live dashboard link https://range-guard.vercel.app, add demo video link placeholder
Generate docs/session-14-frontend.md with: session review, component architecture decisions, any RPC challenges, Vercel deployment steps, live URL confirmation, and the full opening prompt verbatim

 docs/session-14-frontend.md must include the full opening prompt used for this session copied verbatim under a section titled ## Opening Prompt. This is the same pattern established in session-13-demo-script.md.
```

**Follow-up directive (Option C, given after the Session Review):**

```
Option C. Build the dashboard to render whatever ?positionKey= resolves to from live on-chain
events — honest, sparse, fully verifiable. This is what judges and employers see at
range-guard.vercel.app. For the demo recording segment (4:15–4:45), add a second mode: ?demo=true
that renders a clearly-labeled "Demo Narrative" view populated from the demo-run-output.md fork
data — hardcoded, clearly marked as "Simulated 45-day lifecycle (Sepolia fork)" so it is never
presented as live data. The recording shows the ?demo=true view to tell the full coverage story.
The live URL without the parameter shows the real on-chain data. Both are honest — one is live,
one is clearly labeled as simulated.
```

---

## Session Review (produced before any code, verbatim summary)

Before writing code, all six documents were read **and** the live demo position was queried
on-chain with `cast`. The on-chain ground truth materially differs from the idealized table in
the prompt, which shaped the whole build:

| Check | Live result (hook `0xFead…a7C0`) |
|---|---|
| `positions[poolId][0x62e2…]` | **all zeros, `active=false`** — position already withdrawn/settled; struct cleared |
| `poolState[poolId]` | buffer **10,000.81 USDC**, skimmed **0.82 USDC**, paidOut **0.0164 USDC** |
| `AccrualUpdated` (strict topic2) | **3** events (1 dt=0 baseline + 2 real) |
| `PositionOutOfRange` / `BackInRange` | **0 / 0** |
| `Checkpointed` | **0** |
| `ClaimSettled` | **0** |
| `PartialPayout` | **1** — requested ≈ 1.14 USDC, actual = 0.0164 USDC, factor = **COVERAGE_CAP** |
| `PositionClosed` | **1** |

**Conclusions carried into the build:**

1. **The coverage report must be reconstructed from event logs, not the live mapping** — settlement
   clears `positions[…]`, so a closed position reads zero. Events are the durable record (exactly
   Pillar 4's premise).
2. **The live story is sparse and ends in PartialPayout/COVERAGE_CAP**, not the idealized
   ClaimSettled/IL_CAP. The rich 45-day narrative is the *fork* output (`RangeGuardDemo.s.sol`),
   not live chain.
3. **No view functions deployed** — read `poolConfig`/`poolState`/`positions` public getters and
   derive fee/health/price client-side.
4. **Reactive transition events never landed on the live hook** (testnet observation stall) — so
   the Out-of-Range / Back-In-Range rows are absent live; the evidence panel must be honest about it.

The five review points (coverage report as differentiator; event→row mapping; buffer panel;
reactive evidence; risks/gaps) were answered in full in the session transcript and drove the
decisions below.

---

## The Option C decision (live vs. demo mode) — and why

The Session Review surfaced the core tension: the live demo position's real on-chain history is
**honest but sparse** (one in-range deposit → tiny accrual → partial payout), while the recorded
demo needs the **full coverage story** (in → out-of-range → back-in → settlement with the IL cap
binding).

The user chose **Option C: build both, clearly separated.**

- **Live mode** (default, or `?positionKey=0x…`): renders whatever the key resolves to from live
  Sepolia events — honest, sparse, fully verifiable. This is what judges/employers see at the
  bare URL.
- **Demo mode** (`?demo=true`): renders a hardcoded narrative from `docs/demo-run-output.md`,
  banner-labeled **"Simulated 45-day lifecycle (Sepolia fork)"**, never presented as live data.
  This is the view shown during the 4:15–4:45 recording segment to tell the complete story.

**Why this is the right call:** both views are truthful; neither misrepresents simulated data as
live. It also makes the dashboard a stronger portfolio piece — it demonstrates the full coverage
UX even when the live position history is thin. The same normalized `ReportRow` shape feeds both
paths, so `CoverageReport`/`EventRow` render them identically with no code duplication.

---

## Component architecture decisions

```
frontend/
  index.html, vite.config.js, tailwind.config.js, postcss.config.js, vercel.json, .gitignore
  public/shield.svg                         — favicon / brand mark
  src/
    main.jsx, index.css                     — entry + Tailwind + dark theme
    App.jsx                                 — URL-param routing, polling, layout; LiveDashboard + DemoDashboard
    hooks/
      usePositionEvents.js                  — fetch + decode all hook events for a positionKey (+ block timestamps)
      useBufferHealth.js                    — poolState + poolConfig.targetBufferSize → health %
      usePositionSummary.js                 — positions mapping + live _accrue simulation to now
    components/
      CoverageReport.jsx                    — the report table (KEY DIFFERENTIATOR); renders ReportRow[]
      EventRow.jsx                          — one normalized row, tone-coded
      BufferHealthPanel.jsx                 — balance / target / skimmed / paid out + health bar
      PositionSummary.jsx                   — entry/earned/payout; reconstructs closed positions from events
      ReactiveEvidencePanel.jsx             — cross-chain status + verifiable tx links + honest stall note
    lib/
      rpc.js                                — viem client (fallback RPCs), addresses, read helpers, log fetching
      events.js                             — hook + PoolManager ABIs (parseAbi), LimitingFactor enum, decode
      format.js                             — USDC, tick→price, timestamps, addresses, health %
      report.js                             — buildReportRows(): events → normalized ReportRow[]
      demoData.js                           — simulated narrative (?demo=true), clearly labeled
```

Key decisions:

- **Normalized `ReportRow` shape** is the seam between data and UI. Both `buildReportRows()` (live)
  and `demoData.js` (simulated) emit it, so the table component is mode-agnostic.
- **`LiveDashboard` / `DemoDashboard` split** in `App.jsx` (rather than conditional hook calls)
  respects the Rules of Hooks — only the mounted dashboard runs its data hooks, so demo mode makes
  zero RPC calls.
- **Single 30s poll tick** owned by `LiveDashboard`, passed as a `refreshTick` dependency to all
  three hooks (instead of three independent intervals). `refreshTick === 0` drives the first-load
  spinner; later ticks refresh silently in the background.
- **Topic-2 log filter.** Every position-scoped hook event carries `positionKey` as the second
  indexed param (topic2), so a single raw `eth_getLogs` with `topics: [null, null, positionKey]`
  fetches the whole lifecycle at once; logs are decoded by topic0 against the hook ABI.
- **Timestamps:** events that carry their own (`AccrualUpdated.timestamp`,
  `PositionRegistered.depositTime`, transition events) use it directly; settlement/close events
  (no timestamp field) get a batched `getBlock` lookup.
- **`dt == 0` accrual rows are skipped** — the registration baseline `_accrue` and any same-second
  touch carry no information and would clutter the statement.
- **Tick → price:** `1.0001^tick × 1e12` (decimal-adjust for token0=ETH 18-dec, token1=USDC 6-dec),
  giving USDC/ETH.
- **`extsload` for the live tick:** the deployed hook exposes no current-tick view, so
  `usePositionSummary` reads PoolManager Slot0 via `extsload` at `keccak256(abi.encode(poolId, 6))`
  (v4 StateLibrary `POOLS_SLOT = 6`), unpacking `sqrtPriceX96(160) | tick(24)`. Used for the
  in-range check and live earned-coverage estimate.

---

## RPC challenges encountered

1. **Position mapping reads return zeros for a settled position.** `afterRemoveLiquidity` clears
   `PositionState` (strict CEI), so `positions[poolId][0x62e2…]` reads all-zero / `active=false`.
   A naive "read the mapping" Position Summary would show a blank 0.00 position. **Fix:**
   `PositionSummary` detects `!active` and **reconstructs** entry notional, range, earned coverage,
   payout, IL, and limiting factor from the **event history** (`PositionRegistered` + the
   settlement event), showing a "Closed · Settled" state. This is the concrete realization of
   Pillar 4 — the report lives in events, not in mutable state.
2. **No view functions on the deployed hook.** Read the public mapping getters directly
   (`poolConfig`/`poolState`/`positions`) and derive everything (fee = base + buffer; health =
   balance × 100 / target; price = `1.0001^tick`).
3. **Current tick has no getter.** Solved via PoolManager `extsload` (Slot0 unpack) — see above.
4. **Public-RPC robustness.** Used a viem `fallback` transport over three public Sepolia endpoints
   (publicnode primary), floored `getLogs` at `DEPLOY_BLOCK = 11_005_000` (the hook's life) instead
   of block 0, and chunked the scan in 9,000-block windows to stay within public-endpoint
   `eth_getLogs` range limits.
5. **`PoolId` typing in viem.** It is a `bytes32` user-value-type; all ABIs declare `bytes32` and
   indexed `poolId`/`positionKey`/`owner` topics line up for decoding.

### MetaMask console noise (not an app error)

When a wallet extension (MetaMask) is installed, the browser console may show benign messages such
as injected-provider announcements or `Failed to connect to MetaMask` from the extension's own
inpage script. **RangeGuard makes no wallet connection** — it is read-only over public RPC and uses
no `window.ethereum`. These messages originate from the extension, not the dashboard, and do not
affect data fetching or rendering. They can be ignored (or avoided by viewing in a profile without
wallet extensions).

---

## Verification (live data path, against deployed hook)

A Node smoke test imported the actual `lib/` modules (DOM-free) and ran them against live Sepolia:

```
=== decoded event names ===
PositionRegistered, AccrualUpdated, AccrualUpdated, PartialPayout, PositionClosed
=== report rows ===
Position Opened          | Entry: 228.69 USDC · Range: $1,790–$2,208  => —
Checkpoint               | In range ✓ · earned 0.02 USDC             => +0.02 USDC
Claim Settled (Partial)  | Requested: 1.14 → Paid: 0.02 USDC · COVERAGE_CAP => 0.02 USDC paid
=== buffer ===
balance 10,000.81  skimmed 0.82  paidOut 0.02  health 10.00%
=== position (live mapping) active: false  entryNotional: 0.00  earned: 0.00
=== current tick: -200340
```

- `dt = 0` baseline accrual correctly collapsed (2 `AccrualUpdated` → 1 checkpoint row).
- Closed position correctly read zero from the mapping and was reconstructed from events.
- `extsload` current tick (-200340) is in range and confirms the StateLibrary slot math.
- `npm run build` compiles clean (~134 kB gzip JS); `npm run dev` serves HTTP 200 with the correct
  title; `/src/main.jsx` transforms.

---

## Two honest notes (live vs. nominal)

1. **Range displays $1,790–$2,208, not $1,800–$2,200.** The UI converts the *actual* on-chain
   tick bounds (`1.0001^tick × 1e12`); tick-spacing rounding lands a few dollars off the nominal
   round numbers. The dashboard shows the truth from chain rather than the marketing figure.
2. **Live settlement is PartialPayout / COVERAGE_CAP / 0.02 USDC**, not the idealized
   ClaimSettled / IL_CAP / 2.23 USDC. The live position earned only ~0.02 USDC of coverage before
   withdrawal, so the **coverage cap** bound the payout (a faithful demonstration of the three-cap
   mechanism). The richer IL_CAP story is shown only under `?demo=true`, labeled simulated.

---

## Vercel deployment

`frontend/vercel.json` adds SPA rewrites:

```json
{ "rewrites": [{ "source": "/(.*)", "destination": "/index.html" }] }
```

Vercel project configuration (no environment variables — all RPC is public Sepolia):

| Setting | Value |
|---|---|
| Framework preset | **Vite** |
| Root directory | **`frontend`** |
| Build command | **`npm run build`** |
| Output directory | **`dist`** |

The Vercel project is connected to the GitHub repo's **`main`** branch (auto-deploy). The live URL
**https://range-guard.vercel.app** updates when this work is merged to `main`.

### Live URL confirmation

- [ ] _To confirm after merge to `main`:_ https://range-guard.vercel.app loads and shows the live
      coverage report (and `?demo=true` shows the simulated narrative). Update this checkbox once the
      Vercel deploy is green.

---

## Modes (summary)

| URL | Mode | Source |
|---|---|---|
| `https://range-guard.vercel.app` | Live | real Sepolia events for the demo positionKey |
| `https://range-guard.vercel.app/?positionKey=0x…` | Live | real Sepolia events for any position |
| `https://range-guard.vercel.app/?demo=true` | Simulated | hardcoded fork narrative, banner-labeled |

---

## Deviations from plan

- **Added files beyond the prompt's structure:** `postcss.config.js` (required by Tailwind),
  `public/shield.svg` (brand mark/favicon), `.gitignore`, `lib/report.js` (the `buildReportRows`
  normalizer — pulled out of `events.js` so the ABI module stays focused), and `lib/demoData.js`
  (the `?demo=true` data, an explicit consequence of the Option C decision).
- **Live data is sparser than the prompt's example table**, by design (Option C) — the live view is
  honest, and the full narrative is the labeled `?demo=true` view.
- **Not yet committed or deployed** — per the user's instruction to write closing docs first and
  review before committing. Vercel will not reflect the dashboard until the branch is merged to
  `main`.

---

## Carry-ins / follow-ups

- **Live URL confirmation** is pending the merge to `main` (checkbox above).
- **Spec §11 view functions remain unimplemented** on the deployed hook (mainnet-hardening item);
  the dashboard reads public mappings and derives everything client-side, so they are not required
  for the frontend — but `getEarnedCoverage` (accrual simulated to `block.timestamp`) would let an
  open position render its live coverage without the client-side `extsload`/simulation.
- **Full README** is intentionally a minimal placeholder for now; the complete write-up lands after
  the demo recording (with the demo video link).
