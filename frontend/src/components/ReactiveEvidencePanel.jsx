// Cross-chain automation status. Honest per docs/reactive-evidence.md: the reactive contract on
// Lasna provably subscribed, tracked, and detected range transitions (verified via on-chain state
// reads + rGas), and the callback *landing* on Sepolia was blocked by a transient testnet
// observation stall — infra, not contracts. We show exactly that, with verifiable tx links.
import { ADDRESSES, ETHERSCAN, REACTSCAN } from '../lib/rpc.js'
import { shortHash } from '../lib/format.js'

const SEPOLIA_PROOFS = [
  {
    label: 'LP deposit → PositionRegistered',
    detail: 'Reactive tracked the position (activeKeys 0→1 on Lasna)',
    tx: '0x69e31cbe8305b9f54a5ba9afac6ba8002202b70a17af69ed4b530fae7c2d9691',
  },
  {
    label: 'In-range swap → TickUpdated + BufferFunded',
    detail: 'Buffer skim on a real trade',
    tx: '0x57083e0d3defe89e99d3e3e43936e7416723483238b41a9279902f1a24d32421',
  },
  {
    label: 'Swap crosses out → TickUpdated',
    detail: 'Reactive flipped lastKnownInRange true→false, dispatched callback (rGas charged)',
    tx: '0x775a66d9ea842b3f8d1c3a712def4dcfa160435b7ca16c0a13ffdd36e630e25a',
  },
  {
    label: 'Swap crosses back → TickUpdated',
    detail: 'Reactive flipped lastKnownInRange false→true, dispatched callback (rGas charged)',
    tx: '0x3c385b2c6060edcfa630d59ac15c0519da723cd34f4317c5eeda1c3acd63380a',
  },
  {
    label: 'Full withdrawal → PartialPayout + PositionClosed',
    detail: 'Three-cap settlement (COVERAGE_CAP) + CEI payout',
    tx: '0x3dbc8b6630bbde937f8b6e41641c69e2ff62c6bbad1efd7fa508f2ebf513b515',
  },
]

function Link({ href, children }) {
  return (
    <a
      href={href}
      target="_blank"
      rel="noreferrer"
      className="font-mono text-[11px] text-slate-400 hover:text-guard-400"
    >
      {children} ↗
    </a>
  )
}

export default function ReactiveEvidencePanel() {
  return (
    <section className="rounded-2xl border border-ink-600 bg-ink-800/60 backdrop-blur p-5">
      <div className="flex items-center justify-between">
        <h3 className="text-sm font-semibold text-slate-100">Reactive Network Automation</h3>
        <span className="text-xs text-slate-500">Sepolia ⇄ Lasna</span>
      </div>
      <p className="mt-1 text-[11px] leading-relaxed text-slate-500">
        Coverage accrual is lazy and range-gated; the hook can't watch itself. A contract on the
        Reactive Lasna ReactVM subscribes to the hook's events and dispatches accrual callbacks
        cross-chain — no keeper.
      </p>

      {/* Topology */}
      <div className="mt-4 grid grid-cols-2 gap-2">
        <div className="rounded-xl border border-ink-600 bg-ink-700/40 p-3">
          <div className="text-[11px] text-slate-500">Hook · Sepolia</div>
          <Link href={`${ETHERSCAN}/address/${ADDRESSES.hook}`}>{shortHash(ADDRESSES.hook)}</Link>
        </div>
        <div className="rounded-xl border border-ink-600 bg-ink-700/40 p-3">
          <div className="text-[11px] text-slate-500">Reactive · Lasna</div>
          <Link href={`${REACTSCAN}/address/${ADDRESSES.reactive}`}>
            {shortHash(ADDRESSES.reactive)}
          </Link>
        </div>
      </div>

      {/* Proven round-trip steps */}
      <ul className="mt-4 space-y-2.5">
        {SEPOLIA_PROOFS.map((p) => (
          <li key={p.tx} className="flex items-start gap-2.5">
            <span className="mt-0.5 text-guard-400 text-xs">✓</span>
            <div className="min-w-0">
              <div className="text-xs text-slate-300">{p.label}</div>
              <div className="text-[11px] text-slate-500">{p.detail}</div>
              <Link href={`${ETHERSCAN}/tx/${p.tx}`}>{shortHash(p.tx)}</Link>
            </div>
          </li>
        ))}
      </ul>

      {/* Honest stall note */}
      <div className="mt-4 rounded-xl border border-amber-500/25 bg-amber-500/5 p-3">
        <div className="text-[11px] font-medium text-amber-300">⏳ Known testnet limitation</div>
        <p className="mt-1 text-[11px] leading-relaxed text-slate-400">
          Detection + dispatch are proven on Lasna (state flips + rGas). The final callback{' '}
          <span className="text-slate-300">landing</span> on Sepolia was blocked by a transient
          Lasna→Sepolia log-observation stall (after block ~11005952) — infra, not the contracts.
          Two Omni-fork pitfalls were found and fixed along the way: the obsolete{' '}
          <span className="font-mono">vmOnly</span> check (→ <span className="font-mono">onlySystem</span>) and the
          Callback-Proxy reserve funding model (→ <span className="font-mono">depositTo</span>).
        </p>
      </div>
    </section>
  )
}
