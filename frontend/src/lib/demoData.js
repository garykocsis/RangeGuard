// Simulated "Demo Narrative" data — rendered ONLY under ?demo=true and ALWAYS labeled
// "Simulated 45-day lifecycle (Sepolia fork)". This is the fork output from
// docs/demo-run-output.md (RangeGuardDemo.s.sol), used for the recorded coverage-report
// segment (4:15–4:45) so the full IL-coverage story can be shown end-to-end. It is never
// presented as live on-chain data.

// Day 0 anchored so Day 45 lands on ~Jun 06, 2026 (the recording date).
const BASE = Math.floor(Date.UTC(2026, 3, 22) / 1000) // Apr 22, 2026
const day = (n) => BASE + n * 86400

// ReportRow[] — same shape buildReportRows() produces, so <CoverageReport> renders it unchanged.
export const demoRows = [
  {
    key: 'demo-0',
    type: 'open',
    label: 'Position Opened',
    ts: day(0),
    details: 'Entry: 228.38 USDC · Range: $1,800–$2,200',
    coverage: '—',
    tone: 'neutral',
  },
  {
    key: 'demo-15',
    type: 'checkpoint',
    label: 'Checkpoint',
    ts: day(15),
    details: 'In range ✓ · earned 4.69 USDC',
    coverage: '+4.69 USDC',
    tone: 'green',
  },
  {
    key: 'demo-18',
    type: 'outOfRange',
    label: 'Out of Range ⚠',
    ts: day(18),
    details: 'Reactive Network detected tick crossing',
    coverage: 'Paused at 4.69 USDC',
    tone: 'amber',
  },
  {
    key: 'demo-20',
    type: 'checkpoint',
    label: 'Checkpoint',
    ts: day(20),
    details: 'Out of range ✗ · earned 4.69 USDC',
    coverage: '+0.00 USDC',
    tone: 'red',
  },
  {
    key: 'demo-22',
    type: 'backInRange',
    label: 'Back In Range ✓',
    ts: day(22),
    details: 'Reactive Network detected recovery',
    coverage: 'Resumed at 4.69 USDC',
    tone: 'green',
  },
  {
    key: 'demo-43',
    type: 'checkpoint',
    label: 'Checkpoint',
    ts: day(43),
    details: 'In range ✓ · earned 12.51 USDC',
    coverage: '+7.82 USDC',
    tone: 'green',
  },
  {
    key: 'demo-45',
    type: 'settled',
    label: 'Claim Settled',
    ts: day(45),
    details: 'IL: 4.47 USDC · Earned: 12.51 USDC · IL_CAP',
    coverage: '2.23 USDC paid',
    tone: 'green',
  },
]

// Final-state buffer (docs/demo-run-output.md [Final Summary]). Values in 1e6 stable units.
export const demoBuffer = {
  bufferBalanceStable: 9_999_090_000n, // 9,999.09 USDC
  totalSkimmedStable: 1_340_000n, // 1.34 USDC
  totalPaidOutStable: 2_250_000n, // 2.25 USDC
  targetBufferSize: 100_000_000_000n, // 100,000.00 USDC
}

export const demoSummary = {
  active: false, // lifecycle complete (settled)
  closed: true,
  entryNotionalStable: 228_380_000n, // 228.38 USDC
  earnedCoverageStable: 12_510_000n, // 12.51 USDC
  payout: 2_230_000n, // 2.23 USDC
  ilRaw: 4_470_000n, // 4.47 USDC
  limitingFactor: 'IL_CAP',
  tickLower: -201420,
  tickUpper: -199320,
  depositTime: day(0),
  settledTime: day(45),
}
