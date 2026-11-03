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
  assert.equal((await runSpecialist(task, f.options)).status, 'needs_clarification')
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
test('all completion conditions must hold in one observation', async () => {
  const other = { id: 'toggle', name: 'Enabled', role: 'check box', states: [] }
  const combined = { ...task, goal: { all: [task.goal, { name: 'Enabled', role: 'check box', state: 'checked' }] } }
  const f = fixture({ observe: async () => ({ focused: 7, elements: [{ ...element, value: 'ready' }, other] }),
    decide: async () => ({ action: 'click_element', id: 'toggle' }), act: async () => { other.states = ['checked'] } })
  const r = await runSpecialist(combined, f.options)
  assert.equal(r.status, 'verified'); assert.equal(r.evidence.length, 2); assert.equal(r.metrics.actions, 1)
})
test('failed model calls retain their latency and send no input', async () => {
  let time = 0
  const f = fixture({ now: () => time, decide: async () => { time = 700; throw new Error('unavailable') } })
  const r = await runSpecialist(task, f.options)
  assert.equal(r.status, 'interrupted'); assert.equal(r.metrics.modelMs, 700); assert.equal(r.metrics.actions, 0)
})
test('a task owns its window and the dialogs and menus whose parent chain reaches it', async () => {
  const { taskWindows } = await import('./specialist.mjs')
  const windows = [{ id: 7, parent: null }, { id: 9, parent: 7, kind: 'dialog' }, { id: 11, parent: 9, kind: 'popup' }, { id: 12, parent: null }, { id: 13, parent: 14 }, { id: 14, parent: 13 }]
  assert.deepEqual(taskWindows(7, windows).map(w => w.id), [7, 9, 11])
  assert.deepEqual(taskWindows(13, windows).map(w => w.id), [13, 14])
})
test('input follows focus into the task\'s own dialog, never into another window', async () => {
  const dialog = { id: '9-123-name', name: '', role: 'text', value: '', states: ['editable'] }
  let focused = 9, decided = []
  const windows = () => [{ id: 7, parent: null, title: 'Files' }, { id: 9, parent: 7, kind: 'dialog', title: 'Create New Folder' }, { id: 12, parent: null, title: 'Other' }]
  const f = fixture({
    observe: async () => ({ focused, windows: windows(), elements: [dialog] }),
    decide: async observation => { decided.push(observation.window); return { action: 'set_text', id: dialog.id, text: 'ready' } },
    act: async () => { focused = 12 },
  })
  const r = await runSpecialist({ ...task, goal: { title: 'Reports - Files' } }, f.options)
  assert.deepEqual(decided, ['dialog "Create New Folder"'])
  assert.equal(r.status, 'interrupted'); assert.match(r.reason, /focused window changed/)
})
test('a window title is an observable goal', async () => {
  let title = 'notes.txt - Editor'
  const f = fixture({
    observe: async () => ({ focused: 7, windows: [{ id: 7, parent: null, title }], elements: [element] }),
    act: async () => { title = 'saved.txt - Editor' },
  })
  const r = await runSpecialist({ ...task, goal: { all: [{ title: 'saved.txt - Editor' }] } }, f.options)
  assert.equal(r.status, 'verified'); assert.deepEqual(r.evidence, [{ title: 'saved.txt - Editor' }])
  const { validateTask } = await import('./specialist.mjs')
  assert.throws(() => validateTask({ ...task, goal: { title: 'x', name: 'y' } }), /window title alone/)
})
test('a window that just took focus is observed until its controls settle', async () => {
  const dialog = { id: '9-123-name', name: 'Name', role: 'text', value: '', states: ['editable'] }
  let focused = 7, reads = 0
  const windows = [{ id: 7, parent: null, title: 'Editor' }, { id: 9, parent: 7, kind: 'dialog', title: 'Save As' }]
  const seen = []
  const f = fixture({
    observe: async () => {
      if (focused === 9) reads++
      return { focused, windows, elements: focused === 7 ? [element] : reads < 3 ? [] : [dialog] }
    },
    decide: async observation => { seen.push(observation.elements.length); return focused === 7 ? { action: 'click_element', id: element.id } : { action: 'blocked' } },
    act: async () => { focused = 9 },
  })
  const r = await runSpecialist({ ...task, goal: { title: 'done' } }, f.options)
  assert.deepEqual(seen, [1, 1]); assert.equal(r.status, 'needs_clarification')
})
