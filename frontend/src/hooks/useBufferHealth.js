// Read the pool's buffer accounting from the public poolState mapping (+ target from poolConfig).
// No view functions exist on the deployed hook — we read the mappings directly.
import { useEffect, useState } from 'react'
import { readPoolState, readPoolConfig } from '../lib/rpc.js'
import { healthPct } from '../lib/format.js'

export function useBufferHealth(refreshTick) {
  const [data, setData] = useState(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)

  useEffect(() => {
    let cancelled = false
    if (refreshTick === 0) setLoading(true)

    ;(async () => {
      try {
        const [state, config] = await Promise.all([readPoolState(), readPoolConfig()])
        if (cancelled) return
        setData({
          bufferBalanceStable: state.bufferBalanceStable,
          totalSkimmedStable: state.totalSkimmedStable,
          totalPaidOutStable: state.totalPaidOutStable,
          targetBufferSize: config.targetBufferSize,
          healthPct: healthPct(state.bufferBalanceStable, config.targetBufferSize),
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
  }, [refreshTick])

  return { data, loading, error }
}
