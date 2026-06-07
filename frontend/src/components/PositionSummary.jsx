// Position summary — entry notional, range, earned coverage, and (for closed positions)
// the realized payout / IL / limiting factor.
//
// Live: reads usePositionSummary (positions mapping). Because settlement CLEARS the struct, a
// closed position is reconstructed from event history (PositionRegistered + the settlement event).
import { fmtUsdc, fmtRange, tsToDate, shortHash } from '../lib/format.js'
import { LIMITING_FACTOR, LIMITING_FACTOR_LABEL } from '../lib/events.js'
import { demoSummary } from '../lib/demoData.js'

const SETTLEMENT = ['ClaimSettled', 'PartialPayout', 'NoClaim', 'IneligibleClaim']

function buildLiveVM(data, events) {
  const reg = events.find((e) => e.eventName === 'PositionRegistered')
  const settlement = [...events].reverse().find((e) => SETTLEMENT.includes(e.eventName))
  const lastAccrual = [...events].reverse().find((e) => e.eventName === 'AccrualUpdated')
  const active = !!data?.active

  const earned = active
    ? data.liveEarned
    : (settlement?.args.earnedCoverage ?? lastAccrual?.args.newEarnedTotal ?? null)

  return {
    active,
    found: !!(active || reg),
    entryNotional: active ? data.entryNotionalStable : (reg?.args.entryNotionalStable ?? null),
    tickLower: active ? Number(data.tickLower) : reg ? Number(reg.args.tickLower) : null,
    tickUpper: active ? Number(data.tickUpper) : reg ? Number(reg.args.tickUpper) : null,
    earned,
    inRangeNow: data?.inRangeNow ?? false,
    depositTime: active ? data.depositTime : (reg?.args.depositTime ?? null),
    payout: settlement ? (settlement.args.payout ?? settlement.args.actual ?? null) : null,
    ilRaw: settlement?.args.ilRaw ?? null,
    factor:
      settlement && settlement.args.limitingFactor != null
        ? LIMITING_FACTOR[Number(settlement.args.limitingFactor)]
        : null,
  }
}

function StatusBadge({ active, inRangeNow }) {
  let cls = 'bg-slate-500/15 text-slate-300 ring-slate-500/30'
  let label = 'Closed · Settled'
  if (active && inRangeNow) {
    cls = 'bg-guard-500/15 text-guard-300 ring-guard-500/40'
    label = 'Active · In range'
  } else if (active && !inRangeNow) {
    cls = 'bg-amber-500/15 text-amber-300 ring-amber-500/40'
    label = 'Active · Out of range'
  }
  return (
    <span className={`rounded-full px-2.5 py-1 text-[11px] font-medium ring-1 ${cls}`}>{label}</span>
  )
}

function Row({ label, value, accent = false }) {
  return (
    <div className="flex items-baseline justify-between gap-3 py-1.5">
      <span className="text-xs text-slate-500">{label}</span>
      <span className={`font-mono text-sm ${accent ? 'text-guard-400' : 'text-slate-200'}`}>{value}</span>
    </div>
  )
}

export default function PositionSummary({ data, events = [], loading, simulated = false, positionKey }) {
  let vm
  if (simulated) {
    vm = {
      active: false,
      found: true,
      entryNotional: demoSummary.entryNotionalStable,
      tickLower: demoSummary.tickLower,
      tickUpper: demoSummary.tickUpper,
      earned: demoSummary.earnedCoverageStable,
      inRangeNow: false,
      depositTime: demoSummary.depositTime,
      payout: demoSummary.payout,
      ilRaw: demoSummary.ilRaw,
      factor: demoSummary.limitingFactor,
    }
  } else {
    vm = buildLiveVM(data, events)
  }

  return (
    <section className="rounded-2xl border border-ink-600 bg-ink-800/60 backdrop-blur p-5">
      <div className="flex items-center justify-between">
        <h3 className="text-sm font-semibold text-slate-100">Position Summary</h3>
        {(vm.found || simulated) && <StatusBadge active={vm.active} inRangeNow={vm.inRangeNow} />}
      </div>

      {positionKey && (
        <div className="mt-1 font-mono text-[11px] text-slate-600">{shortHash(positionKey, 8, 6)}</div>
      )}

      {loading && !data && !simulated ? (
        <div className="mt-4 space-y-3">
          <div className="h-6 w-32 bg-ink-600 rounded animate-pulse" />
          <div className="h-4 w-full bg-ink-600 rounded animate-pulse" />
          <div className="h-4 w-2/3 bg-ink-600 rounded animate-pulse" />
        </div>
      ) : !vm.found ? (
        <div className="mt-4 text-sm text-slate-500">
          No position found for this key.
          <div className="text-xs text-slate-600 mt-1">Check the positionKey or try the demo view.</div>
        </div>
      ) : (
        <>
          <div className="mt-3">
            <div className="font-mono text-2xl text-slate-100">
              {vm.earned != null ? fmtUsdc(vm.earned) : '—'}
              <span className="text-sm text-slate-500 ml-1">USDC</span>
            </div>
            <div className="text-xs text-slate-500">
              {vm.active ? 'Earned coverage (live estimate)' : 'Earned coverage (final)'}
            </div>
          </div>

          <div className="mt-4 divide-y divide-ink-600/60">
            <Row label="Entry notional" value={`${fmtUsdc(vm.entryNotional)} USDC`} />
            <Row
              label="Range"
              value={vm.tickLower != null ? fmtRange(vm.tickLower, vm.tickUpper) : '—'}
            />
            <Row label="Opened" value={tsToDate(vm.depositTime)} />
            {!vm.active && vm.ilRaw != null && (
              <Row label="IL measured" value={`${fmtUsdc(vm.ilRaw)} USDC`} />
            )}
            {!vm.active && vm.payout != null && (
              <Row label="Payout" value={`${fmtUsdc(vm.payout)} USDC`} accent />
            )}
            {!vm.active && vm.factor && (
              <Row label="Limiting factor" value={vm.factor} />
            )}
          </div>

          {!vm.active && vm.factor && LIMITING_FACTOR_LABEL[vm.factor] && (
            <p className="mt-3 text-[11px] leading-relaxed text-slate-600">
              {LIMITING_FACTOR_LABEL[vm.factor]} was the binding constraint on this payout.
            </p>
          )}
          {vm.active && (
            <p className="mt-3 text-[11px] leading-relaxed text-slate-600">
              Live estimate accrues only while in range; final payout is computed at withdrawal
              against the three caps.
            </p>
          )}
        </>
      )}
    </section>
  )
}
