// Read the live PositionState from the public positions mapping, and (for open positions)
// simulate earned coverage to block.timestamp the same way the hook's _accrue does:
//   delta = entryNotional * coverageApr * dt / (1e18 * secondsPerYear)   [in-range only]
//
// Settlement CLEARS the struct, so a closed position reads active=false / all-zero — the caller
// (PositionSummary component) then reconstructs entry + payout from event history instead.
import { useEffect, useState } from 'react'
import { readPosition, readPoolConfig, readCurrentTick } from '../lib/rpc.js'

const ONE_E18 = 10n ** 18n

export function usePositionSummary(positionKey, refreshTick) {
  const [data, setData] = useState(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)

  useEffect(() => {
    let cancelled = false
    if (refreshTick === 0) setLoading(true)

    ;(async () => {
      try {
        const [pos, config, slot] = await Promise.all([
          readPosition(positionKey),
          readPoolConfig(),
          readCurrentTick().catch(() => null),
        ])
        if (cancelled) return

        const currentTick = slot ? slot.tick : null
        const inRangeNow =
          pos.active && currentTick != null
            ? Number(pos.tickLower) <= currentTick && currentTick < Number(pos.tickUpper)
            : false

        // Live accrual estimate to "now" for an open position.
        let liveEarned = pos.earnedCoverageStable
        if (pos.active && inRangeNow) {
          const nowSec = BigInt(Math.floor(Date.now() / 1000))
          const dt = nowSec - BigInt(pos.lastAccrualTime)
          if (dt > 0n) {
            const delta =
              (pos.entryNotionalStable * config.coverageApr * dt) / (ONE_E18 * config.secondsPerYear)
            liveEarned = pos.earnedCoverageStable + delta
          }
        }

        setData({
          ...pos,
          currentTick,
          inRangeNow,
          liveEarned,
          coverageApr: config.coverageApr,
          secondsPerYear: config.secondsPerYear,
          minHoldSeconds: config.minHoldSeconds,
        })
        setError(null)
      } catch (err) {
        if (!cancelled) setError(err)
      } finally {
        if (!cancelled) setLoading(false)
      }
    })()

    return () => {
      cancelled = true
    }
  }, [positionKey, refreshTick])

  return { data, loading, error }
}
