#!/usr/bin/env node
// Real-host profile/memory/routine check. --agent additionally runs two short provider
// turns (manual and scheduled) on the owner's account; it must already be signed in.
// Test routines are deleted and the verification profile is archived, preserving history.
import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
const base = (process.env.CABOOSE_URL ?? 'http://127.0.0.1:7310').replace(/\/$/, '')
const token = process.env.CABOOSE_OWNER_TOKEN
if (!token) throw new Error('Set CABOOSE_OWNER_TOKEN')
const args = process.argv.slice(2)
if (args.length && (args.length !== 2 || args[0] !== '--agent')) throw new Error('Usage: check-persistent-agents.mjs [--agent <installed-provider>]')
const agent = args[1]
const marker = `caboose-check-${randomUUID()}`
async function call(path, method = 'GET', body) {
  const response = await fetch(base + path, { method, signal: AbortSignal.timeout(300_000), headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' }, ...(body === undefined ? {} : { body: JSON.stringify(body) }) })
  const value = await response.json()
  assert.ok(response.ok, `${method} ${path}: HTTP ${response.status} ${JSON.stringify(value)}`)
  return value
}
let profile
const routines = []
const failures = []
try {
  const catalog = await call('/v1/agents')
  const provider = agent ?? catalog.defaultAgent ?? catalog.agents[0]?.id
  assert.ok(provider, 'Registry has no provider')
  if (agent) assert.ok(catalog.agents.find(a => a.id === agent)?.installed, 'Install and sign in to the requested provider first')
  profile = (await call('/v1/agent/profiles', 'POST', { name: 'Caboose verification', description: marker, agent: provider, instructions: 'For verification, use only Caboose memory tools. Do not run shell commands, browse, or modify files.', approvals: 'ask' })).profile
  const saved = (await call(`/v1/agent/profiles/${profile.id}/memories`, 'POST', { title: 'Verification', content: marker })).profile
  const memory = saved.memories[0]
  const changed = (await call(`/v1/agent/profiles/${profile.id}/memories/${memory.id}`, 'PATCH', { content: `${marker}-updated` })).profile
  assert.equal(changed.memories[0].title, 'Verification')
  assert.equal(changed.memories[0].content, `${marker}-updated`)
  await call(`/v1/agent/profiles/${profile.id}/memories/${memory.id}`, 'DELETE')
  const definition = { profileId: profile.id, name: 'Verification', prompt: `Use memory_remember to save title Verification and content exactly ${marker}. Then respond Done.`, schedule: { kind: 'daily', time: '09:00', timeZone: 'America/Toronto' }, paused: true }
  const routine = (await call('/v1/agent/routines', 'POST', definition)).routine
  routines.push(routine.id)
  assert.equal((await call(`/v1/agent/routines/${routine.id}`)).routine.paused, true)
  assert.ok((await call('/v1/agent/routines')).routines.some(r => r.id === routine.id))
  if (agent) {
    await call(`/v1/agent/routines/${routine.id}`, 'PATCH', { paused: false })
    const manual = (await call(`/v1/agent/routines/${routine.id}/run`, 'POST', {})).run
    async function finish(id, runId) {
      const deadline = Date.now() + 360_000
      while (Date.now() < deadline) {
        const history = (await call(`/v1/agent/routines/${id}/history`)).runs
        const run = runId ? history.find(r => r.id === runId) : history[0]
        if (run && !['reserved', 'active'].includes(run.status)) {
          assert.equal(run.status, 'succeeded', `Routine failed: ${run.detail ?? run.status}`)
          const task = (await call('/v1/agent/tasks')).find(t => t.id === run.id)
          assert.equal(task?.profileId, profile.id)
          return run
        }
        await new Promise(resolve => setTimeout(resolve, 1000))
      }
      throw new Error('Routine did not finish within six minutes')
    }
    await finish(routine.id, manual.id)
    const read = (await call(`/v1/agent/profiles/${profile.id}`)).profile
    assert.ok(read.memories.some(m => m.content === marker), 'Agent did not save memory through MCP')
    const scheduled = (await call('/v1/agent/routines', 'POST', { ...definition, name: 'Scheduled verification', prompt: 'Read saved memories using memory_list and respond with the verification marker. Do not create or edit anything.', paused: false, schedule: { kind: 'once', timeZone: 'UTC', at: new Date(Date.now() + 15_000).toISOString() } })).routine
    routines.push(scheduled.id)
    const completed = await finish(scheduled.id)
    assert.equal(completed.trigger, 'schedule')
    assert.equal((await call(`/v1/agent/routines/${scheduled.id}/history`)).runs.length, 1)
    console.log('Manual and scheduled provider turns, task/profile binding and MCP memory passed.')
  }
  console.log('Profile, partial memory edits and routine API checks passed.')
} catch (error) { failures.push(error) }
finally {
  for (const id of routines) try { await call(`/v1/agent/routines/${id}`, 'DELETE') } catch (error) { failures.push(error) }
  if (profile) try { await call(`/v1/agent/profiles/${profile.id}`, 'PATCH', { archived: true }) } catch (error) { failures.push(error) }
}
if (failures.length) throw new AggregateError(failures, 'Persistent-agent verification failed')
