import * as React from 'react'
import { Button, Input, Select, SettingsRow, SettingsSection, toast } from '@braedonsaunders/appkit-ui'
import type { CabooseClient, ComputerSummary, Me } from '../api.js'
import { errorMessage } from './common.js'

/**
 * Whose computer this is (a person who uses it from their phone, with no account) and, for
 * the operator, which household or team it belongs to.
 */
export function Assignment({ client, computer, me, onChanged }: { client: CabooseClient; computer: ComputerSummary; me: Me; onChanged: () => Promise<void> }) {
  const [person, setPerson] = React.useState(computer.person ?? '')
  const [tenantId, setTenantId] = React.useState(computer.tenantId ?? '')
  const [saving, setSaving] = React.useState(false)
  React.useEffect(() => { setPerson(computer.person ?? '') }, [computer.person])
  React.useEffect(() => { setTenantId(computer.tenantId ?? '') }, [computer.tenantId])

  const personChanged = person.trim() !== (computer.person ?? '')
  const tenantChanged = me.operator && tenantId !== (computer.tenantId ?? '') && tenantId !== ''

  async function save(changes: { person?: string | null; tenantId?: string }, done: string) {
    setSaving(true)
    try {
      await client.updateComputer(computer.id, changes)
      await onChanged()
      toast.success(done)
    } catch (failure) {
      toast.error(errorMessage(failure))
    } finally {
      setSaving(false)
    }
  }

  return (
    <SettingsSection
      title="Who uses it"
      description="A computer is one person's. They use it from their phone, paired on the Phones tab, and need no account."
    >
      <SettingsRow
        title="Person"
        control={
          <div className="flex items-center gap-2">
            <Input className="w-56" maxLength={80} placeholder="Nobody yet" value={person} onChange={event => setPerson(event.target.value)} />
            {personChanged ? (
              <Button size="sm" disabled={saving} onClick={() => void save({ person: person.trim() || null }, 'Saved.')}>Save</Button>
            ) : null}
          </div>
        }
      />
      {me.operator && me.tenants.length > 1 ? (
        <SettingsRow
          title="Household or team"
          description="Moving a computer checks the new tenant's quotas."
          control={
            <div className="flex items-center gap-2">
              <Select className="w-56" aria-label="Tenant" value={tenantId} onChange={event => setTenantId(event.target.value)}>
                {computer.tenantId ? null : <option value="">None</option>}
                {me.tenants.map(tenant => <option key={tenant.id} value={tenant.id}>{tenant.name}</option>)}
              </Select>
              {tenantChanged ? (
                <Button size="sm" disabled={saving} onClick={() => void save({ tenantId }, `Moved to ${me.tenants.find(tenant => tenant.id === tenantId)?.name}.`)}>Move</Button>
              ) : null}
            </div>
          }
        />
      ) : null}
    </SettingsSection>
  )
}
