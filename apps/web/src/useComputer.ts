import * as React from 'react'
import { CabooseApiError, type CabooseClient, type ComputerStatus, type ComputersResponse } from './api.js'

const POLL_MS = 5_000

/**
 * Every computer on the host with its management status, polled over HTTP. Polling
 * `GET /v1/computers` holds no lease, so leaving the console open never keeps a computer
 * awake (a control socket would).
 */
export function useComputers(client: CabooseClient, onUnauthorized: () => void) {
  const [list, setList] = React.useState<ComputersResponse | null>(null)
  const [error, setError] = React.useState<string | null>(null)

  const refresh = React.useCallback(async () => {
    try {
      setList(await client.computers())
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

  /** Puts a status a computer route answered with in place, until the next poll. */
  const update = React.useCallback((id: string, status: ComputerStatus) => {
    setList(current => current && {
      ...current,
      computers: current.computers.map(computer => computer.id === id ? { ...computer, ...status } : computer),
    })
  }, [])

  return { list, error, refresh, update }
}

export type ComputersHandle = ReturnType<typeof useComputers>

/** One computer out of the list, in the shape its pages work with. */
export interface ComputerHandle {
  status: ComputerStatus | null
  setStatus: (status: ComputerStatus) => void
  error: string | null
  refresh: () => Promise<void>
}

export function useComputerHandle(computers: ComputersHandle, id: string): ComputerHandle {
  const status = computers.list?.computers.find(computer => computer.id === id) ?? null
  const { update, refresh, error } = computers
  const setStatus = React.useCallback((next: ComputerStatus) => update(id, next), [update, id])
  return { status, setStatus, error, refresh }
}
