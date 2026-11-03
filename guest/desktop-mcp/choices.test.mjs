import { test } from 'node:test'
import assert from 'node:assert/strict'
import { actionChoices, choiceDecision } from './choices.mjs'
const input = { objective: 'Fill the title', goal: { name: 'Title', role: 'text', value: 'Report' }, elements: [
  { id: 'one', name: 'Title', role: 'text', value: '', states: ['editable'] },
  { id: 'two', name: 'Submit', role: 'button', states: [], actions: ['press'] },
] }
const form = { objective: 'Set Name and Note, check Keep, then Save', goal: { name: 'Saved', role: 'button' },
  values: [{ name: 'Name', value: 'Ada' }, { name: 'Note', value: 'hello' }, { name: 'Reference', value: 'R-7' }],
  elements: [
    { id: 'n', name: 'Name', role: 'text', value: '', states: ['editable'] },
    { id: 'o', name: 'Note', role: 'text', value: 'hello', states: ['editable'] },
    { id: 'k', name: 'Keep', role: 'check box', states: ['checked'] },
    { id: 's', name: 'Save', role: 'button', states: [] },
  ] }
test('text choices contain only authorized values and observed target IDs', () => {
  const { candidates } = actionChoices(input)
  assert.deepEqual(candidates.find(c => c.action.action === 'set_text').action, { action: 'set_text', id: 'one', text: 'Report' })
  assert.equal(candidates.filter(c => c.action.action === 'set_text').length, 1)
  assert.equal(candidates.filter(c => c.action.action === 'click_element').length, 1)
})
test('a value named after a control fills only that control; unnamed sources stay open to every field', () => {
  const sets = actionChoices(form).candidates.filter(c => c.action.action === 'set_text')
  assert.deepEqual(sets.map(c => [c.action.id, c.action.text]), [['n', 'Ada']])
  const open = actionChoices({ ...form, values: [{ name: 'Reference', value: 'R-7' }] }).candidates.filter(c => c.action.action === 'set_text')
  assert.deepEqual(open.map(c => [c.action.id, c.action.text]), [['n', 'R-7'], ['o', 'R-7']])
  assert.match(open[1].label, /from "hello" to "R-7" \(source Reference\)/)
})
test('toggle choices state whether the control is already checked', () => {
  const labels = actionChoices(form).candidates.map(c => c.label)
  assert.ok(labels.includes('PRESS Keep (check box, checked)'))
  assert.ok(actionChoices({ ...form, elements: form.elements.map(e => e.id === 'k' ? { ...e, states: [] } : e) })
    .candidates.some(c => c.label === 'PRESS Keep (check box, not checked)'))
})
test('the prompt lists observed values, so a finished step differs from a missing value', () => {
  const { prompt, candidates } = actionChoices(form)
  const lines = prompt.split('\n')
  assert.equal(lines[0], 'Task: Set Name and Note, check Keep, then Save')
  assert.equal(lines[1], 'Values: Note="hello"')
  assert.deepEqual(lines.slice(2, -1), candidates.map((c, i) => `${'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef'[i]} ${c.label}`))
  assert.equal(lines.at(-1), 'Next:')
})
test('completion and waiting are not model choices', () => {
  assert.deepEqual([...new Set(actionChoices(form).candidates.map(c => c.action.action))].sort(), ['blocked', 'click_element', 'set_text'])
})
test('a changed value or target changes the decision revision', () => {
  const first = actionChoices(input)
  const changed = actionChoices({ ...input, elements: input.elements.map(e => ({ ...e, value: 'new' })) })
  assert.notEqual(first.revision, changed.revision)
})
test('disabled controls and readonly text cannot receive mutation choices', () => {
  const { candidates } = actionChoices({ ...input, elements: input.elements.map(e => ({ ...e, states: ['disabled', 'read-only'] })) })
  assert.deepEqual(candidates.map(c => c.action.action), ['blocked'])
})
test('bounded choices do not silently truncate away the correct option', () => {
  assert.throws(() => actionChoices({ ...input, elements: Array.from({ length: 40 }, (_, i) => ({ id: String(i), name: `B${i}`, role: 'button', states: [] })) }), /32 choices/)
})
test('the model cannot substitute actions or a stale revision', async t => {
  t.mock.method(globalThis, 'fetch', async (_url, options) => {
    const request = JSON.parse(options.body)
    assert.equal(request.choices, 3)
    assert.match(request.prompt, /^Task: Fill the title\n/)
    return Response.json({ revision: request.revision, choice: 1, action: 'shell', text: 'invented' })
  })
  assert.deepEqual(await choiceDecision()(input), { action: 'set_text', id: 'one', text: 'Report' })
  globalThis.fetch.mock.mockImplementation(async () => Response.json({ revision: 'old', choice: 1 }))
  await assert.rejects(choiceDecision()(input), /this observation/)
})
test('exactly decidable observations return without invoking the model', async t => {
  const fetch = t.mock.method(globalThis, 'fetch', () => { throw new Error('must not run') })
  const decide = choiceDecision()
  assert.equal((await decide({ ...input, elements: [...input.elements, { ...input.elements[0], id: 'duplicate' }] })).action, 'blocked')
  assert.deepEqual(await decide({ ...input, elements: input.elements.map(e => ({ ...e, states: [...e.states, 'busy'] })) }), { action: 'wait' })
  assert.equal((await decide({ ...input, elements: input.elements.map(e => ({ ...e, states: ['disabled'] })) })).action, 'blocked')
  assert.equal(fetch.mock.callCount(), 0)
})
