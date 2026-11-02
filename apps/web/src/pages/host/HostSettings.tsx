import { DashboardPanel } from '../../components/console-ui.js'
import * as React from 'react'

import { Alert, AlertDescription, Button, Input, Label, Select, Spinner, toast } from '@braedonsaunders/appkit-ui'
import { Settings2 } from 'lucide-react'
import { CabooseApiError, type CabooseClient, type HostSettings as Settings } from '../../api.js'
import { errorMessage } from '../../components/common.js'
import { hostSettingsPatch } from '../../host.js'
import type { ComputersHandle } from '../../useComputer.js'

/** The host's name, which phones and the local network see, and the computer its unscoped routes serve. */
export function HostSettings({ client, computers, onUnauthorized }: { client: CabooseClient; computers: ComputersHandle; onUnauthorized: () => void }) {
  const [settings, setSettings] = React.useState<Settings | null>(null)
  const [draft, setDraft] = React.useState({ name: '', defaultComputer: '' })
  const [error, setError] = React.useState<string | null>(null)
  const [saving, setSaving] = React.useState(false)

  const adopt = React.useCallback((next: Settings) => {
    setSettings(next)
    setDraft({ name: next.name ?? '', defaultComputer: next.defaultComputer ?? '' })
  }, [])

  React.useEffect(() => {
    let live = true
    client.hostSettings().then(
      next => { if (live) { adopt(next); setError(null) } },
      failure => {
        if (!live) return
        if (failure instanceof CabooseApiError && failure.isUnauthorized) onUnauthorized()
        else setError(errorMessage(failure))
      })
    return () => { live = false }
  }, [client, adopt, onUnauthorized])

  const patch = settings ? hostSettingsPatch(settings, draft) : {}
  const dirty = Object.keys(patch).length > 0
  const list = computers.list?.computers ?? []

  async function save(event?: React.FormEvent) {
    event?.preventDefault()
    if (!dirty) return
    setSaving(true)
    try {
      adopt(await client.updateHostSettings(patch))
      await computers.refresh()
      toast.success('Host settings saved.')
    } catch (failure) {
      if (failure instanceof CabooseApiError && failure.isUnauthorized) return onUnauthorized()
      toast.error(errorMessage(failure))
    } finally {
      setSaving(false)
    }
  }

  return (
    <DashboardPanel title="Host settings" icon={<Settings2 className="size-4" aria-hidden />}>
      {error ? (
        <Alert variant="destructive"><AlertDescription>{error}</AlertDescription></Alert>
      ) : !settings ? (
        <div className="flex items-center gap-2 text-sm text-fg-muted"><Spinner size={16} />Loading…</div>
      ) : (
        <form className="max-w-xl space-y-4" onSubmit={event => void save(event)}>
          <div className="space-y-1.5">
            <Label htmlFor="host-name">Name</Label>
            <Input id="host-name" value={draft.name} maxLength={80} placeholder={settings.displayName} onChange={event => setDraft(current => ({ ...current, name: event.target.value }))} />
            <p className="text-xs text-fg-muted">What phones and the local network call this host. Left empty, it is called “Caboose on” its machine's name.</p>
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="host-default-computer">Default computer</Label>
            <Select id="host-default-computer" value={draft.defaultComputer} onChange={event => setDraft(current => ({ ...current, defaultComputer: event.target.value }))}>
              <option value="">None</option>
              {list.map(computer => <option key={computer.id} value={computer.id}>{computer.settings.name}</option>)}
              {draft.defaultComputer && !list.some(computer => computer.id === draft.defaultComputer) ? <option value={draft.defaultComputer}>{draft.defaultComputer}</option> : null}
            </Select>
            <p className="text-xs text-fg-muted">The computer the host's own routes and the owner token open when no computer is named.</p>
          </div>
          <div className="flex gap-2">
            <Button type="submit" disabled={!dirty || saving}>{saving ? 'Saving…' : 'Save'}</Button>
            <Button type="button" variant="ghost" disabled={!dirty || saving} onClick={() => adopt(settings)}>Discard</Button>
          </div>
        </form>
      )}
    </DashboardPanel>
  )
}
