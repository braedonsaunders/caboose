import { test } from 'node:test'
import assert from 'node:assert/strict'
import { actionChoices, choiceDecision } from './choices.mjs'
const input = { objective: 'Fill the title', goal: { name: 'Title', role: 'text', value: 'Report' }, elements: [
  { id: 'one', name: 'Title', role: 'text', value: '', states: ['editable'] },
  { id: 'two', name: 'Submit', role: 'button', states: [], actions: ['press'] },
] }
test('text choices contain only authorized values and observed target IDs', () => {
  const { candidates } = actionChoices(input)
  assert.deepEqual(candidates.find(c => c.action.action === 'set_text').action, { action: 'set_text', id: 'one', text: 'Report' })
  assert.equal(candidates.filter(c => c.action.action === 'set_text').length, 1)
  assert.equal(candidates.filter(c => c.action.action === 'click_element').length, 1)
})
test('a changed value or target changes the decision revision', () => {
  const first = actionChoices(input)
  const changed = actionChoices({ ...input, elements: input.elements.map(e => ({ ...e, value: 'new' })) })
  assert.notEqual(first.revision, changed.revision)
})
test('disabled controls and readonly text cannot receive mutation choices', () => {
  const { candidates } = actionChoices({ ...input, elements: input.elements.map(e => ({ ...e, states: ['disabled', 'read-only'] })) })
  assert.deepEqual(candidates.map(c => c.action.action), ['wait', 'done', 'blocked'])
})
test('bounded choices do not silently truncate away the correct option', () => {
  assert.throws(() => actionChoices({ ...input, elements: Array.from({ length: 40 }, (_, i) => ({ id: String(i), name: `B${i}`, role: 'button', states: [] })) }), /32 choices/)
})
test('the scorer cannot substitute actions or a stale revision', async t => {
  t.mock.method(globalThis, 'fetch', async (_url, options) => {
    const request = JSON.parse(options.body)
    return Response.json({ revision: request.revision, choice: 3, action: 'shell', text: 'invented' })
  })
  assert.deepEqual(await choiceDecision()(input), { action: 'set_text', id: 'one', text: 'Report' })
  globalThis.fetch.mock.mockImplementation(async () => Response.json({ revision: 'old', choice: 3 }))
  await assert.rejects(choiceDecision()(input), /this observation/)
})
test('ambiguous controls return to the caller without invoking the scorer', async t => {
  const fetch = t.mock.method(globalThis, 'fetch', () => { throw new Error('must not run') })
  const result = await choiceDecision()({ ...input, elements: [...input.elements, { ...input.elements[0], id: 'duplicate' }] })
  assert.equal(result.action, 'blocked')
  assert.equal(fetch.mock.callCount(), 0)
})
