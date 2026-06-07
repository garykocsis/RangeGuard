// Fetch + decode every hook event for a given positionKey, with resolved timestamps.
// Re-runs whenever `refreshTick` changes (App polls every 30s).
import { useEffect, useState } from 'react'
import { fetchPositionLogs, fetchBlockTimestamps } from '../lib/rpc.js'
import { decodeHookLog } from '../lib/events.js'

export function usePositionEvents(positionKey, refreshTick) {
  const [events, setEvents] = useState([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState(null)

  useEffect(() => {
    let cancelled = false
    // Only show the full-screen spinner on the very first load, not on background polls.
    if (refreshTick === 0) setLoading(true)

    ;(async () => {
      try {
        const raw = await fetchPositionLogs(positionKey)
        const decoded = raw.map(decodeHookLog).filter(Boolean)

        // Events without their own timestamp field need a block lookup.
        const needBlock = decoded
          .filter((e) => e.args.timestamp == null && e.args.depositTime == null)
          .map((e) => e.blockNumber)
        const blockTs = needBlock.length ? await fetchBlockTimestamps(needBlock) : {}

        const withTs = decoded.map((e) => {
          const own = e.args.timestamp ?? e.args.depositTime
          const ts = own != null ? Number(own) : blockTs[e.blockNumber.toString()]
          return { ...e, timestamp: ts }
        })

        if (!cancelled) {
          setEvents(withTs)
          setError(null)
        }
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

  return { events, loading, error }
}
