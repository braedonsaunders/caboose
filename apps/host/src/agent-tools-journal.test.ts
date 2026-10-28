import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { AgentToolJournal, ToolValidationError } from './agent-tools-journal.js'

const scope = { taskId: '11111111-1111-4111-8111-111111111111', profileId: '22222222-2222-4222-8222-222222222222', turn: 1 }
const request = { id: '33333333-3333-4333-8333-333333333333', tool: 'routine_create', arguments: { name: 'test' } }
let dir: string
async function path() { dir = await mkdtemp(join(tmpdir(), 'caboose-tools-')); return join(dir, 'journal.json') }
afterEach(async () => { if (dir) await rm(dir, { recursive: true, force: true }) })
describe('tool receipts', () => {
  it('replays a durable result and rejects conflicting reuse across restart', async () => {
    const p = await path(), dispatch = vi.fn(async () => ({ id: 'created' }))
    const journal = await AgentToolJournal.open(p, dispatch)
    await journal.bindTask(scope.taskId, scope.profileId)
    expect(await journal.execute(scope, request)).toEqual({ ok: true, value: { id: 'created' } })
    const reopened = await AgentToolJournal.open(p, dispatch)
    expect(await reopened.execute(scope, request)).toEqual({ ok: true, value: { id: 'created' } })
    await expect(reopened.execute(scope, { ...request, arguments: { name: 'different' } })).rejects.toThrow('conflicts')
    await expect(reopened.execute({ ...scope, profileId: scope.taskId }, request)).rejects.toThrow('binding')
    expect(dispatch).toHaveBeenCalledTimes(1)
  })
  it('never retries an interrupted intent', async () => {
    const p = await path(), dispatch = vi.fn(async () => 'done')
    const journal = await AgentToolJournal.open(p, dispatch)
    await journal.bindTask(scope.taskId, scope.profileId)
    await journal.execute(scope, request)
    const state = JSON.parse(await readFile(p, 'utf8'))
    delete state.receipts[0].result
    await writeFile(p, JSON.stringify(state))
    const reopened = await AgentToolJournal.open(p, dispatch)
    expect(await reopened.execute(scope, request)).toMatchObject({ ok: false, error: expect.stringContaining('may have completed') })
    expect(dispatch).toHaveBeenCalledTimes(1)
  })
  it('returns independent results and rejects duplicate or malformed stored receipts', async () => {
    const p = await path(), dispatch = vi.fn(async () => ({ nested: { n: 1 } }))
    const journal = await AgentToolJournal.open(p, dispatch)
    await journal.bindTask(scope.taskId, scope.profileId)
    const result = await journal.execute(scope, request)
    if (result.ok) (result.value as { nested: { n: number } }).nested.n = 9
    expect(await journal.execute(scope, request)).toEqual({ ok: true, value: { nested: { n: 1 } } })
    const state = JSON.parse(await readFile(p, 'utf8'))
    state.receipts.push(state.receipts[0])
    await writeFile(p, JSON.stringify(state))
    await expect(AgentToolJournal.open(p, dispatch)).rejects.toThrow('Duplicate')
    state.receipts.pop(); state.receipts[0].result = { ok: false, error: 17 }
    await writeFile(p, JSON.stringify(state))
    await expect(AgentToolJournal.open(p, dispatch)).rejects.toThrow('Invalid tool receipt result')
  })
  it('preserves safe validation messages and fences inactive turns', async () => {
    const p = await path(), dispatch = vi.fn(async () => { throw new ToolValidationError('Invalid schedule timezone') })
    const journal = await AgentToolJournal.open(p, dispatch)
    await journal.bindTask(scope.taskId, scope.profileId)
    await expect(journal.execute(scope, request, () => false)).rejects.toThrow('no longer active')
    expect(await journal.execute(scope, request)).toEqual({ ok: false, error: 'Error: Invalid schedule timezone' })
    expect(dispatch).toHaveBeenCalledTimes(1)
  })
  it('rejects unknown and oversized requests before dispatch', async () => {
    const p = await path(), dispatch = vi.fn(async () => null)
    const journal = await AgentToolJournal.open(p, dispatch)
    await journal.bindTask(scope.taskId, scope.profileId)
    await expect(journal.execute(scope, { ...request, tool: 'other' })).rejects.toThrow('Invalid')
    await expect(journal.execute(scope, { ...request, arguments: { text: 'x'.repeat(70_000) } })).rejects.toThrow('too large')
    expect(dispatch).not.toHaveBeenCalled()
  })
})
