import * as React from 'react'
import { DashboardPanel } from '@braedonsaunders/appkit-dashboard/primitives'
import {
  Alert, AlertDescription, Badge, Button, EmptyState, Label, PageContainer, PageHeader, Select, Switch, Textarea, toast,
} from '@braedonsaunders/appkit-ui'
import { Bot, ShieldQuestion } from 'lucide-react'
import { CabooseApiError, canAskFirst, canReply, type AgentKind, type AgentTask, type CabooseClient } from '../api.js'
import { isLiveTask, taskTone } from '../state.js'
import type { ComputerHandle } from '../useComputer.js'

const POLL_MS = 5_000
/** Faster while an agent works, so a request for approval shows up promptly. */
const LIVE_POLL_MS = 2_000

export function Agents({ client, computer, onUnauthorized }: { client: CabooseClient; computer: ComputerHandle; onUnauthorized: () => void }) {
  const [tasks, setTasks] = React.useState<AgentTask[] | null>(null)
  const [error, setError] = React.useState<string | null>(null)
  const [prompt, setPrompt] = React.useState('')
  const [agent, setAgent] = React.useState<AgentKind>('claude')
  const [askFirst, setAskFirst] = React.useState(false)
  const [starting, setStarting] = React.useState(false)
  const running = computer.status?.state === 'running'

  const refresh = React.useCallback(async () => {
    try {
      setTasks(await client.agentTasks())
      setError(null)
    } catch (failure) {
      if (failure instanceof CabooseApiError && failure.isUnauthorized) onUnauthorized()
      else setError(failure instanceof Error ? failure.message : String(failure))
    }
  }, [client, onUnauthorized])

  const anyLive = tasks?.some(task => isLiveTask(task.status)) ?? false
  React.useEffect(() => { void refresh() }, [refresh])
  React.useEffect(() => {
    const timer = window.setInterval(() => { if (document.visibilityState === 'visible') void refresh() }, anyLive ? LIVE_POLL_MS : POLL_MS)
    return () => window.clearInterval(timer)
  }, [refresh, anyLive])

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

  async function answer(task: AgentTask, requestId: string, allow: boolean) {
    await act(async () => {
      const { resolved } = await client.resolveAgentApproval(task.id, requestId, allow)
      if (!resolved) toast.info('That request was already answered or has ended.')
    }, allow ? 'Could not approve.' : 'Could not deny.')
  }

  async function start(event: React.FormEvent) {
    event.preventDefault()
    const text = prompt.trim()
    if (!text) return
    setStarting(true)
    try {
      await client.startAgentTask({ prompt: text, agent, approvals: askFirst ? 'ask' : 'auto' })
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

  return (
    <PageContainer>
      <div className="mx-auto max-w-4xl space-y-6">
        <PageHeader
          title="Agents"
          description="Claude Code and Codex work inside your computer on their own seat, signed in with your accounts. A running task keeps the computer awake."
        />

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
              <Select className="w-40" value={agent} onChange={event => setAgent(event.target.value as AgentKind)} disabled={!running}>
                <option value="claude">Claude Code</option>
                <option value="codex">Codex</option>
              </Select>
              <label className="flex items-center gap-2 text-sm" title={canAskFirst(agent) ? undefined : 'Codex cannot stop to ask; it works in its sandbox.'}>
                <Switch
                  checked={askFirst && canAskFirst(agent)}
                  onChange={event => setAskFirst(event.target.checked)}
                  disabled={!running || !canAskFirst(agent)}
                />
                Ask before acting
              </label>
              <Button type="submit" disabled={!running || starting || !prompt.trim()}>
                {starting ? 'Starting…' : 'Start task'}
              </Button>
              {!running ? <span className="text-sm text-muted-foreground">Wake the computer to start a task.</span> : null}
            </div>
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
                  <span className="text-sm font-medium">{task.agent === 'codex' ? 'Codex' : 'Claude Code'}</span>
                  <span className="text-xs text-muted-foreground">{new Date(task.startedAt).toLocaleString()}</span>
                  {task.approvals === 'ask' ? <Badge variant="secondary">asks first</Badge> : null}
                  {(task.turns ?? 1) > 1 ? <span className="text-xs text-muted-foreground">{task.turns} turns</span> : null}
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
                  <p className="text-xs text-muted-foreground">Attached: {task.attachments.map(path => path.split('/').pop()).join(', ')}</p>
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
                          <Button size="sm" variant="outline" onClick={() => void answer(task, task.pendingApproval!.id, false)}>Deny</Button>
                        </div>
                      </div>
                    </AlertDescription>
                  </Alert>
                ) : null}
                {task.summary ? (
                  <p className="whitespace-pre-wrap rounded-md bg-muted p-3 text-sm text-muted-foreground">{task.summary}</p>
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
