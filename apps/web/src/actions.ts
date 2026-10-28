import * as React from 'react'
import { confirmDialog, toast } from '@braedonsaunders/appkit-ui'
import type { CabooseClient } from './api.js'
import type { ComputerHandle } from './useComputer.js'

/** Wake, park and restart, each confirmed or reported the same way wherever it is offered. */
export function useComputerActions(client: CabooseClient, computer: ComputerHandle) {
  const [busy, setBusy] = React.useState<'wake' | 'park' | 'restart' | null>(null)
  const name = computer.status?.settings.name ?? 'The computer'

  async function run(kind: 'wake' | 'park' | 'restart', work: () => Promise<void>, done: string) {
    setBusy(kind)
    try {
      await work()
      toast.success(done)
    } catch (failure) {
      toast.error(failure instanceof Error ? failure.message : String(failure))
    } finally {
      setBusy(null)
      await computer.refresh()
    }
  }

  return {
    busy,
    wake: () => run('wake', async () => { await client.wake() }, `${name} is awake.`),
    park: () => run('park', async () => { await client.park() }, `${name} parked with every app still open.`),
    /** Confirms first: open apps close and unsaved work in them is lost. Returns whether it ran. */
    async restart(beforeRestart?: () => Promise<boolean>): Promise<boolean> {
      const confirmed = await confirmDialog({
        title: `Restart ${name}?`,
        message: 'Open apps close and unsaved work in them is lost. Files and installed apps are kept, and the computer starts fresh from its disk.',
        confirmLabel: 'Restart',
        tone: 'danger',
      })
      if (!confirmed) return false
      if (beforeRestart && !await beforeRestart()) return false
      await run('restart', async () => { computer.setStatus(await client.restart()) }, `${name} restarted.`)
      return true
    },
  }
}
