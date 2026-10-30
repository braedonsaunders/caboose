import { PageHeader } from '../components/console-ui.js'
import { ShieldCheck, Monitor } from 'lucide-react'
import * as React from 'react'
import { Alert, AlertDescription, Badge, Button, Input, Label, PageContainer, SettingsSection, Spinner } from '@braedonsaunders/appkit-ui'
import { QrCode } from '../components/QrCode.js'
import { securityRequest } from '../security-api.js'

interface Session { id: string; userAgent?: string; ipAddress?: string; createdAt: string; expiresAt: string }
interface Account { user: { twoFactorEnabled?: boolean }; session: { id: string } }

export function Security({ onSignOut }: { onSignOut: () => void }) {
  const [loading, setLoading] = React.useState(true)
  const [account, setAccount] = React.useState<Account | null>(null)
  const [sessions, setSessions] = React.useState<Session[]>([])
  const [password, setPassword] = React.useState('')
  const [nextPassword, setNextPassword] = React.useState('')
  const [confirm, setConfirm] = React.useState('')
  const [code, setCode] = React.useState('')
  const [enrollment, setEnrollment] = React.useState<{ totpURI: string; backupCodes: string[] } | null>(null)
  const [codes, setCodes] = React.useState<string[]>([])
  const [busy, setBusy] = React.useState(false)
  const [error, setError] = React.useState('')
  const [notice, setNotice] = React.useState('')
  const reload = React.useCallback(async () => {
    const current = await securityRequest<Account | null>('get-session')
    setAccount(current)
    if (!current) { setSessions([]); return }
    setSessions(await securityRequest<Session[]>('list-sessions'))
  }, [])
  React.useEffect(() => { void reload().catch(failure => setError(failure.message)).finally(() => setLoading(false)) }, [reload])
  async function run(action: () => Promise<void>) {
    setBusy(true); setError(''); setNotice('')
    try { await action(); await reload() } catch (failure) { setError(failure instanceof Error ? failure.message : 'Request failed') }
    finally { setBusy(false); setPassword(''); setNextPassword(''); setConfirm(''); setCode('') }
  }
  if (!account) return <PageContainer><div className="space-y-6"><PageHeader title="Account security" description="Manage your password, authenticator and browser sessions." />{loading ? <p role="status" className="flex items-center gap-2 text-sm text-fg-muted"><Spinner size={16} />Loading account security…</p> : <p>Sign in with an administrator account to manage its security.</p>}{error && <Alert variant="destructive"><AlertDescription>{error}</AlertDescription></Alert>}</div></PageContainer>
  return <PageContainer><div className="console-security space-y-4">
    <PageHeader title="Account security" description="Manage your password, authenticator and browser sessions." />
    <div className="flex flex-wrap items-center gap-x-6 gap-y-3 rounded-xl border border-border bg-surface px-4 py-3 text-sm">
      <div className="flex items-center gap-2"><ShieldCheck className="size-4 text-primary" aria-hidden /><span className="text-fg-muted">Sign-in protection</span><Badge variant={account.user.twoFactorEnabled ? 'success' : 'secondary'}>{account.user.twoFactorEnabled ? 'Authenticator enabled' : 'Password only'}</Badge></div>
      <div className="flex items-center gap-2"><Monitor className="size-4 text-primary" aria-hidden /><span className="font-semibold tabular-nums">{sessions.length}</span><span className="text-fg-muted">signed-in sessions</span></div>
    </div>
    {error && <Alert variant="destructive"><AlertDescription>{error}</AlertDescription></Alert>}
    {notice && <p role="status">{notice}</p>}
    <div className="flex flex-wrap items-center gap-x-5 gap-y-3 rounded-xl border border-border bg-surface px-4 py-3">
      <div className="min-w-0 flex-[1_1_16rem]"><Label htmlFor="security-password">Current password</Label><p id="security-password-help" className="mt-1 text-xs text-fg-muted">Required for password and authenticator changes.</p></div>
      <Input className="flex-[1_1_16rem]" id="security-password" type="password" autoComplete="current-password" aria-describedby="security-password-help" value={password} onChange={event => setPassword(event.target.value)} />
    </div>
    <div className="grid items-start gap-4 xl:grid-cols-2">
    <SettingsSection title="Password">
      <form className="space-y-3 p-4" onSubmit={event => { event.preventDefault(); void run(async () => {
        await securityRequest('change-password', { currentPassword: password, newPassword: nextPassword, revokeOtherSessions: true })
        setNotice('Password changed. Other sessions have been signed out.')
      }) }}>
        <Label htmlFor="new-password">New password</Label><Input id="new-password" type="password" autoComplete="new-password" value={nextPassword} onChange={event => setNextPassword(event.target.value)} />
        <Label htmlFor="confirm-password">Confirm new password</Label><Input id="confirm-password" type="password" autoComplete="new-password" value={confirm} onChange={event => setConfirm(event.target.value)} />
        <Button disabled={busy || !password || nextPassword.length < 8 || nextPassword !== confirm}>Change password</Button>
      </form>
    </SettingsSection>
    <SettingsSection title="Authenticator" description={account.user.twoFactorEnabled ? 'Two-factor authentication is enabled.' : 'Require a code from your authenticator when signing in.'}>
      <div className="space-y-3 p-4">
        {!enrollment && <Button disabled={busy || !password} onClick={() => void run(async () => {
          if (account.user.twoFactorEnabled) { await securityRequest('two-factor/disable', { password }); setCodes([]); setNotice('Authenticator disabled.') }
          else { const result = await securityRequest<{ totpURI: string; backupCodes: string[] }>('two-factor/enable', { password }); setEnrollment(result); setCodes(result.backupCodes) }
        })}>{account.user.twoFactorEnabled ? 'Disable authenticator' : 'Set up authenticator'}</Button>}
        {enrollment && <form className="space-y-3" onSubmit={event => { event.preventDefault(); void run(async () => {
          await securityRequest('two-factor/verify-totp', { code }); setEnrollment(null); setNotice('Authenticator enabled. Keep your recovery codes in a safe place.')
        }) }}>
          <p>Scan this code with your authenticator, or enter the setup key below. Then enter its six-digit code.</p>
          <QrCode value={enrollment.totpURI} label="Authenticator setup" />
          <code className="block break-all select-all">{new URL(enrollment.totpURI).searchParams.get('secret')}</code>
          <Label htmlFor="enrollment-code">Authenticator code</Label><Input id="enrollment-code" inputMode="numeric" autoComplete="one-time-code" value={code} onChange={event => setCode(event.target.value)} />
          <Button disabled={busy || !code}>Verify and enable</Button>
        </form>}
        {account.user.twoFactorEnabled && <Button disabled={busy || !password} variant="outline" onClick={() => void run(async () => {
          const result = await securityRequest<{ backupCodes: string[] }>('two-factor/generate-backup-codes', { password }); setCodes(result.backupCodes)
        })}>Replace recovery codes</Button>}
        {codes.length > 0 && <div className="space-y-2"><p>Save these recovery codes. Each works once; replacing them invalidates previous codes.</p><pre className="rounded-lg border border-border bg-bg-subtle p-4 font-mono text-sm select-all whitespace-pre-wrap">{codes.join('\n')}</pre><Button variant="outline" onClick={() => setCodes([])}>I saved these codes</Button></div>}
      </div>
    </SettingsSection>
    </div>
    <SettingsSection title="Signed-in sessions" description="Revoking a session signs that browser out on its next request.">
      <div className="space-y-3 p-4">
        <Button disabled={busy} variant="outline" onClick={() => void run(async () => { await securityRequest('revoke-other-sessions', {}); setNotice('Other sessions signed out.') })}>Sign out other sessions</Button>
        {sessions.map(session => <div key={session.id} className="flex flex-wrap items-start justify-between gap-3 border-b border-border py-3"><div className="min-w-0 flex-[1_1_18rem]"><p className="font-medium">{session.id === account.session.id ? 'This session' : 'Other session'}</p><p className="mt-1 text-sm text-fg-muted break-all">{session.userAgent || 'Unknown browser'} · {session.ipAddress || 'Unknown address'}</p><p className="text-xs text-fg-muted">Signed in {new Date(session.createdAt).toLocaleString()} · Expires {new Date(session.expiresAt).toLocaleString()}</p></div><Button variant="outline" disabled={busy} onClick={() => void run(async () => { await securityRequest('revoke-session', { id: session.id }); if (session.id === account.session.id) onSignOut() })}>Sign out</Button></div>)}
      </div>
    </SettingsSection>
  </div></PageContainer>
}
