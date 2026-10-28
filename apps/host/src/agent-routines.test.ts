import { describe, it, expect } from 'vitest'
import { mkdtemp, readFile, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { AgentRoutines, type RoutineState, type RoutineTask, type RoutineClock, type RoutineRuntime, type RoutineOptions } from './agent-routines.js'

const profileId = '11111111-1111-4111-8111-111111111111'
const base = Date.parse('2026-01-01T00:00:00.000Z')
function fixture() {
  let now = base, stored: RoutineState | undefined, fail = false, revision = 'v1', available = true
  const tasks = new Map<string, RoutineTask>(), calls: Array<{ id: string; input: Record<string, unknown> }> = [], errors: unknown[] = []
  const timers = new Map<number, () => void>(); let timerId = 0, leases = 0, writes = 0
  const clock: RoutineClock = { now: () => now, setTimeout: fn => { timers.set(++timerId, fn); return timerId }, clearTimeout: timer => { timers.delete(timer as number) } }
  const runtime: RoutineRuntime = {
    snapshot: async (_id, prompt) => available ? { revision, input: { prompt, envelope: { revision } } } : null,
    acquire: async () => { leases++; return () => { leases-- } },
    lookup: async id => tasks.get(id) ?? null,
    start: async (input, id) => { calls.push({ id, input }); const task: RoutineTask = { status: 'active' }; tasks.set(id, task); return task },
  }
  const persistence = { load: async () => structuredClone(stored), save: async (state: RoutineState) => { if (fail) throw new Error('disk failure'); stored = structuredClone(state); writes++ } }
  const options: RoutineOptions = { runtime, clock, onError: error => { errors.push(error) } }
  return { options, runtime, persistence, tasks, calls, errors, timers, now: (value: number) => { now = base + value }, fail: (value: boolean) => { fail = value }, profile: (value: string, present = true) => { revision = value; available = present }, store: () => structuredClone(stored), leases: () => leases, writes: () => writes, open: () => AgentRoutines.create(persistence, options), input: (extra = {}) => ({ name: 'Daily summary', profileId, prompt: 'Summarize', schedule: { kind: 'interval', timeZone: 'UTC', everyMs: 60_000, anchor: new Date(base).toISOString() }, ...extra }) }
}

describe('durable computer routines', () => {
  it('delivers a normally late polling tick inside explicit grace and skips overdue ticks', async () => {
    const f = fixture(), s = await f.open(), r = await s.create(f.input())
    f.now(60_010); await s.tick()
    expect(f.calls).toHaveLength(1); expect(s.history()[0]?.scheduledAt).toBe(new Date(base + 60_000).toISOString())
    f.tasks.set(f.calls[0]!.id, { status: 'succeeded' }); f.now(301_000); await s.tick()
    expect(f.calls).toHaveLength(1); expect(s.get(r.id).nextAt).toBe(new Date(base + 360_000).toISOString()); expect(f.leases()).toBe(0)
    await s.close()
  })
  it('coalesces oldest persisted due once and discards all overlap ticks', async () => {
    const f = fixture(), s = await f.open(); await s.create(f.input({ missed: 'coalesce' }))
    f.now(301_000); await s.tick(); expect(f.calls).toHaveLength(1)
    expect(s.history()[0]?.scheduledAt).toBe(new Date(base + 60_000).toISOString())
    f.now(601_000); await s.tick(); expect(f.calls).toHaveLength(1)
    f.tasks.set(f.calls[0]!.id, { status: 'succeeded' }); await s.tick(); expect(f.calls).toHaveLength(1)
    f.now(660_000); await s.tick(); expect(f.calls).toHaveLength(2); await s.close()
  })
  it('reserves manual runs durably and refuses paused or overlapping manual runs', async () => {
    const f = fixture(), s = await f.open(), r = await s.create(f.input()), run = await s.runNow(r.id)
    expect(f.store()?.runs[0]?.id).toBe(run.id); expect(f.calls).toHaveLength(0)
    await expect(s.runNow(r.id)).rejects.toThrow('already active')
    await s.update(r.id, { paused: true }); await s.tick(); expect(s.history()[0]?.status).toBe('skipped'); expect(f.calls).toHaveLength(0)
    await expect(s.runNow(r.id)).rejects.toThrow('paused'); await s.close()
  })
  it.each(['pause', 'edit', 'delete', 'profile edit', 'archive'] as const)('revalidates %s after wake before dispatch', async action => {
    const f = fixture(), s = await f.open(), r = await s.create(f.input()); await s.runNow(r.id)
    let wake!: () => void, entered!: () => void
    const waiting = new Promise<void>(resolve => { entered = resolve })
    f.runtime.acquire = async () => { entered(); await new Promise<void>(resolve => { wake = resolve }); return () => {} }
    const tick = s.tick(); await waiting
    if (action === 'pause') await s.update(r.id, { paused: true })
    if (action === 'edit') await s.update(r.id, { prompt: 'New prompt' })
    if (action === 'delete') await s.delete(r.id)
    if (action === 'profile edit') f.profile('v2')
    if (action === 'archive') f.profile('v2', false)
    wake(); await tick
    expect(f.calls).toHaveLength(0); expect(s.history()[0]?.status).toBe('skipped'); await s.close()
  })
  it('recovers an ambiguous launch using the same task UUID and original envelope', async () => {
    const f = fixture(), s = await f.open(), r = await s.create(f.input()), reserved = await s.runNow(r.id)
    const start = f.runtime.start
    f.runtime.start = async (input, id) => { await start(input, id); throw new Error('connection lost after admission') }
    await s.tick(); expect(s.history()[0]?.status).toBe('reserved'); expect(s.history()[0]?.detail).toContain('connection lost')
    await s.close(); const restarted = await f.open(); await restarted.tick()
    expect(f.calls).toHaveLength(1); expect(f.calls[0]?.id).toBe(reserved.id); expect(restarted.history()[0]?.status).toBe('active')
    f.tasks.set(reserved.id, { status: 'failed', detail: 'Uncertain effects; intervention required' }); await restarted.tick()
    expect(restarted.history()[0]?.detail).toContain('Uncertain'); expect(f.calls).toHaveLength(1); await restarted.close()
  })
  it('retries a definitely absent reserved task using the same UUID', async () => {
    const f = fixture(), s = await f.open(), r = await s.create(f.input()), run = await s.runNow(r.id)
    const start = f.runtime.start; f.runtime.start = async () => { throw new Error('before admission') }
    await s.tick(); await s.close(); f.runtime.start = start
    const restarted = await f.open(); await restarted.tick(); expect(f.calls[0]?.id).toBe(run.id); expect(f.calls[0]?.input).toEqual({ prompt: 'Summarize', envelope: { revision: 'v1' } }); await restarted.close()
  })
  it('never restarts a missing previously active task', async () => {
    const f = fixture(), s = await f.open(), r = await s.create(f.input()); const run = await s.runNow(r.id); await s.tick(); f.tasks.delete(run.id); await s.tick()
    expect(s.history()[0]?.status).toBe('failed'); expect(f.calls).toHaveLength(1); await s.close()
  })
  it('atomically persists cursor and reservation and latches storage failures closed', async () => {
    const f = fixture(), s = await f.open(), r = await s.create(f.input()); f.fail(true); f.now(60_000)
    await expect(s.tick()).rejects.toThrow('disk failure'); expect(f.calls).toHaveLength(0)
    expect(f.store()?.routines[0]?.nextAt).toBe(new Date(base + 60_000).toISOString()); expect(f.store()?.runs).toHaveLength(0)
    f.fail(false); await expect(s.runNow(r.id)).rejects.toThrow('reopen'); await s.close()
    const restarted = await f.open(); await restarted.tick(); expect(f.calls).toHaveLength(1); await restarted.close()
  })
  it('recovers admission when saving launch status fails', async () => {
    const f = fixture(), s = await f.open(), r = await s.create(f.input()); const run = await s.runNow(r.id), start = f.runtime.start
    f.runtime.start = async (input, id) => { const task = await start(input, id); f.fail(true); return task }
    await s.tick(); expect(f.store()?.runs[0]?.status).toBe('reserved'); await s.close(); f.fail(false)
    const restarted = await f.open(); await restarted.tick(); expect(f.calls).toHaveLength(1); expect(restarted.history()[0]?.id).toBe(run.id); await restarted.close()
  })
  it('serializes concurrent ticks and manual reservations', async () => {
    const f = fixture(), s = await f.open(), r = await s.create(f.input())
    const results = await Promise.allSettled([s.runNow(r.id), s.runNow(r.id)])
    expect(results.filter(r => r.status === 'fulfilled')).toHaveLength(1)
    await Promise.all([s.tick(), s.tick(), s.tick()]); expect(f.calls).toHaveLength(1); await s.close()
  })
  it('reconciles missed profile edits across file boundaries without a coalesced backlog', async () => {
    const f = fixture(), s = await f.open(), r = await s.create(f.input({ missed: 'coalesce' })); await s.close()
    f.profile('archived', false); f.now(300_000); const restarted = await f.open(); await restarted.tick(); expect(f.calls).toHaveLength(0)
    f.profile('restored'); f.now(600_000); await restarted.tick(); expect(f.calls).toHaveLength(0)
    expect(restarted.get(r.id).nextAt).toBe(new Date(base + 660_000).toISOString())
    f.now(660_000); await restarted.tick(); expect(f.calls).toHaveLength(1); await restarted.close()
  })
  it('invalidates undispatched work and resets cursor on profileChanged', async () => {
    const f = fixture(), s = await f.open(), r = await s.create(f.input()); await s.runNow(r.id)
    f.profile('v2'); await s.profileChanged(profileId); await s.tick(); expect(f.calls).toHaveLength(0); expect(s.history()[0]?.status).toBe('skipped'); await s.close()
  })
  it('expires a skip delivery delayed beyond grace during wake', async () => {
    const f = fixture(), s = await f.open(); await s.create(f.input()); f.now(60_010)
    f.runtime.acquire = async () => { f.now(91_000); return () => {} }
    await s.tick(); expect(f.calls).toHaveLength(0); expect(s.history()[0]?.status).toBe('skipped'); await s.close()
  })
  it('coalesce filters scheduled time while allowing execution outside the active window', async () => {
    const f = fixture(), s = await f.open()
    await s.create(f.input({ missed: 'coalesce', schedule: { kind: 'once', timeZone: 'UTC', at: '2026-01-01T00:01:00Z', active: { window: { start: '00:00', end: '00:02' } } } }))
    f.now(600_000); await s.tick()
    expect(f.calls).toHaveLength(1); expect(s.history()[0]?.scheduledAt).toBe('2026-01-01T00:01:00.000Z'); await s.close()
  })
  it('keeps a reservation on lookup failure and rejects oversized envelopes before persisting it', async () => {
    const f = fixture(), s = await f.open(), r = await s.create(f.input()); await s.runNow(r.id)
    const lookup = f.runtime.lookup; f.runtime.lookup = async () => { throw new Error('guest unavailable') }
    await s.tick(); expect(s.history()[0]?.status).toBe('reserved'); expect(f.calls).toHaveLength(0); expect(f.leases()).toBe(0)
    f.runtime.lookup = lookup; await s.tick(); expect(f.calls).toHaveLength(1)
    const run = s.history()[0]!; f.tasks.set(run.id, { status: 'succeeded' }); await s.tick()
    f.runtime.snapshot = async () => ({ revision: 'v1', input: { envelope: 'x'.repeat(512_001) } })
    await expect(s.runNow(r.id)).rejects.toThrow('too large'); expect(s.history()).toHaveLength(1); await s.close()
  })
  it('allows a fresh manual run immediately after an unobserved profile edit', async () => {
    const f = fixture(), s = await f.open(), r = await s.create(f.input()); f.profile('v2')
    const run = await s.runNow(r.id); await s.tick()
    expect(f.calls[0]?.id).toBe(run.id); expect(f.calls[0]?.input).toEqual({ prompt: 'Summarize', envelope: { revision: 'v2' } }); await s.close()
  })
  it('does not persist unchanged active statuses or repeated lookup failures', async () => {
    const f = fixture(), s = await f.open(), r = await s.create(f.input()); await s.runNow(r.id); await s.tick()
    const writes = f.writes(); await s.tick(); await s.tick(); expect(f.writes()).toBe(writes)
    const run = s.history()[0]!; f.tasks.set(run.id, { status: 'active', detail: 'Waiting for approval' }); await s.tick(); expect(f.writes()).toBe(writes + 1)
    await s.tick(); expect(f.writes()).toBe(writes + 1)
    f.runtime.lookup = async () => { throw new Error('guest unavailable') }; await s.tick(); const errorsWritten = f.writes()
    await s.tick(); expect(f.writes()).toBe(errorsWritten); await s.close()
  })
  it('accepts bounded Unicode profile envelopes', async () => {
    const f = fixture(), s = await f.open(), r = await s.create(f.input())
    f.runtime.snapshot = async () => ({ revision: 'v1', input: { context: '🦀'.repeat(100_000) } })
    await s.runNow(r.id); await s.tick(); expect(f.calls).toHaveLength(1); await s.close()
  })
  it('bounds history and removes terminal envelopes', async () => {
    const f = fixture(), s = await f.open(), r = await s.create(f.input())
    for (let i = 0; i < 105; i++) { const run = await s.runNow(r.id); f.tasks.set(run.id, { status: 'succeeded' }); await s.tick() }
    expect(s.history()).toHaveLength(100); expect(f.store()?.runs.every(r => Object.keys(r.input).length === 0)).toBe(true); await s.close()
  })
  it('uses AppKit timezone, DST and exhaustion semantics', async () => {
    const f = fixture(), s = await f.open(); f.now(Date.parse('2026-03-07T08:00:00Z') - base)
    const r = await s.create(f.input({ schedule: { kind: 'daily', timeZone: 'America/New_York', time: '02:30' } }))
    expect(r.nextAt).toBe('2026-03-09T06:30:00.000Z')
    const once = await s.create(f.input({ schedule: { kind: 'once', timeZone: 'UTC', at: '2026-03-07T08:01:00Z' } }))
    f.now(Date.parse('2026-03-07T08:01:00Z') - base); await s.tick(); expect(s.get(once.id).nextAt).toBeNull(); await s.close()
  })
  it('rejects malformed storage and bounded input', async () => {
    const f = fixture(), s = await f.open()
    await expect(s.create(f.input({ prompt: 'x'.repeat(16_001) }))).rejects.toThrow()
    await expect(s.create(f.input({ schedule: { kind: 'daily', timeZone: 'Mars/Test', time: '12:00' } }))).rejects.toThrow()
    await expect(s.create(f.input({ overlap: 'coalesce' }))).rejects.toThrow()
    await expect(AgentRoutines.create({ load: async () => ({ version: 12 }), save: async () => {} }, f.options)).rejects.toThrow()
    await s.close()
  })
  it('stops timers and drains a pending wake without dispatch after close', async () => {
    const f = fixture(), s = await f.open(), r = await s.create(f.input()); await s.runNow(r.id); s.start(); expect(f.timers.size).toBe(1)
    let wake!: () => void, entered!: () => void
    const waiting = new Promise<void>(resolve => { entered = resolve })
    f.runtime.acquire = async () => { entered(); await new Promise<void>(resolve => { wake = resolve }); return () => {} }
    const tick = s.tick(); await waiting; const close = s.close(); wake(); await tick; await close
    expect(f.calls).toHaveLength(0); expect(f.timers.size).toBe(0); await expect(s.tick()).rejects.toThrow('closed')
  })
  it('writes and reopens the private file store and rejects corrupt files', async () => {
    const f = fixture(), dir = await mkdtemp(join(tmpdir(), 'caboose-routines-')), path = join(dir, 'routines.json')
    const s = await AgentRoutines.open(path, f.options), r = await s.create(f.input()); await s.runNow(r.id); await s.close()
    const reopened = await AgentRoutines.open(path, f.options); await reopened.tick(); expect(f.calls).toHaveLength(1); expect(JSON.parse(await readFile(path, 'utf8')).version).toBe(1); await reopened.close()
    await writeFile(path, '{broken'); await expect(AgentRoutines.open(path, f.options)).rejects.toThrow()
  })
})
