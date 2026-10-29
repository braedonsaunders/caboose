import * as React from 'react'
import { EmptyState, Label, PageContainer, Select } from '@braedonsaunders/appkit-ui'
import type { CabooseClient, Me } from '../api.js'
import { Capacity } from './Capacity.js'

/** Only the operator can select the host; all other scopes come from current membership. */
export function Usage({ client, me, onUnauthorized }: {
  client: CabooseClient
  me: Me
  onUnauthorized: () => void
}) {
  const [selected, setSelected] = React.useState('')
  const tenant = me.tenants.find(item => item.id === selected)
  const scope = tenant?.id ?? (me.operator ? '' : me.tenants[0]?.id)
  const name = me.tenants.find(item => item.id === scope)?.name

  if (scope === undefined) return <PageContainer><EmptyState title="No households or teams" description="Usage is available for households and teams you administer." /></PageContainer>

  return <Capacity key={scope || 'host'} client={client} onUnauthorized={onUnauthorized} tenantId={scope || undefined} tenantName={name} scopeControl={
    <div className="flex flex-wrap items-center gap-3 rounded-xl border border-border bg-surface px-5 py-4">
      <Label htmlFor="usage-scope">Resource scope</Label>
      <Select className="max-w-sm" id="usage-scope" value={scope} onChange={event => setSelected(event.target.value)}>
        {me.operator ? <option value="">Entire host</option> : null}
        {me.tenants.map(item => <option key={item.id} value={item.id}>{item.name}</option>)}
      </Select>
      <p className="text-xs text-fg-muted">{scope ? 'Resources assigned to this household or team' : 'All computers and host measurements'}</p>
    </div>
  } />
}
