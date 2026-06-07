// Buffer health — read from poolState (balance / skimmed / paidOut) + poolConfig.targetBufferSize.
// Health % = bufferBalanceStable * 100 / targetBufferSize.
import { fmtUsdc } from '../lib/format.js'

function Stat({ label, value, sub }) {
  return (
    <div className="flex items-baseline justify-between gap-3">
      <span className="text-xs text-slate-500">{label}</span>
      <span className="font-mono text-sm text-slate-200">
        {value}
        {sub && <span className="text-slate-500 text-xs ml-1">{sub}</span>}
      </span>
    </div>
  )
}

export default function BufferHealthPanel({ data, loading, simulated = false }) {
  const pct = data ? data.healthPct : 0
  const barPct = Math.max(0, Math.min(100, pct))

  return (
    <section className="rounded-2xl border border-ink-600 bg-ink-800/60 backdrop-blur p-5">
      <div className="flex items-center justify-between">
        <h3 className="text-sm font-semibold text-slate-100">Buffer Health</h3>
        <span className="text-xs text-slate-500">IL coverage reserve</span>
      </div>

      {loading && !data ? (
        <div className="mt-4 space-y-3">
          <div className="h-7 w-40 bg-ink-600 rounded animate-pulse" />
          <div className="h-2.5 w-full bg-ink-600 rounded animate-pulse" />
        </div>
      ) : (
        <>
          <div className="mt-3 flex items-end justify-between">
            <div>
              <div className="font-mono text-2xl text-slate-100">{fmtUsdc(data?.bufferBalanceStable)}</div>
              <div className="text-xs text-slate-500">USDC balance</div>
            </div>
            <div className="text-right">
              <div className="font-mono text-lg text-guard-400">{pct.toFixed(1)}%</div>
              <div className="text-xs text-slate-500">of target</div>
            </div>
          </div>

          {/* Health bar */}
          <div className="mt-3 h-2.5 w-full rounded-full bg-ink-600 overflow-hidden">
            <div
              className="h-full rounded-full bg-gradient-to-r from-guard-600 to-guard-400 transition-all"
              style={{ width: `${barPct}%` }}
            />
          </div>

          <div className="mt-4 space-y-2">
            <Stat label="Target" value={`${fmtUsdc(data?.targetBufferSize)} USDC`} />
            <Stat label="Skimmed" value={`${fmtUsdc(data?.totalSkimmedStable)} USDC`} sub="(lifetime fees)" />
            <Stat label="Paid out" value={`${fmtUsdc(data?.totalPaidOutStable)} USDC`} sub="(lifetime payouts)" />
          </div>

          <p className="mt-3 text-[11px] leading-relaxed text-slate-600">
            {simulated
              ? 'Simulated final state. Buffer retained ~99% of the 10,000 USDC seed — coverage is self-funding.'
              : 'Target is the actuarial reserve (100k USDC); a 10k seed reads ~10% and is healthy. Skim > payouts ⇒ self-funding.'}
          </p>
        </>
      )}
    </section>
  )
}
