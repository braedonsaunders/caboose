import type { AgentEvent } from './agents.js'
import type { APNsEnvironment, APNsMessage, APNsResult } from './apns.js'
import { readJsonFile, SettingsInputError, writePrivateJson } from './settings.js'

type Status = 'running' | 'paused' | 'succeeded' | 'failed' | 'cancelled'
export interface Job { id: string; kind: string; title: string; status: Status; detail: string }
interface Activity { token: string; environment: APNsEnvironment; jobId: string; activityId: string }
interface StartDevice { token: string; environment: APNsEnvironment; deviceId: string; phone?: string }
interface State { activities: Activity[]; starters: StartDevice[]; jobs: Job[] }
const idPattern = /^[A-Za-z0-9._-]{1,100}$/
const tokenPattern = /^(?:[0-9a-f]{2}){1,256}$/
function object(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new SettingsInputError('expected object')
  return value as Record<string, unknown>
}
function string(value: unknown, name: string, pattern: RegExp): string {
  if (typeof value !== 'string' || !pattern.test(value)) throw new SettingsInputError(`invalid ${name}`)
  return value
}
function environment(value: unknown): APNsEnvironment {
  if (value !== 'sandbox' && value !== 'production') throw new SettingsInputError('invalid environment')
  return value
}
function activity(value: unknown): Activity {
  const v = object(value)
  return { token: string(v.token, 'token', tokenPattern), environment: environment(v.environment), jobId: string(v.jobId, 'jobId', idPattern), activityId: string(v.activityId, 'activityId', idPattern) }
}
function starter(value: unknown): StartDevice {
  const v = object(value)
  return { token: string(v.token, 'token', tokenPattern), environment: environment(v.environment), deviceId: string(v.deviceId, 'deviceId', tokenPattern) }
}
/** A stored starter keeps the phone sign-in that registered it. */
function storedStarter(value: unknown): StartDevice {
  const item = starter(value)
  const phone = object(value).phone
  if (phone === undefined) return item
  return { ...item, phone: string(phone, 'phone', /^p-[0-9a-f]{12}$/) }
}
export function parseJob(value: unknown): Job {
  const v = object(value)
  const status = v.status
  if (status !== 'running' && status !== 'paused' && status !== 'succeeded' && status !== 'failed' && status !== 'cancelled') throw new SettingsInputError('invalid job status')
  if (typeof v.title !== 'string' || !v.title.trim() || v.title.length > 200 || typeof v.detail !== 'string' || v.detail.length > 500) throw new SettingsInputError('invalid job title or detail')
  return { id: string(v.id, 'job id', idPattern), kind: string(v.kind, 'job kind', idPattern), title: v.title, status, detail: v.detail }
}
export class ActivityStore {
  private pending: Promise<void> = Promise.resolve()
  private revisions = new Map<string, number>()
  private constructor(private path: string, private state: State) {}
  static async open(path: string) {
    const raw = await readJsonFile(path)
    if (raw === undefined) return new ActivityStore(path, { activities: [], starters: [], jobs: [] })
    const value = object(raw)
    if (!Array.isArray(value.activities) || !Array.isArray(value.starters)) throw new Error('invalid activity store')
    if (value.jobs !== undefined && !Array.isArray(value.jobs)) throw new Error('invalid activity jobs')
    return new ActivityStore(path, { activities: value.activities.map(activity), starters: value.starters.map(storedStarter), jobs: (value.jobs ?? []).map(parseJob) })
  }
  list(): State { return structuredClone(this.state) }
  private update(change: (state: State) => void): Promise<void> {
    const work = this.pending.then(async () => { const next = this.list(); change(next); await writePrivateJson(this.path, next); this.state = next })
    this.pending = work.catch(() => {})
    return work
  }
  version(key: string): number { return this.revisions.get(key) ?? 0 }
  private bump(key: string) { this.revisions.set(key, this.version(key) + 1) }
  recordJob(job: Job) { return this.update(state => { state.jobs = [...state.jobs.filter(v => v.id !== job.id), job].slice(-200) }) }
  registerActivity(input: unknown) { const item = activity(input); return this.update(state => { this.bump(`a:${item.activityId}`); state.activities = [...state.activities.filter(v => v.activityId !== item.activityId), item] }) }
  registerStarter(input: unknown, phone?: string) { const item: StartDevice = { ...starter(input), ...(phone ? { phone } : {}) }; return this.update(state => { this.bump(`s:${item.deviceId}`); state.starters = [...state.starters.filter(v => v.deviceId !== item.deviceId), item] }) }
  removeActivity(activityId: string, token?: string, revision?: number) { return this.update(state => { if (revision !== undefined && revision !== this.version(`a:${activityId}`)) return; state.activities = state.activities.filter(v => v.activityId !== activityId || (token !== undefined && v.token !== token)) }) }
  /** Signing a phone out stops Live Activities it registered for. */
  removeByPhone(phone: string) { return this.update(state => { state.starters = state.starters.filter(v => v.phone !== phone) }) }
  removeStarter(deviceId: string, token?: string, revision?: number) { return this.update(state => { if (revision !== undefined && revision !== this.version(`s:${deviceId}`)) return; state.starters = state.starters.filter(v => v.deviceId !== deviceId || (token !== undefined && v.token !== token)) }) }
}
export type ActivitySend = (message: APNsMessage) => Promise<APNsResult>
export function activityPayload(job: Job, event: 'start' | 'update' | 'end', now: number): object {
  const aps: Record<string, unknown> = { timestamp: Math.floor(now / 1000), event, 'content-state': { status: job.status, detail: job.detail } }
  if (event === 'start') Object.assign(aps, { 'input-push-token': 1, 'attributes-type': 'JobAttributes', attributes: { jobID: job.id, kind: job.kind, title: job.title }, alert: { title: job.title, body: job.detail || 'Working…' } })
  if (event === 'end') aps['dismissal-date'] = Math.floor(now / 1000) + 3600
  return { aps }
}
export function agentJob(event: AgentEvent): Job | undefined {
  switch (event.type) {
    case 'agent.task.started': return { id: event.id, kind: 'agent', title: (event.agentName || event.agent || 'Agent task').slice(0, 200), status: 'running', detail: event.prompt.slice(0, 500) }
    case 'agent.task.replied': return { id: event.id, kind: 'agent', title: 'Agent task', status: 'running', detail: event.prompt.slice(0, 500) }
    case 'agent.task.paused': return { id: event.id, kind: 'agent', title: 'Agent task', status: 'paused', detail: 'Paused' }
    case 'agent.task.resumed': return { id: event.id, kind: 'agent', title: 'Agent task', status: 'running', detail: 'Working…' }
    case 'agent.task.finished': return { id: event.id, kind: 'agent', title: 'Agent task', status: event.status === 'running' || event.status === 'paused' ? 'failed' : event.status, detail: event.summary.slice(0, 500) }
    default: return undefined
  }
}
export class ActivityService {
  private pending = new Map<string, Promise<void>>()
  constructor(readonly store: ActivityStore, private send: ActivitySend, private topic: string, private now: () => number = Date.now) {}
  job(job: Job, start: boolean, foreground: boolean): Promise<void> {
    const previous = this.pending.get(job.id) ?? Promise.resolve()
    const next = previous.catch(() => {}).then(() => this.deliver(job, start, foreground))
    this.pending.set(job.id, next)
    return next.finally(() => { if (this.pending.get(job.id) === next) this.pending.delete(job.id) })
  }
  async reconcile(activityId: string): Promise<void> {
    const snapshot = this.store.list()
    const item = snapshot.activities.find(value => value.activityId === activityId)
    if (!item) return
    await this.pending.get(item.jobId)?.catch(() => {})
    const job = this.store.list().jobs.find(value => value.id === item.jobId)
    if (job) await this.job(job, false, true)
  }
  private async deliver(job: Job, start: boolean, foreground: boolean): Promise<void> {
    await this.store.recordJob(job)
    const snapshot = this.store.list()
    const ended = job.status === 'succeeded' || job.status === 'failed' || job.status === 'cancelled'
    await Promise.all(snapshot.activities.filter(item => item.jobId === job.id).map(async item => {
      try {
        const revision = this.store.version(`a:${item.activityId}`)
        const result = await this.send({ token: item.token, environment: item.environment, topic: `${this.topic}.push-type.liveactivity`, pushType: 'liveactivity', payload: activityPayload(job, ended ? 'end' : 'update', this.now()) })
        if ((result.status === 410 && result.reason === 'Unregistered') || (ended && result.status === 200)) await this.store.removeActivity(item.activityId, item.token, revision)
        else if (result.status !== 200) console.error(`APNs rejected Live Activity update: ${result.status} ${result.reason ?? ''}`)
      } catch (error) { console.error('Live Activity delivery failed:', error instanceof Error ? error.message : 'unknown error') }
    }))
    if (start && !foreground && !ended) await Promise.all(snapshot.starters.map(async item => {
      try {
        const revision = this.store.version(`s:${item.deviceId}`)
        const result = await this.send({ token: item.token, environment: item.environment, topic: `${this.topic}.push-type.liveactivity`, pushType: 'liveactivity', payload: activityPayload(job, 'start', this.now()) })
        if (result.status === 410 && result.reason === 'Unregistered') await this.store.removeStarter(item.deviceId, item.token, revision)
        else if (result.status !== 200) console.error(`APNs rejected Live Activity start: ${result.status} ${result.reason ?? ''}`)
      } catch (error) { console.error('Live Activity start failed:', error instanceof Error ? error.message : 'unknown error') }
    }))
  }
}
