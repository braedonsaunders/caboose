import * as React from 'react'
import { CabooseApiError, type CabooseClient, type ComputerStatus } from './api.js'

const POLL_MS = 5_000

/**
 * The computer's management status, polled over HTTP. Polling `GET /v1/computer` holds no
 * lease, so leaving the console open never keeps a computer awake (a control socket would).
 */
export function useComputer(client: CabooseClient, onUnauthorized: () => void) {
  const [status, setStatus] = React.useState<ComputerStatus | null>(null)
  const [error, setError] = React.useState<string | null>(null)

  const refresh = React.useCallback(async () => {
    try {
      setStatus(await client.computer())
      setError(null)
    } catch (failure) {
      if (failure instanceof CabooseApiError && failure.isUnauthorized) onUnauthorized()
      else setError(failure instanceof Error ? failure.message : String(failure))
    }
  }, [client, onUnauthorized])

  React.useEffect(() => {
    void refresh()
    const timer = window.setInterval(() => {
      if (document.visibilityState === 'visible') void refresh()
    }, POLL_MS)
    const onVisible = () => { if (document.visibilityState === 'visible') void refresh() }
    document.addEventListener('visibilitychange', onVisible)
    return () => {
      window.clearInterval(timer)
      document.removeEventListener('visibilitychange', onVisible)
    }
  }, [refresh])

  return { status, setStatus, error, refresh }
}

export type ComputerHandle = ReturnType<typeof useComputer>
