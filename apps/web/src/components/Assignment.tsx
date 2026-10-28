import * as React from 'react'
import { Alert, AlertDescription, Button, Select, SettingsRow, SettingsSection, toast } from '@braedonsaunders/appkit-ui'
import type { CabooseClient, ComputerSummary, Me, Person } from '../api.js'
import { errorMessage } from './common.js'

/** A computer and its selected person always move between tenants together. */
export function Assignment({ client, computer, me, onChanged }: { client: CabooseClient; computer: ComputerSummary; me: Me; onChanged: () => Promise<void> }) {
  const [tenantId, setTenantId] = React.useState(computer.tenantId ?? me.tenants[0]?.id ?? '')
  const [personId, setPersonId] = React.useState(computer.personId ?? '')
  const [people, setPeople] = React.useState<Person[] | null>(null)
  const [error, setError] = React.useState('')
  const [saving, setSaving] = React.useState(false)

  React.useEffect(() => {
    setTenantId(computer.tenantId ?? me.tenants[0]?.id ?? '')
    setPersonId(computer.personId ?? '')
  }, [computer.id, computer.tenantId, computer.personId, me.tenants])
  React.useEffect(() => {
    let active = true
    setPeople(null)
    setError('')
    if (!tenantId) { setPeople([]); return }
    client.people(tenantId).then(
      result => { if (active) setPeople(result.people) },
      failure => { if (active) setError(errorMessage(failure)) },
    )
    return () => { active = false }
  }, [client, tenantId])

  const validPerson = people?.some(person => person.id === personId && person.tenantId === tenantId)
  const changed = tenantId !== computer.tenantId || personId !== computer.personId
  async function save() {
    if (!validPerson || !changed) return
    setSaving(true)
    setError('')
    try {
      await client.updateComputer(computer.id, { tenantId, personId })
      await onChanged()
      toast.success('Ownership saved.')
    } catch (failure) { setError(errorMessage(failure)) }
    finally { setSaving(false) }
  }

  return (
    <SettingsSection title="Ownership" description="This computer belongs to a person in a household or team. Administrator access is managed separately.">
      <SettingsRow title="Household or team" control={
        <Select className="w-56" aria-label="Household or team" disabled={!me.operator || saving} value={tenantId} onChange={event => { setTenantId(event.target.value); setPersonId('') }}>
          {!tenantId ? <option value="">Complete setup first</option> : null}
          {me.tenants.map(tenant => <option key={tenant.id} value={tenant.id}>{tenant.name}</option>)}
        </Select>
      } />
      <SettingsRow title="Person" description={!error && people === null ? 'Loading people…' : people?.length === 0 ? 'Add a person on the People page first.' : undefined} control={
        <Select className="w-56" aria-label="Person" disabled={!people || saving} value={personId} onChange={event => setPersonId(event.target.value)}>
          <option value="">Choose a person</option>
          {people?.map(person => <option key={person.id} value={person.id}>{person.name}</option>)}
        </Select>
      } />
      {error ? <Alert variant="destructive"><AlertDescription>{error}</AlertDescription></Alert> : null}
      <div className="flex items-center justify-end gap-4">
        <a className="text-sm underline underline-offset-4" href="/people">Manage people</a>
        <Button disabled={saving || !validPerson || !changed} onClick={() => void save()}>{saving ? 'Saving…' : 'Save ownership'}</Button>
      </div>
    </SettingsSection>
  )
}
