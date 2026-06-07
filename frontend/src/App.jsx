import { useEffect, useMemo, useState } from 'react'
import CoverageReport from './components/CoverageReport.jsx'
import BufferHealthPanel from './components/BufferHealthPanel.jsx'
import PositionSummary from './components/PositionSummary.jsx'
import ReactiveEvidencePanel from './components/ReactiveEvidencePanel.jsx'
import { usePositionEvents } from './hooks/usePositionEvents.js'
import { useBufferHealth } from './hooks/useBufferHealth.js'
import { usePositionSummary } from './hooks/usePositionSummary.js'
import { buildReportRows } from './lib/report.js'
import { healthPct, fmtSecondsAgo, shortHash } from './lib/format.js'
import { ADDRESSES, POOL_ID, DEMO_POSITION_KEY, ETHERSCAN } from './lib/rpc.js'
import { demoRows, demoBuffer, demoSummary } from './lib/demoData.js'

const POLL_MS = 30_000

/* //////////////////////////////////////////////////////////////
                              HEADER
////////////////////////////////////////////////////////////// */

function Shield() {
  return (
    <svg viewBox="0 0 24 24" className="h-8 w-8" fill="none" aria-hidden>
      <path d="M12 2 4 5v6c0 5 3.4 8.5 8 11 4.6-2.5 8-6 8-11V5l-8-3Z" fill="#10b981" />
      <path
        d="M9 12.5 11 14.5 15.5 10"
        stroke="#0a0e14"
        strokeWidth="2"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  )
}

function Header() {
  return (
    <header className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3">
      <div className="flex items-center gap-3">
        <Shield />
        <div>
          <h1 className="text-xl font-semibold text-slate-100 leading-tight">RangeGuard</h1>
          <p className="text-xs text-guard-400">Protect your liquidity. Guard your range.</p>
        </div>
      </div>
      <div className="text-[11px] text-slate-500 sm:text-right space-y-0.5">
        <div>
          Uniswap v4 hook · Sepolia ·{' '}
          <a
            href={`${ETHERSCAN}/address/${ADDRESSES.hook}`}
            target="_blank"
            rel="noreferrer"
            className="font-mono text-slate-400 hover:text-guard-400"
          >
            {shortHash(ADDRESSES.hook)} ↗
          </a>
        </div>
        <div className="font-mono">Pool {shortHash(POOL_ID)}</div>
      </div>
    </header>
  )
}

function LastUpdated({ lastUpdated, now }) {
  const seconds = Math.max(0, Math.floor((now - lastUpdated) / 1000))
  return (
    <div className="flex items-center gap-2 text-[11px] text-slate-500">
      <span className="relative flex h-2 w-2">
        <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-guard-500/60" />
        <span className="relative inline-flex h-2 w-2 rounded-full bg-guard-500" />
      </span>
      Live · polling every 30s · updated {fmtSecondsAgo(seconds)}
    </div>
  )
}

/* //////////////////////////////////////////////////////////////
                          LIVE DASHBOARD
////////////////////////////////////////////////////////////// */

function LiveDashboard({ positionKey }) {
  const [refreshTick, setRefreshTick] = useState(0)
  const [lastUpdated, setLastUpdated] = useState(() => Date.now())
  const [now, setNow] = useState(() => Date.now())

  // 30s data poll
  useEffect(() => {
    const id = setInterval(() => {
      setRefreshTick((t) => t + 1)
      setLastUpdated(Date.now())
    }, POLL_MS)
    return () => clearInterval(id)
  }, [])

  // 1s clock for the "updated Xs ago" label
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), 1000)
    return () => clearInterval(id)
  }, [])

  const { events, loading: eventsLoading, error: eventsError } = usePositionEvents(positionKey, refreshTick)
  const { data: buffer, loading: bufferLoading } = useBufferHealth(refreshTick)
  const { data: summary, loading: summaryLoading } = usePositionSummary(positionKey, refreshTick)

  // Refresh lastUpdated when the first load resolves.
  useEffect(() => {
    if (!eventsLoading) setLastUpdated(Date.now())
  }, [eventsLoading])

  const rows = useMemo(() => buildReportRows(events), [events])

  return (
    <>
      <div className="flex items-center justify-between mt-6">
        <h2 className="sr-only">Live coverage report</h2>
        <LastUpdated lastUpdated={lastUpdated} now={now} />
        <a
          href={`?demo=true`}
          className="text-[11px] text-slate-500 hover:text-guard-400"
          title="Open the simulated full-lifecycle narrative"
        >
          View demo narrative →
        </a>
      </div>

      {eventsError && (
        <div className="mt-3 rounded-xl border border-rose-500/30 bg-rose-500/5 px-4 py-3 text-xs text-rose-300">
          RPC error fetching events: {String(eventsError.message || eventsError)}. Retrying on next
          poll.
        </div>
      )}

      <div className="mt-4 grid grid-cols-1 lg:grid-cols-3 gap-5">
        <div className="lg:col-span-2">
          <CoverageReport rows={rows} loading={eventsLoading} />
        </div>
        <div className="space-y-5">
          <PositionSummary
            data={summary}
            events={events}
            loading={summaryLoading}
            positionKey={positionKey}
          />
          <BufferHealthPanel data={buffer} loading={bufferLoading} />
          <ReactiveEvidencePanel />
        </div>
      </div>
    </>
  )
}

/* //////////////////////////////////////////////////////////////
                          DEMO DASHBOARD
////////////////////////////////////////////////////////////// */

function DemoDashboard() {
  const buffer = {
    ...demoBuffer,
    healthPct: healthPct(demoBuffer.bufferBalanceStable, demoBuffer.targetBufferSize),
  }

  return (
    <>
      <div className="mt-6 rounded-xl border border-amber-500/30 bg-amber-500/10 px-4 py-3">
        <div className="text-sm font-medium text-amber-200">Simulated 45-day lifecycle (Sepolia fork)</div>
        <div className="text-xs text-amber-200/70 mt-0.5">
          Illustrative coverage story from <span className="font-mono">RangeGuardDemo.s.sol</span>. This
          is NOT live data — remove <span className="font-mono">?demo=true</span> from the URL for the
          real on-chain report.
        </div>
      </div>

      <div className="mt-4 grid grid-cols-1 lg:grid-cols-3 gap-5">
        <div className="lg:col-span-2">
          <CoverageReport rows={demoRows} loading={false} simulated />
        </div>
        <div className="space-y-5">
          <PositionSummary simulated positionKey={DEMO_POSITION_KEY} />
          <BufferHealthPanel data={buffer} loading={false} simulated />
          <ReactiveEvidencePanel />
        </div>
      </div>
    </>
  )
}

/* //////////////////////////////////////////////////////////////
                               APP
////////////////////////////////////////////////////////////// */

export default function App() {
  const params = useMemo(() => new URLSearchParams(window.location.search), [])
  const demo = params.get('demo') === 'true'
  const positionKey = params.get('positionKey') || DEMO_POSITION_KEY

  return (
    <div className="min-h-full max-w-6xl mx-auto px-4 sm:px-6 py-8">
      <Header />
      {demo ? <DemoDashboard /> : <LiveDashboard positionKey={positionKey} />}

      <footer className="mt-10 pt-5 border-t border-ink-600 text-[11px] text-slate-600 flex flex-col sm:flex-row sm:items-center sm:justify-between gap-2">
        <div>
          RangeGuard · native Uniswap v4 impermanent-loss coverage · funded by dynamic-fee skimming
        </div>
        <a
          href={`${ETHERSCAN}/address/${ADDRESSES.hook}`}
          target="_blank"
          rel="noreferrer"
          className="hover:text-guard-400"
        >
          View hook on Etherscan ↗
        </a>
      </footer>
    </div>
  )
}
