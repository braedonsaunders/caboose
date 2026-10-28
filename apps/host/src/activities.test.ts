import { mkdtemp, rm, stat } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, expect, it, vi } from 'vitest'
import type { APNsMessage } from './apns.js'
import { ActivityService, ActivityStore, activityPayload, agentJob, parseJob } from './activities.js'
const roots: string[] = []
afterEach(async () => { await Promise.all(roots.splice(0).map(root => rm(root, { recursive: true, force: true }))) })
const token = 'ab'.repeat(32)
const job = { id: 'job-1', kind: 'agent', title: 'Agent', status: 'running' as const, detail: 'Working' }
async function store() {
  const root = await mkdtemp(join(tmpdir(), 'activities-')); roots.push(root)
  const path = join(root, 'activities.json')
  return { store: await ActivityStore.open(path), path }
}
it('validates generic job state and builds ActivityKit APNs envelopes', () => {
  expect(parseJob(job)).toEqual(job)
  expect(() => parseJob({ ...job, status: 'unknown' })).toThrow()
  expect(activityPayload(job, 'start', 123_000)).toEqual({ aps: { timestamp: 123, event: 'start', 'content-state': { status: 'running', detail: 'Working' }, 'input-push-token': 1, 'attributes-type': 'JobAttributes', attributes: { jobID: 'job-1', kind: 'agent', title: 'Agent' }, alert: { title: 'Agent', body: 'Working' } } })
  expect(activityPayload({ ...job, status: 'succeeded' }, 'end', 123_000)).toMatchObject({ aps: { event: 'end', 'dismissal-date': 3723 } })
  expect(agentJob({ type: 'agent.task.output', id: 'job-1', kind: 'text', text: 'output' })).toBeUndefined()
})
it('persists activity and start tokens privately, sends starts, updates and ends', async () => {
  const { store: devices, path } = await store()
  await devices.registerStarter({ token, environment: 'sandbox', deviceId: 'bb' })
  await devices.registerActivity({ token, environment: 'sandbox', jobId: job.id, activityId: 'activity' })
  expect((await stat(path)).mode & 0o777).toBe(0o600)
  expect((await ActivityStore.open(path)).list()).toEqual(devices.list())
  const send = vi.fn(async (_message: APNsMessage) => ({ status: 200 }))
  const service = new ActivityService(devices, send, 'example.app', () => 123_000)
  await service.job(job, true, true)
  expect(send).toHaveBeenCalledTimes(1)
  expect(send.mock.calls[0]![0]).toMatchObject({ topic: 'example.app.push-type.liveactivity', pushType: 'liveactivity', payload: { aps: { event: 'update' } } })
  await service.job(job, true, false)
  expect(send).toHaveBeenCalledTimes(3)
  expect(send.mock.calls[2]![0]).toMatchObject({ payload: { aps: { event: 'start' } } })
  await service.job({ ...job, status: 'succeeded' }, false, false)
  expect(devices.list().activities).toEqual([])
})
it('removes only the expired token, not one replaced while sending', async () => {
  const { store: devices } = await store()
  await devices.registerActivity({ token, environment: 'sandbox', jobId: job.id, activityId: 'activity' })
  let complete!: (result: { status: number; reason: string }) => void
  const service = new ActivityService(devices, () => new Promise(resolve => { complete = resolve }), 'example.app')
  const pending = service.job(job, false, false)
  await vi.waitFor(() => expect(complete).toBeTypeOf('function'))
  await devices.registerActivity({ token: 'cd'.repeat(32), environment: 'sandbox', jobId: job.id, activityId: 'activity' })
  complete({ status: 410, reason: 'Unregistered' })
  await pending
  expect(devices.list().activities[0]?.token).toBe('cd'.repeat(32))
})


it('reconciles a late update token with a job that already ended', async () => {
  const { store: devices } = await store()
  const send = vi.fn(async (_message: APNsMessage) => ({ status: 200 }))
  const service = new ActivityService(devices, send, 'example.app')
  await service.job({ ...job, status: 'failed', detail: 'Failed' }, false, false)
  await devices.registerActivity({ token, environment: 'production', jobId: job.id, activityId: 'late' })
  await service.reconcile('late')
  expect(send).toHaveBeenCalledOnce()
  expect(send.mock.calls[0]![0]).toMatchObject({ payload: { aps: { event: 'end', 'content-state': { status: 'failed' } } } })
  expect(devices.list().activities).toEqual([])
})
