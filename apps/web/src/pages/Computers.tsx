import * as React from 'react'
import { DashboardPanel } from '@braedonsaunders/appkit-dashboard/primitives'
import {
  Alert, AlertDescription, AlertTitle, Button, Dialog, Input, Label, PageContainer, PageHeader, Select, toast,
} from '@braedonsaunders/appkit-ui'
import { Monitor, Plus } from 'lucide-react'
import {
  effectiveLimits, formatIdleDuration, formatMemoryMb, validateSettingsInput, type CabooseClient, type ComputersResponse, type Me, type NewComputer, type Person,
} from '../api.js'
import { ComputersTable } from '../components/ComputersTable.js'
import { errorMessage } from '../components/common.js'
import { navigate, routeHref } from '../navigation.js'
import { idleChoices, memoryChoices } from '../state.js'
import type { ComputersHandle } from '../useComputer.js'
import { RollingWordmark } from '../brand/Logo.js'

export function Computers({ client, computers, me }: { client: CabooseClient; computers: ComputersHandle; me: Me }) {
  const { list, error } = computers
  const [creating, setCreating] = React.useState(false)

  if (!list) {
    return (
      <PageContainer>
        {error ? (
          <Alert variant="destructive">
            <AlertTitle>The host could not be reached</AlertTitle>
            <AlertDescription>{error}</AlertDescription>
          </Alert>
        ) : <RollingWordmark label="Loading computers" />}
      </PageContainer>
    )
  }

  const full = list.computers.length >= list.limits.computers

  return (
    <PageContainer>
      <div className="space-y-6">
        <PageHeader
          title="Computers"
          description={list.limits.running
            ? `Each computer is its own Linux machine with its own disk, apps and phones. Up to ${list.limits.running} run at once; the rest stay parked until they are opened.`
            : 'Each computer is its own Linux machine with its own disk, apps and phones.'}
          actions={list.canCreate ? (
            <Button onClick={() => setCreating(true)} disabled={full} title={full ? `This host runs at most ${list.limits.computers} computers.` : undefined}>
              <Plus className="size-4" aria-hidden />New computer
            </Button>
          ) : null}
        />

        {error ? (
          <Alert variant="warning">
            <AlertTitle>Showing the last known status</AlertTitle>
            <AlertDescription>{error}</AlertDescription>
          </Alert>
        ) : null}

        <DashboardPanel title="All computers" icon={<Monitor className="size-4" aria-hidden />}>
          <ComputersTable computers={list.computers} tenants={me.tenants} />
        </DashboardPanel>
      </div>

      <NewComputerDialog
        client={client}
        open={creating}
        list={list}
        me={me}
        onClose={() => setCreating(false)}
        onCreate={async input => {
          const made = await client.createComputer(input)
          await computers.refresh()
          setCreating(false)
          toast.success(`${made.settings.name} is ready. It starts the first time it is opened.`)
          navigate(routeHref({ page: 'computer', id: made.id, tab: 'overview' }))
        }}
      />
    </PageContainer>
  )
}

function NewComputerDialog({ client, open, list, me, onClose, onCreate }: {
  client: CabooseClient
  open: boolean
  list: ComputersResponse
  me: Me
  onClose: () => void
  onCreate: (input: NewComputer) => Promise<void>
}) {
  const template = list.computers[0]
  const limits = effectiveLimits(template)
  const initial = React.useCallback((): NewComputer => ({
    name: '',
    personId: '',
    ...(me.tenants[0] ? { tenantId: me.tenants[0].id } : {}),
    memoryMb: template?.settings.memoryMb ?? 4096,
    vcpus: template?.settings.vcpus ?? 2,
    idleMs: template?.settings.idleMs ?? 600_000,
  }), [template, me.tenants])
  const [draft, setDraft] = React.useState<NewComputer>(initial)
  const [people, setPeople] = React.useState<Person[]>([])
  const [peopleError, setPeopleError] = React.useState<string | null>(null)
  const [peopleLoading, setPeopleLoading] = React.useState(false)
  React.useEffect(() => {
    let active = true
    setPeople([]); setPeopleError(null)
    if (!open || !draft.tenantId) { setPeopleLoading(false); return }
    setPeopleLoading(true)
    client.people(draft.tenantId).then(
      result => { if (active) { setPeople(result.people); setPeopleLoading(false) } },
      failure => { if (active) { setPeopleError(errorMessage(failure)); setPeopleLoading(false) } },
    )
    return () => { active = false }
  }, [client, draft.tenantId, open])
  const [saving, setSaving] = React.useState(false)
  const [touched, setTouched] = React.useState(false)

  const wasOpen = React.useRef(false)
  React.useEffect(() => {
    if (open && !wasOpen.current) { setDraft(initial()); setTouched(false) }
    wasOpen.current = open
  }, [open, initial])

  const validation = validateSettingsInput(draft, limits)
  const errors = validation.ok ? {} : validation.errors
  const update = (changes: Partial<NewComputer>) => setDraft(current => ({ ...current, ...changes }))

  async function submit(event?: React.FormEvent) {
    event?.preventDefault()
    setTouched(true)
    if (!validation.ok || !people.some(person => person.id === draft.personId && person.tenantId === draft.tenantId)) return
    setSaving(true)
    try {
      await onCreate({ ...draft, name: draft.name.trim(), personId: draft.personId })
    } catch (failure) {
      toast.error(errorMessage(failure))
    } finally {
      setSaving(false)
    }
  }

  return (
    <Dialog
      open={open}
      onClose={() => { if (!saving) onClose() }}
      title="New computer"
      description="A fresh Linux machine from the host's image, with its own disk. Memory and vCPUs can be changed later in its Settings."
      footer={
        <div className="flex justify-end gap-2">
          <Button variant="ghost" onClick={onClose} disabled={saving}>Cancel</Button>
          <Button onClick={() => void submit()} disabled={saving || !draft.personId || !people.some(person => person.id === draft.personId) || (touched && !validation.ok)}>{saving ? 'Creating…' : 'Create computer'}</Button>
        </div>
      }
    >
      <form className="space-y-4" onSubmit={event => void submit(event)}>
        <div className="space-y-1.5">
          <Label htmlFor="new-computer-name">Name</Label>
          <Input
            id="new-computer-name"
            autoFocus
            value={draft.name}
            maxLength={80}
            placeholder="Studio"
            aria-invalid={touched && errors.name ? true : undefined}
            onChange={event => update({ name: event.target.value })}
          />
          {touched && errors.name ? <p className="text-xs text-danger">{errors.name}</p> : <p className="text-xs text-fg-muted">Shown on Home in the iPhone app.</p>}
        </div>
        <div className="grid gap-4 sm:grid-cols-2">
          <div className="space-y-1.5">
            <Label htmlFor="new-computer-person">Whose computer</Label>
            <Select id="new-computer-person" disabled={peopleLoading || saving} value={draft.personId ?? ''} onChange={event => update({ personId: event.target.value })}>
              <option value="">{peopleLoading ? 'Loading people…' : 'Choose a person'}</option>
              {people.map(person => <option key={person.id} value={person.id}>{person.name}</option>)}
            </Select>
            {peopleError ? <p role="alert" className="text-sm text-danger">{peopleError}</p> : !peopleLoading ? <a className="text-sm underline underline-offset-4" href="/people">{people.length ? 'Manage people' : 'Add a person on the People page first'}</a> : null}
            <p className="text-xs text-fg-muted">The person who uses it from their phone. No account needed.</p>
          </div>
          {me.tenants.length > 1 ? (
            <div className="space-y-1.5">
              <Label htmlFor="new-computer-tenant">Household or team</Label>
              <Select id="new-computer-tenant" value={draft.tenantId ?? ''} onChange={event => update({ tenantId: event.target.value, personId: '' })}>
                {me.tenants.map(tenant => <option key={tenant.id} value={tenant.id}>{tenant.name}</option>)}
              </Select>
            </div>
          ) : null}
        </div>
        <div className="grid gap-4 sm:grid-cols-3">
          <div className="space-y-1.5">
            <Label htmlFor="new-computer-memory">Memory</Label>
            <Select id="new-computer-memory" value={String(draft.memoryMb)} onChange={event => update({ memoryMb: Number(event.target.value) })}>
              {memoryChoices(limits.memoryMb.min, limits.memoryMb.max, draft.memoryMb).map(value => (
                <option key={value} value={value}>{formatMemoryMb(value)}</option>
              ))}
            </Select>
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="new-computer-vcpus">vCPUs</Label>
            <Input
              id="new-computer-vcpus"
              type="number"
              inputMode="numeric"
              min={limits.vcpus.min}
              max={limits.vcpus.max}
              step={1}
              value={draft.vcpus}
              aria-invalid={touched && errors.vcpus ? true : undefined}
              onChange={event => update({ vcpus: event.target.valueAsNumber })}
            />
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="new-computer-idle">Park after</Label>
            <Select id="new-computer-idle" value={String(draft.idleMs)} onChange={event => update({ idleMs: Number(event.target.value) })}>
              {idleChoices(limits.idleMs.min, limits.idleMs.max, draft.idleMs).map(value => (
                <option key={value} value={value}>{formatIdleDuration(value)}</option>
              ))}
            </Select>
          </div>
        </div>
        {touched && errors.vcpus ? <p className="text-xs text-danger">{errors.vcpus}</p> : null}
      </form>
    </Dialog>
  )
}
