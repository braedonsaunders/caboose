import type { DesktopNotification } from './desktop-notifications.js'
import type { AgentEvent } from './agents.js'
import { APNsSender, type APNsEnvironment, type APNsMessage, type APNsResult } from './apns.js'
import { readJsonFile, SettingsInputError, writePrivateJson } from './settings.js'

type Kind = 'approval' | 'task' | 'desktop'
export interface PushDevice { token: string; environment: APNsEnvironment; kinds: Kind[] }
const TOKEN = /^(?:[0-9a-f]{2}){1,256}$/
export function parseDevice(input: unknown): PushDevice {
  if (!input || typeof input !== 'object' || Array.isArray(input)) throw new SettingsInputError('device must be an object')
  const value = input as Record<string, unknown>
  if (Object.keys(value).some(key => !['token', 'environment', 'kinds'].includes(key)) || typeof value.token !== 'string' || !TOKEN.test(value.token) || (value.environment !== 'sandbox' && value.environment !== 'production') || !Array.isArray(value.kinds) || value.kinds.some(kind => kind !== 'approval' && kind !== 'task' && kind !== 'desktop') || new Set(value.kinds).size !== value.kinds.length) throw new SettingsInputError('invalid push device')
  return { token: value.token, environment: value.environment, kinds: value.kinds as Kind[] }
}
export class PushDevices {
  private pending: Promise<void> = Promise.resolve()
  private revisions = new Map<string, number>()
  private constructor(private path: string, private devices: PushDevice[]) {}
  static async open(path: string): Promise<PushDevices> {
    const value = await readJsonFile(path)
    if (value !== undefined && !Array.isArray(value)) throw new Error('Invalid push device store')
    const devices = (value ?? []).map(parseDevice)
    if (new Set(devices.map(d => d.token)).size !== devices.length) throw new Error('Duplicate push device')
    return new PushDevices(path, devices)
  }
  list(): PushDevice[] { return this.devices.map(d => ({ ...d, kinds: [...d.kinds] })) }
  private mutate(change: (devices: PushDevice[]) => PushDevice[]): Promise<void> {
    const work = this.pending.then(async () => {
      const next = change(this.list())
      await writePrivateJson(this.path, next)
      this.devices = next
    })
    this.pending = work.catch(() => {})
    return work
  }
  register(input: unknown): Promise<void> {
    const device = parseDevice(input)
    return this.mutate(devices => {
      this.revisions.set(device.token, (this.revisions.get(device.token) ?? 0) + 1)
      return [...devices.filter(d => d.token !== device.token), device]
    })
  }
  version(token: string): number { return this.revisions.get(token) ?? 0 }
  remove(token: unknown, environment?: APNsEnvironment, expectedRevision?: number): Promise<void> {
    if (typeof token !== 'string' || !TOKEN.test(token)) throw new SettingsInputError('invalid push token')
    return this.mutate(devices => expectedRevision !== undefined && this.version(token) !== expectedRevision ? devices : devices.filter(d => d.token !== token || (environment !== undefined && d.environment !== environment)))
  }
}
const bounded = (text: string) => Array.from(text).slice(0, 700).join('')
export function notificationFor(event: AgentEvent): { kind: Kind; payload: object; collapseId: string } | undefined {
  if (event.type === 'agent.task.approval') return {
    kind: 'approval', collapseId: `approval-${event.request.id}`,
    payload: { aps: { alert: { title: 'Approval requested', body: bounded(event.request.summary || event.request.tool) }, category: 'AGENT_APPROVAL', 'thread-id': `task-${event.id}`, sound: 'default' }, taskId: event.id, approvalId: event.request.id },
  }
  if (event.type === 'agent.task.finished' && (event.status === 'succeeded' || event.status === 'failed')) return {
    kind: 'task', collapseId: `task-${event.id}`,
    payload: { aps: { alert: { title: event.status === 'succeeded' ? 'Task finished' : 'Task failed', body: bounded(event.summary || 'Open Caboose to see the task.') }, 'thread-id': `task-${event.id}`, sound: 'default' }, taskId: event.id },
  }
  return undefined
}
export class PushService {
  constructor(readonly devices: PushDevices, private sender: Pick<APNsSender, 'send'>) {}
  async event(event: AgentEvent, foreground: boolean): Promise<void> {
    const notification = notificationFor(event)
    if (!notification || foreground) return
    await this.deliver(notification)
  }
  async desktop(event: DesktopNotification, foreground: boolean): Promise<void> {
    if (foreground) return
    await this.deliver({ kind: 'desktop', collapseId: `desktop-${event.id}`, payload: { aps: { alert: { title: bounded(event.summary || event.app || 'Desktop notification'), body: bounded(event.body) }, 'thread-id': `desktop-${bounded(event.app).slice(0, 40)}`, sound: 'default' } } })
  }
  private async deliver(notification: { kind: Kind; payload: object; collapseId: string }): Promise<void> {
    await Promise.all(this.devices.list().filter(device => device.kinds.includes(notification.kind)).map(async device => {
      try {
        const revision = this.devices.version(device.token)
        const result: APNsResult = await this.sender.send({ ...device, payload: notification.payload, collapseId: notification.collapseId } as APNsMessage)
        if (result.status === 410 && result.reason === 'Unregistered') await this.devices.remove(device.token, device.environment, revision)
        else if (result.status !== 200) console.error(`APNs rejected notification: ${result.status} ${result.reason ?? ''}`)
      } catch (error) { console.error('APNs delivery failed:', error instanceof Error ? error.message : 'unknown error') }
    }))
  }
}
