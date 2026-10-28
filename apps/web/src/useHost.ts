import * as React from 'react'
import { CabooseApiError, type CabooseClient } from './api.js'
import { errorMessage, useVisibleInterval } from './components/common.js'
import type { HealthStatus, HostInfo } from './host.js'

const HEALTH_POLL_MS = 10_000

/**
 * How the host was started (read once) and how it is doing (polled while the tab is visible).
 * Neither request holds a lease or wakes the computer.
 */
export function useHost(client: CabooseClient, onUnauthorized: () => void) {
  const [info, setInfo] = React.useState<HostInfo | null>(null)
  const [infoError, setInfoError] = React.useState<{ status: number; message: string } | null>(null)
  const [health, setHealth] = React.useState<HealthStatus | null>(null)
  const [healthError, setHealthError] = React.useState<string | null>(null)

  React.useEffect(() => {
    let current = true
    client.host().then(
      value => { if (current) setInfo(value) },
      failure => {
        if (!current) return
        if (failure instanceof CabooseApiError && failure.isUnauthorized) onUnauthorized()
        else setInfoError({ status: failure instanceof CabooseApiError ? failure.status : 0, message: errorMessage(failure) })
      },
    )
    return () => { current = false }
  }, [client, onUnauthorized])

  const refreshHealth = React.useCallback(async () => {
    try {
      setHealth(await client.health())
      setHealthError(null)
    } catch (failure) {
      if (failure instanceof CabooseApiError && failure.isUnauthorized) onUnauthorized()
      else setHealthError(errorMessage(failure))
    }
  }, [client, onUnauthorized])
  React.useEffect(() => { void refreshHealth() }, [refreshHealth])
  useVisibleInterval(() => void refreshHealth(), HEALTH_POLL_MS)

  return { info, infoError, health, healthError }
}

export type HostHandle = ReturnType<typeof useHost>
