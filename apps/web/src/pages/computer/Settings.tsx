import * as React from 'react'
import {
  Alert, AlertDescription, AlertTitle, Button, Input, Select, SettingsRow, SettingsSection, promptDialog, toast,
} from '@braedonsaunders/appkit-ui'
import {
  computeSettingsPatch, effectiveLimits, formatIdleDuration, formatMemoryMb, validateSettingsInput,
  willRequireColdRestart, type CabooseClient, type ComputerSettings,
} from '../../api.js'
import { useComputerActions } from '../../actions.js'
import { idleChoices, isTransitioning, memoryChoices } from '../../state.js'
import type { ComputerHandle } from '../../useComputer.js'
import { TabIntro } from '../../components/common.js'

function same(a: ComputerSettings | null, b: ComputerSettings | null): boolean {
  return Boolean(a && b) && a!.name === b!.name && a!.memoryMb === b!.memoryMb && a!.vcpus === b!.vcpus && a!.idleMs === b!.idleMs
}

/** `onDelete` is absent for the owner's computer, which cannot be deleted. */
export function Settings({ client, computer, onDelete, assignment }: { client: CabooseClient; computer: ComputerHandle; onDelete?: () => Promise<void>; assignment?: React.ReactNode }) {
  const { status } = computer
  const actions = useComputerActions(client, computer)
  const [draft, setDraft] = React.useState<ComputerSettings | null>(status?.settings ?? null)
  const [saving, setSaving] = React.useState(false)
  const [deleting, setDeleting] = React.useState(false)
  const baseline = React.useRef<ComputerSettings | null>(status?.settings ?? null)

  // Follow changes made elsewhere (the iPhone, another tab) unless there are edits in progress here.
  React.useEffect(() => {
    if (!status) return
    setDraft(current => (current === null || same(current, baseline.current) ? status.settings : current))
    baseline.current = status.settings
  }, [status])

  if (!status || !draft) return null

  const limits = effectiveLimits(status)
  const validation = validateSettingsInput(draft, limits)
  const errors = validation.ok ? {} : validation.errors
  const patch = computeSettingsPatch(status.settings, draft)
  const dirty = Object.keys(patch).length > 0
  const needsRestart = willRequireColdRestart(status, draft)
  const update = (changes: Partial<ComputerSettings>) => setDraft(current => (current ? { ...current, ...changes } : current))

  async function save(): Promise<boolean> {
    if (!validation.ok || !dirty) return validation.ok
    setSaving(true)
    try {
      const next = await client.updateSettings(patch)
      baseline.current = next.settings
      computer.setStatus(next)
      setDraft(next.settings)
      toast.success('Settings saved.')
      return true
    } catch (failure) {
      toast.error(failure instanceof Error ? failure.message : String(failure))
      return false
    } finally {
      setSaving(false)
    }
  }

  async function remove() {
    const name = status!.settings.name
    const typed = await promptDialog({
      title: `Delete ${name}?`,
      label: `Its disk and everything on it are deleted. Type the computer's name, ${name}, to confirm.`,
      confirmLabel: 'Delete computer',
    })
    if (typed === null) return
    if (typed !== name) {
      toast.error('The name did not match, so nothing was deleted.')
      return
    }
    setDeleting(true)
    try {
      await onDelete!()
      toast.success(`${name} was deleted.`)
    } catch (failure) {
      toast.error(failure instanceof Error ? failure.message : String(failure))
      setDeleting(false)
    }
  }

  const busy = saving || deleting || actions.busy !== null || isTransitioning(status.state)

  return (
    <div className="max-w-3xl space-y-6">
      <TabIntro
        description="Kept by the host in caboose.json. The name and auto-park apply at once; memory and vCPUs at the next restart."
        actions={
          <div className="flex gap-2">
            <Button variant="ghost" disabled={!dirty || busy} onClick={() => setDraft(status.settings)}>Discard</Button>
            <Button disabled={!dirty || !validation.ok || busy} onClick={() => void save()}>
              {saving ? 'Saving…' : 'Save'}
            </Button>
          </div>
        }
      />

      {status.restartRequired && !dirty ? (
        <Alert variant="warning">
          <AlertTitle>Restart to apply</AlertTitle>
          <AlertDescription>Saved memory or vCPU changes take effect when the computer restarts.</AlertDescription>
        </Alert>
      ) : null}

      <SettingsSection title="Computer">
        <SettingsRow
          title="Name"
          description={errors.name ?? 'Shown on Home in the iPhone app and in this console.'}
          control={
            <Input
              className="w-64"
              value={draft.name}
              maxLength={80}
              aria-invalid={errors.name ? true : undefined}
              onChange={event => update({ name: event.target.value })}
            />
          }
        />
      </SettingsSection>

      {assignment}

      <SettingsSection
        title="Resources"
        description="A memory snapshot keeps the machine it was taken from, so these apply on the next cold boot."
      >
        <SettingsRow
          title="Memory"
          description={errors.memoryMb ?? (status.activeResources ? `Running with ${formatMemoryMb(status.activeResources.memoryMb)}.` : undefined)}
          control={
            <Select
              className="w-40"
              value={String(draft.memoryMb)}
              onChange={event => update({ memoryMb: Number(event.target.value) })}
            >
              {memoryChoices(limits.memoryMb.min, limits.memoryMb.max, draft.memoryMb).map(value => (
                <option key={value} value={value}>{formatMemoryMb(value)}</option>
              ))}
            </Select>
          }
        />
        <SettingsRow
          title="vCPUs"
          description={errors.vcpus ?? (status.activeResources ? `Running with ${status.activeResources.vcpus}.` : undefined)}
          control={
            <Input
              className="w-24"
              type="number"
              inputMode="numeric"
              min={limits.vcpus.min}
              max={limits.vcpus.max}
              step={1}
              value={draft.vcpus}
              aria-invalid={errors.vcpus ? true : undefined}
              onChange={event => update({ vcpus: event.target.valueAsNumber })}
            />
          }
        />
      </SettingsSection>

      <SettingsSection title="Parking">
        <SettingsRow
          title="Park after"
          description={errors.idleMs ?? 'With nothing using it, the computer parks with its memory and wakes on the next open.'}
          control={
            <Select
              className="w-40"
              value={String(draft.idleMs)}
              onChange={event => update({ idleMs: Number(event.target.value) })}
            >
              {idleChoices(limits.idleMs.min, limits.idleMs.max, draft.idleMs).map(value => (
                <option key={value} value={value}>{formatIdleDuration(value)}</option>
              ))}
            </Select>
          }
        />
      </SettingsSection>

      {status.capabilities.restart ? (
        <SettingsSection
          title="Restart"
          description="Starts the computer fresh from its disk: open apps close and unsaved work in them is lost; files and installed apps are kept."
        >
          <SettingsRow
            title={dirty && needsRestart ? 'Save and restart' : 'Restart now'}
            description={dirty ? 'Unsaved changes are saved first.' : undefined}
            control={
              <Button
                variant="destructive"
                disabled={busy || (dirty && !validation.ok)}
                onClick={() => void actions.restart(dirty ? save : undefined)}
              >
                {actions.busy === 'restart' ? 'Restarting…' : dirty ? 'Save and restart' : 'Restart'}
              </Button>
            }
          />
        </SettingsSection>
      ) : null}

      {onDelete ? (
        <SettingsSection
          title="Delete"
          description="Deletes the computer for good: its disk with every file and app on it, its phones' sign-ins and its notifications. Nothing can be recovered."
        >
          <SettingsRow
            title="Delete this computer"
            description={deleting ? 'Waiting for work running on it, then deleting…' : undefined}
            control={
              <Button variant="destructive" disabled={deleting} onClick={() => void remove()}>
                {deleting ? 'Deleting…' : 'Delete computer'}
              </Button>
            }
          />
        </SettingsSection>
      ) : null}
    </div>
  )
}
