import * as React from 'react'
import { DashboardPanel } from '@braedonsaunders/appkit-dashboard/primitives'
import {
  Alert, AlertDescription, Button, Dialog, Input, Label, PageContainer, PageHeader, Spinner,
  Table, TableBody, TableCell, TableHead, TableHeader, TableRow, confirmDialog, toast,
} from '@braedonsaunders/appkit-ui'
import { Building2, Plus } from 'lucide-react'
import { CabooseApiError, formatMemoryMb, type CabooseClient, type Quotas, type Tenant } from '../api.js'
import { errorMessage } from '../components/common.js'
import { formatBytes } from '../files.js'
import { quotaDraft, quotasFromDraft, type QuotaDraft } from '../tenants.js'

/**
 * The operator's view of every household or team on the host: what its computers are given
 * and use against its quotas. A personal host has one tenant with no limits.
 */
export function Tenants({ client, onChanged, onUnauthorized }: { client: CabooseClient; onChanged: () => Promise<void>; onUnauthorized: () => void }) {
  const [tenants, setTenants] = React.useState<Tenant[] | null>(null)
  const [error, setError] = React.useState<string | null>(null)
  const [editing, setEditing] = React.useState<Tenant | 'new' | null>(null)

  const refresh = React.useCallback(async () => {
    try {
      setTenants((await client.tenants()).tenants)
      setError(null)
    } catch (failure) {
      if (failure instanceof CabooseApiError && failure.isUnauthorized) onUnauthorized()
      else setError(errorMessage(failure))
    }
  }, [client, onUnauthorized])
  React.useEffect(() => { void refresh() }, [refresh])

  async function remove(tenant: Tenant) {
    if (!await confirmDialog({
      title: `Delete ${tenant.name}?`,
      message: 'Its administrators lose access to it. Their accounts stay.',
      confirmLabel: 'Delete', tone: 'danger',
    })) return
    try {
      await client.deleteTenant(tenant.id)
      toast.success(`${tenant.name} was deleted.`)
      await onChanged()
    } catch (failure) {
      toast.error(errorMessage(failure))
    } finally {
      await refresh()
    }
  }

  return (
    <PageContainer>
      <div className="space-y-6">
        <PageHeader
          title="Tenants"
          description="Each household or team has its own computers and administrators, and quotas on what its computers are given between them. Quotas are checked when a computer is made, resized or woken."
          actions={<Button onClick={() => setEditing('new')}><Plus className="size-4" aria-hidden />New tenant</Button>}
        />
        {error ? <Alert variant="destructive"><AlertDescription>{error}</AlertDescription></Alert> : null}
        <DashboardPanel title="All tenants" icon={<Building2 className="size-4" aria-hidden />}>
          {tenants === null ? (
            <div className="flex items-center gap-2 text-sm text-fg-muted"><Spinner size={16} />Loading…</div>
          ) : (
            <Table containerClassName="border-0 shadow-none">
              <TableHeader>
                <TableRow noAnimate>
                  <TableHead>Name</TableHead>
                  <TableHead>Computers</TableHead>
                  <TableHead className="hidden md:table-cell">Memory</TableHead>
                  <TableHead className="hidden md:table-cell">vCPUs</TableHead>
                  <TableHead className="hidden lg:table-cell">Disk</TableHead>
                  <TableHead className="w-px"><span className="sr-only">Actions</span></TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {tenants.map(tenant => {
                  const usage = tenant.usage
                  return (
                    <TableRow key={tenant.id}>
                      <TableCell className="font-medium">{tenant.name}</TableCell>
                      <TableCell className="tabular-nums">{usage?.computers ?? '—'}</TableCell>
                      <TableCell className="hidden text-sm md:table-cell">
                        <Share used={usage ? formatMemoryMb(usage.memoryMb) : '—'} limit={tenant.quotas.memoryMb === null ? null : formatMemoryMb(tenant.quotas.memoryMb)} over={!!usage && tenant.quotas.memoryMb !== null && usage.memoryMb > tenant.quotas.memoryMb} />
                      </TableCell>
                      <TableCell className="hidden text-sm md:table-cell">
                        <Share used={usage ? String(usage.vcpus) : '—'} limit={tenant.quotas.vcpus === null ? null : String(tenant.quotas.vcpus)} over={!!usage && tenant.quotas.vcpus !== null && usage.vcpus > tenant.quotas.vcpus} />
                      </TableCell>
                      <TableCell className="hidden text-sm lg:table-cell">
                        <Share
                          used={usage?.diskBytes === null || usage?.diskBytes === undefined ? 'not measured' : formatBytes(usage.diskBytes)}
                          limit={tenant.quotas.diskGb === null ? null : `${tenant.quotas.diskGb} GiB`}
                          over={!!usage && usage.diskBytes !== null && tenant.quotas.diskGb !== null && usage.diskBytes > tenant.quotas.diskGb * 1024 ** 3}
                        />
                      </TableCell>
                      <TableCell>
                        <div className="flex justify-end gap-1">
                          <Button size="sm" variant="ghost" onClick={() => setEditing(tenant)}>Edit</Button>
                          <Button size="sm" variant="ghost" disabled={(usage?.computers ?? 0) > 0} title={(usage?.computers ?? 0) > 0 ? 'Delete or move its computers first.' : undefined} onClick={() => void remove(tenant)}>Delete</Button>
                        </div>
                      </TableCell>
                    </TableRow>
                  )
                })}
              </TableBody>
            </Table>
          )}
        </DashboardPanel>
      </div>
      <TenantDialog
        tenant={editing}
        onClose={() => setEditing(null)}
        onSave={async (name, quotas) => {
          if (editing === 'new') await client.createTenant({ name, quotas })
          else if (editing) await client.updateTenant(editing.id, { name, quotas })
          toast.success(editing === 'new' ? `${name} was made. Invite its administrators from People.` : `${name} was saved.`)
          setEditing(null)
          await Promise.all([refresh(), onChanged()])
        }}
      />
    </PageContainer>
  )
}

function Share({ used, limit, over }: { used: string; limit: string | null; over: boolean }) {
  return (
    <span className={over ? 'text-danger' : undefined}>
      {used}<span className="text-fg-muted"> of {limit ?? 'no limit'}</span>
    </span>
  )
}

function TenantDialog({ tenant, onClose, onSave }: { tenant: Tenant | 'new' | null; onClose: () => void; onSave: (name: string, quotas: Quotas) => Promise<void> }) {
  const [name, setName] = React.useState('')
  const [draft, setDraft] = React.useState<QuotaDraft>(quotaDraft(null))
  const [saving, setSaving] = React.useState(false)
  const [error, setError] = React.useState<string | null>(null)

  React.useEffect(() => {
    if (!tenant) return
    setName(tenant === 'new' ? '' : tenant.name)
    setDraft(quotaDraft(tenant === 'new' ? null : tenant.quotas))
    setError(null)
  }, [tenant])

  const parsed = quotasFromDraft(draft)

  async function save() {
    if (!parsed.ok) { setError(parsed.error); return }
    setSaving(true)
    try { await onSave(name.trim(), parsed.quotas) }
    catch (failure) { setError(errorMessage(failure)) }
    finally { setSaving(false) }
  }

  return (
    <Dialog
      open={tenant !== null}
      onClose={() => { if (!saving) onClose() }}
      title={tenant === 'new' ? 'New tenant' : `Edit ${tenant?.name ?? ''}`}
      description="A household or team. Leave a quota empty for no limit."
      footer={
        <div className="flex justify-end gap-2">
          <Button variant="ghost" onClick={onClose} disabled={saving}>Cancel</Button>
          <Button onClick={() => void save()} disabled={saving || !name.trim() || !parsed.ok}>{saving ? 'Saving…' : 'Save'}</Button>
        </div>
      }
    >
      <form className="space-y-4" onSubmit={event => { event.preventDefault(); void save() }}>
        <div className="space-y-1.5">
          <Label htmlFor="tenant-name">Name</Label>
          <Input id="tenant-name" autoFocus maxLength={80} value={name} placeholder="The Smiths" onChange={event => setName(event.target.value)} />
        </div>
        <div className="grid gap-4 sm:grid-cols-3">
          <div className="space-y-1.5">
            <Label htmlFor="tenant-memory">Memory (GiB)</Label>
            <Input id="tenant-memory" inputMode="numeric" placeholder="No limit" value={draft.memoryGb} onChange={event => setDraft({ ...draft, memoryGb: event.target.value })} />
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="tenant-vcpus">vCPUs</Label>
            <Input id="tenant-vcpus" inputMode="numeric" placeholder="No limit" value={draft.vcpus} onChange={event => setDraft({ ...draft, vcpus: event.target.value })} />
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="tenant-disk">Disk (GiB)</Label>
            <Input id="tenant-disk" inputMode="numeric" placeholder="No limit" value={draft.diskGb} onChange={event => setDraft({ ...draft, diskGb: event.target.value })} />
          </div>
        </div>
        {error || !parsed.ok ? <p className="text-xs text-danger">{error ?? (parsed.ok ? '' : parsed.error)}</p> : null}
      </form>
    </Dialog>
  )
}
