// One row of the coverage report. Renders a normalized ReportRow (live or demo, identical shape).
import { tsToDate, dayLabel } from '../lib/format.js'
import { ETHERSCAN } from '../lib/rpc.js'

const TONE = {
  green: { text: 'text-guard-400', dot: 'bg-guard-400' },
  amber: { text: 'text-amber-400', dot: 'bg-amber-400' },
  red: { text: 'text-rose-400', dot: 'bg-rose-400' },
  neutral: { text: 'text-slate-300', dot: 'bg-slate-500' },
}

const TYPE_BADGE = {
  open: 'bg-sky-500/10 text-sky-300 ring-sky-500/30',
  checkpoint: 'bg-guard-500/10 text-guard-300 ring-guard-500/30',
  outOfRange: 'bg-amber-500/10 text-amber-300 ring-amber-500/30',
  backInRange: 'bg-guard-500/10 text-guard-300 ring-guard-500/30',
  settled: 'bg-violet-500/10 text-violet-300 ring-violet-500/30',
}

export default function EventRow({ row, firstTs }) {
  const tone = TONE[row.tone] ?? TONE.neutral
  const badge = TYPE_BADGE[row.type] ?? TYPE_BADGE.settled

  return (
    <tr className="border-t border-ink-600/70 hover:bg-ink-700/40 transition-colors">
      {/* Date */}
      <td className="px-4 py-3 align-top whitespace-nowrap">
        <div className="text-slate-200 text-sm">{tsToDate(row.ts)}</div>
        {firstTs != null && (
          <div className="text-[11px] text-slate-500 mt-0.5">{dayLabel(row.ts, firstTs)}</div>
        )}
      </td>

      {/* Event */}
      <td className="px-4 py-3 align-top">
        <span
          className={`inline-flex items-center gap-1.5 rounded-full px-2.5 py-1 text-xs font-medium ring-1 ${badge}`}
        >
          <span className={`h-1.5 w-1.5 rounded-full ${tone.dot}`} />
          {row.label}
        </span>
      </td>

      {/* Details */}
      <td className="px-4 py-3 align-top">
        <div className="text-sm text-slate-300">{row.details}</div>
        {row.txHash && (
          <a
            href={`${ETHERSCAN}/tx/${row.txHash}`}
            target="_blank"
            rel="noreferrer"
            className="mt-1 inline-block text-[11px] text-slate-500 hover:text-guard-400 font-mono"
          >
            tx ↗
          </a>
        )}
      </td>

      {/* Coverage earned */}
      <td className={`px-4 py-3 align-top text-right whitespace-nowrap font-mono text-sm ${tone.text}`}>
        {row.coverage}
      </td>
    </tr>
  )
}
