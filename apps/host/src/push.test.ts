import { mkdtemp, readFile, rm, stat } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, expect, it, vi } from 'vitest'
import { notificationFor, PushDevices, PushService } from './push.js'

const roots: string[] = []
afterEach(async () => { await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))) })
async function store() {
  const root = await mkdtemp(join(tmpdir(), 'caboose-push-')); roots.push(root)
  const path = join(root, 'devices.json')
  return { path, devices: await PushDevices.open(path) }
}
const token = 'ab'.repeat(32)
const approval = { type: 'agent.task.approval' as const, id: 'task-id', request: { id: 'request-id', tool: 'shell', summary: 'Run command' } }
it('validates and persists device registrations atomically and privately', async () => {
  const { path, devices } = await store()
  expect(() => devices.register({ token: 'bad', environment: 'sandbox', kinds: [] })).toThrow()
  await Promise.all([devices.register({ token, environment: 'sandbox', kinds: ['approval'] }), devices.register({ token: 'cd'.repeat(32), environment: 'production', kinds: ['task'] })])
  expect((await stat(path)).mode & 0o777).toBe(0o600)
  expect(JSON.parse(await readFile(path, 'utf8'))).toHaveLength(2)
  expect((await PushDevices.open(path)).list()).toEqual(devices.list())
  await devices.remove(token)
  expect(devices.list()).toHaveLength(1)
})
it('builds only approval and completed task alerts with grouping', () => {
  expect(notificationFor(approval)).toMatchObject({ kind: 'approval', collapseId: 'approval-request-id', payload: { taskId: 'task-id', approvalId: 'request-id', aps: { category: 'AGENT_APPROVAL', 'thread-id': 'task-task-id' } } })
  expect(notificationFor({ type: 'agent.task.finished', id: 'id', status: 'failed', summary: 'failed' })).toMatchObject({ kind: 'task' })
  expect(notificationFor({ type: 'agent.task.finished', id: 'id', status: 'cancelled', summary: '' })).toBeUndefined()
  expect(notificationFor({ type: 'agent.task.paused', id: 'id' })).toBeUndefined()
})
it('respects foreground and per-device kinds, and removes an unregistered token', async () => {
  const { devices } = await store()
  await devices.register({ token, environment: 'sandbox', kinds: ['approval'] })
  const send = vi.fn(async () => ({ status: 410, reason: 'Unregistered' }))
  const push = new PushService(devices, { send })
  await push.event(approval, true)
  await push.event({ type: 'agent.task.finished', id: 'id', status: 'failed', summary: '' }, false)
  expect(send).not.toHaveBeenCalled()
  await push.event(approval, false)
  expect(send).toHaveBeenCalledOnce()
  expect(devices.list()).toEqual([])
})
it('does not delete a device re-registered while a push is in flight', async () => {
  const { devices } = await store()
  await devices.register({ token, environment: 'sandbox', kinds: ['approval'] })
  let complete!: (value: { status: number; reason: string }) => void
  const push = new PushService(devices, { send: () => new Promise(resolve => { complete = resolve }) })
  const pending = push.event(approval, false)
  await devices.register({ token, environment: 'sandbox', kinds: ['approval'] })
  complete({ status: 410, reason: 'Unregistered' })
  await pending
  expect(devices.list()).toHaveLength(1)
})
