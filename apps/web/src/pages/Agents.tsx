import * as React from 'react'
import { DashboardPanel } from '@braedonsaunders/appkit-dashboard/primitives'
import {
  Alert, AlertDescription, Badge, Button, EmptyState, Label, PageContainer, PageHeader, Select, Switch, Textarea, toast,
} from '@braedonsaunders/appkit-ui'
import { Bot, KeyRound, ShieldQuestion } from 'lucide-react'
import {
  CabooseApiError, agentLabel, alwaysAllowOption, canReply, envProblem, hasUpdate, orderAgents,
  type AgentListing, type AgentTask, type AgentsResponse, type CabooseClient, type SignInMethod,
} from '../api.js'
import { isLiveTask, taskTone } from '../state.js'
import type { ComputerHandle } from '../useComputer.js'

const POLL_MS = 5_000
/** Faster while an agent works, so a request for approval shows up promptly. */
const LIVE_POLL_MS = 2_000

export function Agents({ client, computer, onUnauthorized }: { client: CabooseClient; computer: ComputerHandle; onUnauthorized: () => void }) {
  const [tasks, setTasks] = React.useState<AgentTask[] | null>(null)
  const [catalog, setCatalog] = React.useState<AgentsResponse | null>(null)
  const [error, setError] = React.useState<string | null>(null)
  const [prompt, setPrompt] = React.useState('')
  const [agent, setAgent] = React.useState('')
  const [askFirst, setAskFirst] = React.useState(false)
  const [starting, setStarting] = React.useState(false)
  const [installing, setInstalling] = React.useState<string | null>(null)
  const running = computer.status?.state === 'running'

  const fail = React.useCallback((failure: unknown) => {
    if (failure instanceof CabooseApiError && failure.isUnauthorized) onUnauthorized()
    else setError(failure instanceof Error ? failure.message : String(failure))
  }, [onUnauthorized])

  const refresh = React.useCallback(async () => {
    try {
      setTasks(await client.agentTasks())
      setError(null)
    } catch (failure) {
      fail(failure)
    }
  }, [client, fail])

  const refreshCatalog = React.useCallback(async () => {
    try {
      const next = await client.agents()
      setCatalog(next)
      setAgent(current => current || next.defaultAgent || orderAgents(next.agents, next.defaultAgent).find(entry => entry.installed)?.id || '')
    } catch (failure) {
      fail(failure)
    }
  }, [client, fail])

  const anyLive = tasks?.some(task => isLiveTask(task.status)) ?? false
  const signingIn = catalog?.agents.some(entry => entry.signInStatus?.status === 'running') ?? false
  React.useEffect(() => { void refresh() }, [refresh])
  // The installed state comes from the computer, so look again once it is running.
  React.useEffect(() => { void refreshCatalog() }, [refreshCatalog, running])
  React.useEffect(() => {
    const timer = window.setInterval(() => { if (document.visibilityState === 'visible') void refresh() }, anyLive ? LIVE_POLL_MS : POLL_MS)
    return () => window.clearInterval(timer)
  }, [refresh, anyLive])
  React.useEffect(() => {
    if (!signingIn) return
    const timer = window.setInterval(() => { if (document.visibilityState === 'visible') void refreshCatalog() }, LIVE_POLL_MS)
    return () => window.clearInterval(timer)
  }, [refreshCatalog, signingIn])

  async function act(work: () => Promise<unknown>, failureMessage: string): Promise<boolean> {
    let ok = false
    try {
      await work()
      ok = true
    } catch (failure) {
      toast.error(failure instanceof Error ? failure.message : failureMessage)
    }
    await refresh()
    await computer.refresh()
    return ok
  }

  async function answer(task: AgentTask, requestId: string, allow: boolean, optionId?: string) {
    await act(async () => {
      const { resolved } = await client.resolveAgentApproval(task.id, requestId, allow, optionId ? { optionId } : {})
      if (!resolved) toast.info('That request was already answered or has ended.')
    }, allow ? 'Could not approve.' : 'Could not deny.')
  }

  async function install(entry: AgentListing) {
    setInstalling(entry.id)
    try {
      const { agent: installed } = await client.installAgent(entry.id)
      toast.success(`${installed.name} ${installed.installed?.version ?? ''} is installed.`)
    } catch (failure) {
      toast.error(failure instanceof Error ? failure.message : 'The install failed.')
    } finally {
      setInstalling(null)
      await refreshCatalog()
      await computer.refresh()
    }
  }

  async function signIn(id: string, method: SignInMethod) {
    try {
      await client.signInAgent(id, method.id)
      toast.info(method.type === 'terminal'
        ? 'A terminal opened on your computer\'s screen. Finish signing in there.'
        : 'The sign-in page opened in your computer\'s browser. Finish signing in on its screen.')
    } catch (failure) {
      toast.error(failure instanceof Error ? failure.message : 'Could not start the sign-in.')
    }
    await refreshCatalog()
  }

  async function start(event: React.FormEvent) {
    event.preventDefault()
    const text = prompt.trim()
    if (!text) return
    setStarting(true)
    try {
      await client.startAgentTask({ prompt: text, ...(agent ? { agent } : {}), approvals: askFirst ? 'ask' : 'auto' })
      setPrompt('')
      toast.success('The agent is working on it.')
    } catch (failure) {
      toast.error(failure instanceof Error ? failure.message : 'The task did not start.')
    } finally {
      setStarting(false)
      await refresh()
      await computer.refresh()
    }
  }

  const ordered = catalog ? orderAgents(catalog.agents, catalog.defaultAgent) : []
  const installedAgents = ordered.filter(entry => entry.installed)
  const availableAgents = ordered.filter(entry => !entry.installed)
  const selected = ordered.find(entry => entry.id === agent)

  return (
    <PageContainer>
      <div className="mx-auto max-w-4xl space-y-6">
        <PageHeader
          title="Agents"
          description="Any agent from the Agent Client Protocol registry works inside your computer on its own seat, signed in with your own account. A running task keeps the computer awake."
        />

        {catalog?.registry.error ? (
          <Alert variant="warning">
            <AlertDescription>
              {catalog.agents.length ? `${catalog.registry.error} Showing the list from ${catalog.registry.fetchedAt ? new Date(catalog.registry.fetchedAt).toLocaleString() : 'earlier'}.` : catalog.registry.error}
            </AlertDescription>
          </Alert>
        ) : null}

        <DashboardPanel title="New task" icon={<Bot className="size-4" aria-hidden />}>
          <form className="space-y-3" onSubmit={start}>
            <div className="space-y-2">
              <Label htmlFor="prompt">What should the agent do?</Label>
              <Textarea
                id="prompt"
                rows={4}
                maxLength={32_000}
                value={prompt}
                onChange={event => setPrompt(event.target.value)}
                disabled={!running}
              />
            </div>
            <div className="flex flex-wrap items-center gap-3">
              <Select
                className="w-64"
                aria-label="Agent"
                value={agent}
                placeholder={catalog ? 'Choose an agent' : 'Loading agents…'}
                onChange={event => setAgent(event.target.value)}
                disabled={!running || !catalog}
              >
                {installedAgents.length ? (
                  <optgroup label="Installed">
                    {installedAgents.map(entry => <option key={entry.id} value={entry.id}>{entry.name}</option>)}
                  </optgroup>
                ) : null}
                {availableAgents.length ? (
                  <optgroup label="In the registry">
                    {availableAgents.map(entry => <option key={entry.id} value={entry.id}>{entry.name}</option>)}
                  </optgroup>
                ) : null}
              </Select>
              <label className="flex items-center gap-2 text-sm" title="Every action the agent asks permission for waits for your answer.">
                <Switch checked={askFirst} onChange={event => setAskFirst(event.target.checked)} disabled={!running} />
                Ask before acting
              </label>
              <Button type="submit" disabled={!running || starting || !prompt.trim() || !agent}>
                {starting ? 'Starting…' : 'Start task'}
              </Button>
              {!running ? <span className="text-sm text-fg-muted">Wake the computer to start a task.</span> : null}
            </div>
            {selected ? (
              <AgentDetails
                agent={selected}
                isDefault={selected.id === catalog?.defaultAgent}
                running={running}
                installing={installing === selected.id}
                onInstall={() => void install(selected)}
                onSignIn={method => void signIn(selected.id, method)}
                onSetEnv={changes => act(() => client.setAgentEnv(selected.id, changes), 'Could not change the environment.')}
              />
            ) : null}
          </form>
        </DashboardPanel>

        {error ? (
          <Alert variant="destructive"><AlertDescription>{error}</AlertDescription></Alert>
        ) : null}

        {tasks && tasks.length === 0 ? (
          <EmptyState
            icon={<Bot className="size-6" aria-hidden />}
            title="No agent tasks yet"
            description="Tasks started here, from the iPhone's Ask bar, or by the API appear here with their result."
          />
        ) : null}

        <div className="space-y-3">
          {tasks?.map(task => (
            <DashboardPanel key={task.id}>
              <div className="space-y-2">
                <div className="flex flex-wrap items-center gap-2">
                  <Badge variant={taskTone(task.status)}>{task.status}</Badge>
                  <span className="text-sm font-medium">{agentLabel(task, catalog?.agents)}</span>
                  <span className="text-xs text-fg-muted">{new Date(task.startedAt).toLocaleString()}</span>
                  {task.approvals === 'ask' ? <Badge variant="secondary">asks first</Badge> : null}
                  {(task.turns ?? 1) > 1 ? <span className="text-xs text-fg-muted">{task.turns} turns</span> : null}
                  <div className="ml-auto flex gap-2">
                    {task.status === 'running' ? (
                      <Button size="sm" variant="outline" onClick={() => void act(() => client.pauseAgentTask(task.id), 'Could not pause.')}>Pause</Button>
                    ) : null}
                    {task.status === 'paused' ? (
                      <Button size="sm" variant="outline" onClick={() => void act(() => client.resumeAgentTask(task.id), 'Could not resume.')}>Resume</Button>
                    ) : null}
                    {isLiveTask(task.status) ? (
                      <Button size="sm" variant="destructive" onClick={() => void act(() => client.cancelAgentTask(task.id), 'Could not cancel.')}>Cancel</Button>
                    ) : null}
                  </div>
                </div>
                <p className="whitespace-pre-wrap text-sm">{task.prompt}</p>
                {task.attachments?.length ? (
                  <p className="text-xs text-fg-muted">Attached: {task.attachments.map(path => path.split('/').pop()).join(', ')}</p>
                ) : null}
                {task.pendingApproval ? (
                  <Alert>
                    <ShieldQuestion className="size-4" aria-hidden />
                    <AlertDescription>
                      <div className="flex flex-wrap items-center gap-3">
                        <span className="min-w-0 flex-1 break-words">
                          <span className="font-medium">Wants to run </span>
                          <code className="text-xs">{task.pendingApproval.summary}</code>
                        </span>
                        <div className="flex gap-2">
                          <Button size="sm" onClick={() => void answer(task, task.pendingApproval!.id, true)}>Approve</Button>
                          {alwaysAllowOption(task.pendingApproval) ? (
                            <Button size="sm" variant="outline" onClick={() => void answer(task, task.pendingApproval!.id, true, alwaysAllowOption(task.pendingApproval!)!.id)}>
                              {alwaysAllowOption(task.pendingApproval)!.name}
                            </Button>
                          ) : null}
                          <Button size="sm" variant="outline" onClick={() => void answer(task, task.pendingApproval!.id, false)}>Deny</Button>
                        </div>
                      </div>
                    </AlertDescription>
                  </Alert>
                ) : null}
                {task.summary ? (
                  <p className="whitespace-pre-wrap rounded-md bg-bg-subtle p-3 text-sm text-fg-muted">{task.summary}</p>
                ) : null}
                {task.signIn?.length && running ? (
                  <SignInButtons methods={task.signIn} onSignIn={method => void signIn(task.agent, method)} />
                ) : null}
                {canReply(task) && running ? (
                  <ReplyForm onReply={text => act(() => client.replyToAgentTask(task.id, text), 'The reply was not sent.')} />
                ) : null}
              </div>
            </DashboardPanel>
          ))}
        </div>
      </div>
    </PageContainer>
  )
}

/** What the chosen agent is, whether it is installed, and how to sign in to it. */
function AgentDetails({ agent, isDefault, running, installing, onInstall, onSignIn, onSetEnv }: {
  agent: AgentListing; isDefault: boolean; running: boolean; installing: boolean
  onInstall: () => void; onSignIn: (method: SignInMethod) => void
  onSetEnv: (changes: { set?: Record<string, string>; remove?: string[] }) => Promise<boolean>
}) {
  const status = agent.signInStatus
  const statusMethod = agent.signIn?.find(method => method.id === status?.methodId)?.name ?? status?.methodId
  return (
    <div className="space-y-2 rounded-md border p-3 text-sm">
      <div className="flex flex-wrap items-center gap-2">
        <span className="font-medium">{agent.name}</span>
        <span className="text-xs text-fg-muted">{agent.version}</span>
        {isDefault ? <Badge variant="secondary">default</Badge> : null}
        {agent.installed ? <Badge variant="success">installed {agent.installed.version}</Badge> : <Badge variant="outline">runs on first use</Badge>}
        {agent.website || agent.repository ? (
          <a className="text-xs underline" href={agent.website ?? agent.repository ?? undefined} target="_blank" rel="noreferrer">About</a>
        ) : null}
        <div className="ml-auto">
          {!agent.installed || hasUpdate(agent) ? (
            <Button type="button" size="sm" variant="outline" disabled={!running || installing} onClick={onInstall}>
              {installing ? 'Installing…' : agent.installed ? `Update to ${agent.version}` : 'Install'}
            </Button>
          ) : null}
        </div>
      </div>
      {agent.description ? <p className="text-fg-muted">{agent.description}</p> : null}
      {agent.signIn?.length ? <SignInButtons methods={agent.signIn} onSignIn={onSignIn} disabled={!running || status?.status === 'running'} /> : null}
      {status ? (
        <p className={status.status === 'failed' ? 'text-danger' : 'text-fg-muted'}>
          {status.status === 'running' ? `Signing in with ${statusMethod}: finish it on your computer's screen.`
            : status.status === 'succeeded' ? `Signed in with ${statusMethod}.`
              : `Sign-in with ${statusMethod} failed${status.message ? `: ${status.message}` : '.'}`}
        </p>
      ) : null}
      <EnvEditor names={agent.env ?? []} disabled={!running} onChange={onSetEnv} />
    </div>
  )
}

/**
 * The agent's environment in the computer, for an API key or a provider's base URL. Values
 * are written there and never read back; only the names are shown.
 */
function EnvEditor({ names, disabled, onChange }: {
  names: string[]; disabled: boolean
  onChange: (changes: { set?: Record<string, string>; remove?: string[] }) => Promise<boolean>
}) {
  const [name, setName] = React.useState('')
  const [value, setValue] = React.useState('')
  const [saving, setSaving] = React.useState(false)
  const problem = name || value ? envProblem(name, value) : undefined
  async function save() {
    if (envProblem(name, value)) return
    setSaving(true)
    if (await onChange({ set: { [name.trim()]: value } })) { setName(''); setValue('') }
    setSaving(false)
  }
  return (
    // Inside the task form, so a group of its own rather than a nested form; Enter saves here.
    <div className="space-y-2 border-t pt-2" role="group" aria-label="Environment"
      onKeyDown={event => { if (event.key === 'Enter' && (event.target as HTMLElement).tagName === 'INPUT') { event.preventDefault(); void save() } }}>
      <div className="flex flex-wrap items-center gap-2">
        <span className="text-xs font-medium">Environment</span>
        {names.length ? names.map(entry => (
          <Badge key={entry} variant="outline" className="gap-1 font-mono">
            {entry}
            <button type="button" className="ml-1 text-fg-muted hover:text-danger" aria-label={`Remove ${entry}`} disabled={disabled}
              onClick={() => void onChange({ remove: [entry] })}>×</button>
          </Badge>
        )) : <span className="text-xs text-fg-muted">None. Add an API key here instead of signing in, if the agent takes one.</span>}
      </div>
      <div className="flex flex-wrap items-center gap-2">
        <input className="h-8 w-56 rounded-md border bg-transparent px-2 font-mono text-xs" placeholder="OPENROUTER_API_KEY" aria-label="Variable name"
          value={name} onChange={event => setName(event.target.value)} disabled={disabled} autoComplete="off" spellCheck={false} />
        <input className="h-8 w-64 rounded-md border bg-transparent px-2 text-xs" type="password" placeholder="Value" aria-label="Value"
          value={value} onChange={event => setValue(event.target.value)} disabled={disabled} autoComplete="new-password" />
        <Button type="button" size="sm" variant="outline" disabled={disabled || saving || !name || !value || Boolean(problem)} onClick={() => void save()}>
          {saving ? 'Saving…' : names.includes(name.trim()) ? 'Replace' : 'Add'}
        </Button>
      </div>
      {problem && name && value ? <p className="text-xs text-danger">{problem}</p> : null}
      <p className="text-xs text-fg-muted">Kept in the computer for this agent only (mode 0600) and never shown again.</p>
    </div>
  )
}

function SignInButtons({ methods, onSignIn, disabled }: { methods: SignInMethod[]; onSignIn: (method: SignInMethod) => void; disabled?: boolean }) {
  return (
    <div className="flex flex-wrap items-center gap-2">
      <KeyRound className="size-4 text-fg-muted" aria-hidden />
      {methods.map(method => (
        <Button key={method.id} type="button" size="sm" variant="outline" disabled={disabled} title={method.description} onClick={() => onSignIn(method)}>
          Sign in: {method.name}
        </Button>
      ))}
      <span className="text-xs text-fg-muted">Opens on your computer's screen.</span>
    </div>
  )
}

/** Continues a finished task's conversation; the agent picks up where it stopped. */
function ReplyForm({ onReply }: { onReply: (text: string) => Promise<boolean> }) {
  const [text, setText] = React.useState('')
  const [sending, setSending] = React.useState(false)
  async function send(event: React.FormEvent) {
    event.preventDefault()
    const trimmed = text.trim()
    if (!trimmed) return
    setSending(true)
    try {
      if (await onReply(trimmed)) setText('')
    } finally {
      setSending(false)
    }
  }
  return (
    <form className="flex items-end gap-2" onSubmit={send}>
      <Textarea
        aria-label="Reply to the agent"
        placeholder="Reply to continue this task…"
        rows={1}
        maxLength={32_000}
        className="min-h-9 flex-1"
        value={text}
        onChange={event => setText(event.target.value)}
      />
      <Button type="submit" size="sm" variant="outline" disabled={sending || !text.trim()}>
        {sending ? 'Sending…' : 'Reply'}
      </Button>
    </form>
  )
}
