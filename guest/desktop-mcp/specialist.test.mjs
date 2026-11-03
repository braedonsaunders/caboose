import { test } from 'node:test'
import assert from 'node:assert/strict'
import { runSpecialist, phoneDecision } from './specialist.mjs'
const task = { objective: 'Set the field to ready', window: 7, goal: { name: 'Title', role: 'entry', value: 'ready' } }
const element = { id: '7-123-field', name: 'Title', role: 'entry', value: '', states: ['editable'] }
function fixture(overrides = {}) {
  let current = { ...element }; const actions = []
  return { actions, options: {
    observe: async () => ({ focused: 7, elements: [current] }),
    decide: async () => ({ action: 'set_text', id: element.id, text: 'ready' }),
    act: async action => { actions.push(action); current = { ...current, value: action.text } },
    ...overrides,
  } }
}
test('completion comes from a fresh observation and records separate overhead', async () => {
  const f = fixture(); const r = await runSpecialist(task, f.options)
  assert.equal(r.status, 'verified'); assert.equal(f.actions.length, 1)
  assert.equal(r.metrics.observations, 3); assert.equal(r.metrics.actions, 1)
})
test('model cannot invent an element or substitute shell input', async () => {
  for (const choice of [{ action: 'set_text', id: 'unknown', text: 'ready' }, { action: 'launch', command: 'false' }, { action: 'done' }]) {
    const f = fixture({ decide: async () => choice })
    assert.equal((await runSpecialist(task, f.options)).status, 'rejected'); assert.equal(f.actions.length, 0)
  }
})
test('changed focus prevents all input', async () => {
  const f = fixture({ observe: async () => ({ focused: 8, elements: [element] }) })
  assert.equal((await runSpecialist(task, f.options)).status, 'interrupted'); assert.equal(f.actions.length, 0)
})
test('renamed target during inference is rejected', async () => {
  let reads = 0
  const f = fixture({ observe: async () => ({ focused: 7, elements: [{ ...element, name: ++reads === 1 ? 'Title' : 'Delete everything' }] }) })
  assert.equal((await runSpecialist(task, f.options)).status, 'rejected'); assert.equal(f.actions.length, 0)
})
test('unsupported accessibility requests visual escalation without clicking', async () => {
  const f = fixture({ observe: async () => ({ focused: 7, elements: [] }) })
  assert.equal((await runSpecialist(task, f.options)).status, 'needs_visual'); assert.equal(f.actions.length, 0)
})
test('ambiguous goal never counts as verified', async () => {
  const f = fixture({ observe: async () => ({ focused: 7, elements: [element, { ...element, id: 'other', value: 'ready' }] }), decide: async () => ({ action: 'escalate' }) })
  assert.equal((await runSpecialist(task, f.options)).status, 'needs_visual')
})
test('an unsuccessful action is not retried', async () => {
  let attempts = 0
  const f = fixture({ act: async () => { attempts++; throw new Error('response lost; action outcome unknown') } })
  const r = await runSpecialist(task, f.options)
  assert.equal(r.status, 'interrupted'); assert.match(r.reason, /unknown/); assert.equal(attempts, 1)
})
test('action budget bounds a model stuck on ineffective actions', async () => {
  const f = fixture({ act: async () => {} })
  const r = await runSpecialist({ ...task, maxActions: 2 }, f.options)
  assert.equal(r.status, 'incomplete'); assert.equal(r.metrics.actions, 2)
})
test('cancelled delegates cannot act', async () => {
  const c = new AbortController(); c.abort(new Error('owner takeover'))
  const f = fixture({ signal: c.signal })
  assert.equal((await runSpecialist(task, f.options)).status, 'interrupted'); assert.equal(f.actions.length, 0)
})
test('raw trace is opt-in and observes actual effects', async () => {
  const traces = []; const f = fixture({ trace: row => traces.push(row) })
  await runSpecialist(task, f.options)
  assert.equal(traces.length, 1); assert.equal(traces[0].after[0].value, 'ready')
})
