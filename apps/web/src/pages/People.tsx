import * as React from 'react'
import { DashboardPanel } from '@braedonsaunders/appkit-dashboard/primitives'
import {
  Alert, AlertDescription, AlertTitle, Badge, Button, EmptyState, PageContainer, PageHeader, Select, Spinner,
  Table, TableBody, TableCell, TableHead, TableHeader, TableRow, confirmDialog, promptDialog, toast,
} from '@braedonsaunders/appkit-ui'
import { Mail, ShieldCheck, Users } from 'lucide-react'
import {
  CabooseApiError, buildInviteLink, type Administrator, type CabooseClient, type Me, type PendingInvite, type Person, type ComputerSummary,
} from '../api.js'
import { navigate, routeHref } from '../navigation.js'
import { errorMessage } from '../components/common.js'

/**
 * People and their computers, with administrator login access managed separately.
 */
export function People({ client, me, onUnauthorized }: { client: CabooseClient; me: Me; onUnauthorized: () => void }) {
  const [tenantId, setTenantId] = React.useState(me.tenants[0]?.id ?? '')
  const [administrators, setAdministrators] = React.useState<Administrator[] | null>(null)
  const [invites, setInvites] = React.useState<PendingInvite[] | null>(null)
  const [error, setError] = React.useState<string | null>(null)
  const [busy, setBusy] = React.useState<string | null>(null)
  const [link, setLink] = React.useState<{ email: string; url: string } | null>(null)
  const [people, setPeople] = React.useState<Person[] | null>(null)
  const [computers, setComputers] = React.useState<ComputerSummary[]>([])
  const currentTenant = React.useRef(tenantId)
  currentTenant.current = tenantId
  const generation = React.useRef(0)
  const tenant = me.tenants.find(entry => entry.id === tenantId)

  const refresh = React.useCallback(async () => {
    if (!tenantId || currentTenant.current !== tenantId) return
    const request = ++generation.current
    try {
      const [persons, machines, admins, pending] = await Promise.all([
        client.people(tenantId), client.computers(), client.administrators(tenantId), client.invites(tenantId),
      ])
      if (generation.current !== request || currentTenant.current !== tenantId) return
      setPeople(persons.people)
      setComputers(machines.computers)
      setAdministrators(admins.administrators)
      setInvites(pending.invites)
      setError(null)
    } catch (failure) {
      if (generation.current !== request || currentTenant.current !== tenantId) return
      if (failure instanceof CabooseApiError && failure.isUnauthorized) onUnauthorized()
      else setError(errorMessage(failure))
    }
  }, [client, tenantId, onUnauthorized])
  React.useEffect(() => {
    setPeople(null); setComputers([]); setAdministrators(null); setInvites(null); setLink(null); setError(null)
    void refresh()
    return () => { generation.current++ }
  }, [refresh])

  async function act(key: string, work: () => Promise<unknown>, done: string) {
    setBusy(key)
    try {
      await work()
      toast.success(done)
    } catch (failure) {
      if (failure instanceof CabooseApiError && failure.isUnauthorized) return onUnauthorized()
      toast.error(errorMessage(failure))
    } finally {
      setBusy(null)
      await refresh()
    }
  }

  async function addPerson() {
    const name = await promptDialog({ title: `Add a person to ${tenant?.name ?? 'this tenant'}`, label: 'Name', confirmLabel: 'Add person' })
    if (name?.trim()) await act('person', () => client.createPerson(tenantId, name.trim()), 'Person added.')
  }

  async function renamePerson(person: Person) {
    const name = await promptDialog({ title: `Rename ${person.name}`, label: 'Name', confirmLabel: 'Rename' })
    if (name?.trim()) await act(person.id, () => client.renamePerson(person.id, name.trim()), 'Person renamed.')
  }

  async function deletePerson(person: Person) {
    if (await confirmDialog({ title: `Delete ${person.name}?`, message: 'Remove this person from the tenant. Reassign any computers first. Administrator login access is managed separately.', confirmLabel: 'Delete', tone: 'danger' })) {
      await act(person.id, () => client.deletePerson(person.id), 'Person deleted.')
    }
  }

  async function invite() {
    const email = await promptDialog({ title: `Invite an administrator to ${tenant?.name ?? 'this tenant'}`, label: 'Their email', placeholder: 'name@example.com', confirmLabel: 'Make invitation link' })
    if (!email) return
    setBusy('invite')
    try {
      const made = await client.invite(tenantId, email)
      setLink({ email: made.invite.email, url: buildInviteLink(window.location.origin, made.token) })
    } catch (failure) {
      if (failure instanceof CabooseApiError && failure.isUnauthorized) return onUnauthorized()
      toast.error(errorMessage(failure))
    } finally {
      setBusy(null)
      await refresh()
    }
  }

  async function remove(admin: Administrator) {
    if (!await confirmDialog({
      title: `Remove ${admin.name}?`,
      message: `${admin.name} can no longer manage ${tenant?.name ?? 'this tenant'}'s computers. Their account stays, and an invitation brings them back.`,
      confirmLabel: 'Remove', tone: 'danger',
    })) return
    await act(admin.userId, () => client.removeAdministrator(tenantId, admin.userId), `${admin.name} was removed.`)
  }

  async function revoke(pending: PendingInvite) {
    await act(pending.id, () => client.revokeInvite(tenantId, pending.id), `The invitation to ${pending.email} was withdrawn.`)
  }

  return (
    <PageContainer>
      <div className="space-y-6">
        <PageHeader
          title="People"
          description="People own computers. Administrator access is managed separately below."
          actions={
            <div className="flex flex-wrap items-center gap-2">
              {me.tenants.length > 1 ? (
                <Select className="w-56" aria-label="Tenant" value={tenantId} onChange={event => setTenantId(event.target.value)}>
                  {me.tenants.map(entry => <option key={entry.id} value={entry.id}>{entry.name}</option>)}
                </Select>
              ) : null}
              {tenantId ? (
                <Button onClick={() => void invite()} disabled={busy !== null}><Mail className="size-4" aria-hidden />Invite administrator</Button>
              ) : null}
            </div>
          }
        />

        {!tenantId ? (
          <EmptyState icon={<Users className="size-6" aria-hidden />} title="No household or team yet" description={me.setupRequired ? "Use Complete setup above to create your household and person and link your existing computer." : "The operator makes them under Tenants."} />
        ) : null}

        {link ? (
          <Alert variant="success">
            <AlertTitle>Send this link to {link.email}</AlertTitle>
            <AlertDescription>
              <div className="space-y-3">
                <p>It works once, for seven days, and is shown only now. Whoever opens it can become an administrator of {tenant?.name}, so send it only to them.</p>
                <code className="block break-all rounded-md bg-bg-subtle p-3 text-xs text-fg">{link.url}</code>
                <div className="flex flex-wrap gap-2">
                  <Button size="sm" onClick={() => {
                    navigator.clipboard.writeText(link.url).then(() => toast.success('Invitation link copied.'), () => toast.error('The browser did not allow copying.'))
                  }}>Copy link</Button>
                  <Button size="sm" variant="ghost" onClick={() => setLink(null)}>Done</Button>
                </div>
              </div>
            </AlertDescription>
          </Alert>
        ) : null}

        {error ? <Alert variant="destructive"><AlertDescription>{error}</AlertDescription></Alert> : null}

        {tenantId ? (
          <DashboardPanel title={`People in ${tenant?.name ?? 'this tenant'}`} icon={<Users className="size-4" aria-hidden />}>
            <div className="mb-4 flex justify-end">
              <Button disabled={busy !== null} onClick={() => void addPerson()}>Add person</Button>
            </div>
            {people === null ? (
              <div className="flex items-center gap-2 text-sm text-fg-muted"><Spinner size={16} />Loading people…</div>
            ) : people.length === 0 ? (
              <EmptyState icon={<Users className="size-6" aria-hidden />} title="No people yet" description="Add the people who will use this tenant’s computers. They do not need an administrator login." />
            ) : (
              <Table containerClassName="border-0 shadow-none">
                <TableHeader><TableRow noAnimate><TableHead>Name</TableHead><TableHead>Computers</TableHead><TableHead><span className="sr-only">Actions</span></TableHead></TableRow></TableHeader>
                <TableBody>{people.map(person => {
                  const owned = computers.filter(computer => computer.personId === person.id && computer.tenantId === tenantId)
                  return (
                    <TableRow key={person.id}>
                      <TableCell className="font-medium">{person.name}{person.userId === me.user?.id ? <span className="ml-2 text-xs text-fg-muted">you</span> : null}</TableCell>
                      <TableCell>{owned.length ? <div className="flex flex-wrap gap-3">{owned.map(computer => {
                        const href = routeHref({ page: 'computer', id: computer.id, tab: 'overview' })
                        return <a key={computer.id} href={href} className="text-sm underline underline-offset-4" onClick={event => { event.preventDefault(); navigate(href) }}>{computer.settings.name}</a>
                      })}</div> : <span className="text-sm text-fg-muted">No computers</span>}</TableCell>
                      <TableCell><div className="flex justify-end gap-2">
                        <Button size="sm" variant="ghost" disabled={busy !== null} onClick={() => void renamePerson(person)}>Rename</Button>
                        <Button size="sm" variant="ghost" disabled={busy !== null || owned.length > 0} title={owned.length ? 'Reassign this person’s computers first.' : undefined} onClick={() => void deletePerson(person)}>Delete</Button>
                      </div></TableCell>
                    </TableRow>
                  )
                })}</TableBody>
              </Table>
            )}
          </DashboardPanel>
        ) : null}

        {tenantId ? (
          <DashboardPanel title="Administrators" icon={<ShieldCheck className="size-4" aria-hidden />}>
            {administrators === null ? (
              <div className="flex items-center gap-2 text-sm text-fg-muted"><Spinner size={16} />Loading…</div>
            ) : (
              <Table containerClassName="border-0 shadow-none">
                <TableHeader>
                  <TableRow noAnimate>
                    <TableHead>Name</TableHead>
                    <TableHead>Email</TableHead>
                    <TableHead className="hidden md:table-cell">Joined</TableHead>
                    <TableHead className="w-px"><span className="sr-only">Actions</span></TableHead>
                  </TableRow>
                </TableHeader>
                <TableBody>
                  {administrators.map(admin => (
                    <TableRow key={admin.userId}>
                      <TableCell className="font-medium">
                        {admin.name}
                        {admin.operator ? <Badge variant="info" className="ml-2">Operator</Badge> : null}
                        {admin.userId === me.user?.id ? <span className="ml-2 text-xs text-fg-muted">you</span> : null}
                      </TableCell>
                      <TableCell className="text-sm text-fg-muted">{admin.email}</TableCell>
                      <TableCell className="hidden text-sm text-fg-muted md:table-cell">{admin.joinedAt ? new Date(admin.joinedAt).toLocaleDateString() : '—'}</TableCell>
                      <TableCell>
                        <Button size="sm" variant="ghost" disabled={busy !== null || administrators.length === 1} title={administrators.length === 1 ? 'A tenant keeps at least one administrator.' : undefined} onClick={() => void remove(admin)}>
                          {busy === admin.userId ? 'Removing…' : 'Remove'}
                        </Button>
                      </TableCell>
                    </TableRow>
                  ))}
                </TableBody>
              </Table>
            )}
          </DashboardPanel>
        ) : null}

        {tenantId && invites?.length ? (
          <DashboardPanel title="Invitations waiting" icon={<Mail className="size-4" aria-hidden />}>
            <Table containerClassName="border-0 shadow-none">
              <TableHeader>
                <TableRow noAnimate>
                  <TableHead>Email</TableHead>
                  <TableHead>Expires</TableHead>
                  <TableHead className="w-px"><span className="sr-only">Actions</span></TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {invites.map(pending => (
                  <TableRow key={pending.id}>
                    <TableCell>{pending.email}</TableCell>
                    <TableCell className="text-sm text-fg-muted">{new Date(pending.expiresAt).toLocaleString()}</TableCell>
                    <TableCell>
                      <Button size="sm" variant="ghost" disabled={busy !== null} onClick={() => void revoke(pending)}>{busy === pending.id ? 'Withdrawing…' : 'Withdraw'}</Button>
                    </TableCell>
                  </TableRow>
                ))}
              </TableBody>
            </Table>
          </DashboardPanel>
        ) : null}
      </div>
    </PageContainer>
  )
}
