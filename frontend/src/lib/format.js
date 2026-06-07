// Display formatting: USDC amounts, tick→price, timestamps, addresses.

export const USDC_DECIMALS = 6
const USDC_DIVISOR = 1_000_000

// Format a stable (USDC, 6-dec) amount as a 2-decimal string with thousands separators.
// Accepts bigint | number | string. `sign: true` prefixes a + for non-negative values.
export function fmtUsdc(v, { sign = false } = {}) {
  if (v === null || v === undefined) return '—'
  const bn = typeof v === 'bigint' ? v : BigInt(v)
  const num = Number(bn) / USDC_DIVISOR
  const body = Math.abs(num).toLocaleString('en-US', {
    minimumFractionDigits: 2,
    maximumFractionDigits: 2,
  })
  const prefix = num < 0 ? '-' : sign ? '+' : ''
  return `${prefix}${body}`
}

// Tick -> price in USDC per ETH. token0 = ETH (18 dec), token1 = USDC (6 dec):
// raw price = 1.0001^tick (token1/token0 in raw units); decimal-adjust by 10^(18-6) = 1e12.
export function tickToPrice(tick) {
  return Math.pow(1.0001, Number(tick)) * 1e12
}

export function fmtPrice(price) {
  if (!isFinite(price)) return '—'
  return '$' + price.toLocaleString('en-US', { maximumFractionDigits: 0 })
}

// Render a [tickLower, tickUpper] band as a price range string.
export function fmtRange(tickLower, tickUpper) {
  return `${fmtPrice(tickToPrice(tickLower))}–${fmtPrice(tickToPrice(tickUpper))}`
}

// Unix seconds -> "Jun 06, 2026"
export function tsToDate(ts) {
  if (ts === null || ts === undefined) return '—'
  return new Date(Number(ts) * 1000).toLocaleDateString('en-US', {
    month: 'short',
    day: '2-digit',
    year: 'numeric',
  })
}

// Unix seconds -> "Jun 06, 2026 · 14:32 UTC"
export function tsToDateTime(ts) {
  if (ts === null || ts === undefined) return '—'
  const d = new Date(Number(ts) * 1000)
  const date = d.toLocaleDateString('en-US', { month: 'short', day: '2-digit', year: 'numeric' })
  const time = d.toLocaleTimeString('en-US', {
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
    timeZone: 'UTC',
  })
  return `${date} · ${time} UTC`
}

// Relative-day label from the first event ("Day 0", "Day 15").
export function dayLabel(ts, firstTs) {
  if (ts == null || firstTs == null) return ''
  const days = Math.floor((Number(ts) - Number(firstTs)) / 86400)
  return `Day ${days}`
}

export function shortHash(h, lead = 6, tail = 4) {
  if (!h) return ''
  return `${h.slice(0, 2 + lead)}…${h.slice(-tail)}`
}

export function fmtSecondsAgo(seconds) {
  if (seconds < 5) return 'just now'
  if (seconds < 60) return `${seconds}s ago`
  const m = Math.floor(seconds / 60)
  return `${m}m ${seconds % 60}s ago`
}

// coverageApr is 1e18 fixed-point; render as a percent.
export function fmtApr(apr) {
  if (apr == null) return '—'
  return `${(Number(apr) / 1e16).toFixed(0)}%`
}

// Health percent of target = balance * 100 / target (both 1e6 stable units).
export function healthPct(balance, target) {
  if (!target || BigInt(target) === 0n) return 0
  return (Number(balance) / Number(target)) * 100
}
