// The coverage report table — RangeGuard's key differentiator (spec §4 Pillar 4).
// Every row maps to a real on-chain event. Accepts already-normalized ReportRow[] so it renders
// live (buildReportRows) and simulated (demoData) histories identically.
import EventRow from './EventRow.jsx'

function SkeletonRows() {
  return Array.from({ length: 4 }).map((_, i) => (
    <tr key={i} className="border-t border-ink-600/70">
      <td className="px-4 py-3">
        <div className="h-3 w-24 bg-ink-600 rounded animate-pulse" />
      </td>
      <td className="px-4 py-3">
        <div className="h-5 w-28 bg-ink-600 rounded-full animate-pulse" />
      </td>
      <td className="px-4 py-3">
        <div className="h-3 w-56 bg-ink-600 rounded animate-pulse" />
      </td>
      <td className="px-4 py-3 text-right">
        <div className="h-3 w-16 bg-ink-600 rounded animate-pulse ml-auto" />
      </td>
    </tr>
  ))
}

export default function CoverageReport({ rows, loading, simulated = false }) {
  const firstTs = rows.length ? rows[0].ts : null

  return (
    <section className="rounded-2xl border border-ink-600 bg-ink-800/60 backdrop-blur overflow-hidden">
      <header className="flex items-center justify-between gap-4 px-5 py-4 border-b border-ink-600">
        <div>
          <h2 className="text-base font-semibold text-slate-100">Coverage Report</h2>
          <p className="text-xs text-slate-500 mt-0.5">
            {simulated
              ? 'Day-by-day coverage statement (simulated lifecycle)'
              : 'Day-by-day coverage statement — every row is a real on-chain event'}
          </p>
        </div>
        {simulated ? (
          <span className="shrink-0 rounded-full bg-amber-500/15 text-amber-300 ring-1 ring-amber-500/40 px-3 py-1 text-xs font-medium">
            Simulated
          </span>
        ) : (
          <span className="shrink-0 rounded-full bg-guard-500/15 text-guard-300 ring-1 ring-guard-500/40 px-3 py-1 text-xs font-medium">
            Live · on-chain
          </span>
        )}
      </header>

      <div className="overflow-x-auto">
        <table className="w-full text-left">
          <thead>
            <tr className="text-[11px] uppercase tracking-wider text-slate-500">
              <th className="px-4 py-2.5 font-medium">Date</th>
              <th className="px-4 py-2.5 font-medium">Event</th>
              <th className="px-4 py-2.5 font-medium">Details</th>
              <th className="px-4 py-2.5 font-medium text-right">Coverage Earned</th>
            </tr>
          </thead>
          <tbody>
            {loading && rows.length === 0 ? (
              <SkeletonRows />
            ) : rows.length === 0 ? (
              <tr className="border-t border-ink-600/70">
                <td colSpan={4} className="px-4 py-10 text-center text-sm text-slate-500">
                  No coverage events found for this position yet.
                  <div className="text-xs text-slate-600 mt-1">
                    Once an LP deposits and checkpoints run, the statement populates here.
                  </div>
                </td>
              </tr>
            ) : (
              rows.map((row) => <EventRow key={row.key} row={row} firstTs={firstTs} />)
            )}
          </tbody>
        </table>
      </div>

      <footer className="px-5 py-3 border-t border-ink-600 text-[11px] text-slate-500">
        {simulated
          ? 'Simulated 45-day lifecycle (Sepolia fork) — illustrates the full coverage UX. Not live data.'
          : 'Reconstructed entirely from emitted events — no off-chain bookkeeping. Verify any row on Etherscan.'}
      </footer>
    </section>
  )
}
