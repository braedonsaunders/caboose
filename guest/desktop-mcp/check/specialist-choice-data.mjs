// Reuses fixture evidence. Negative rows are explicit synthetic augmentations, not UI recordings.
import { readFile, writeFile, mkdir } from 'node:fs/promises'
import { resolve } from 'node:path'
import { actionChoices } from '../choices.mjs'
const [root, output] = process.argv.slice(2)
await mkdir(output, { recursive: true })
for (const split of ['train', 'validation', 'heldout']) {
  const cases = JSON.parse(await readFile(resolve(root, 'cases', `${split}.json`), 'utf8'))
  const traces = (await readFile(resolve(root, 'dataset', `${split}-results.jsonl.traces.jsonl`), 'utf8')).trim().split('\n').map(JSON.parse)
  const rows = []
  const add = (t, elements, expectedAction, kind, sources, extraState = {}) => {
    const spec = cases[t.case]
    const observation = { objective: t.objective, goal: t.goal, elements, values: sources ?? spec.fields }
    const request = actionChoices(observation)
    request.state = JSON.stringify({ ...JSON.parse(request.state), ...extraState })
    const expected = request.candidates.findIndex(c => JSON.stringify(c.action) === JSON.stringify(expectedAction))
    if (expected < 0) throw new Error('oracle action absent from grounded choices')
    const acceptable = kind === 'recorded-action' && expectedAction.action === 'set_text'
      ? request.candidates.flatMap((c, i) => {
          const target = elements.find(e => e.id === c.action.id)
          const field = spec.fields.find(f => f.name === target?.name)
          return c.action.action === 'set_text' && field?.value === c.action.text && target.value !== field.value ? [i] : []
        }) : [expected]
    rows.push({ split, case: t.case, kind, state: request.state, choices: request.candidates.map(c => c.label), expected, acceptable })
  }
  for (const [index, t] of traces.entries()) {
    add(t, t.before, t.action, 'recorded-action')
    if (index % 4 === 0) {
      add(t, t.before.map(e => ({ ...e, states: [...e.states, 'busy'] })), { action: 'wait' }, 'synthetic-busy')
      add(t, [], { action: 'blocked' }, 'synthetic-unavailable')
      const pendingField = t.before.find(e => e.states?.includes('editable') && cases[t.case].fields.some(f => f.name === e.name && f.value !== e.value))
      if (pendingField) add(t, t.before, { action: 'blocked' }, 'synthetic-missing-values', [])
      add(t, t.before, { action: 'blocked' }, 'synthetic-stale', undefined, { fresh: false })
      const field = pendingField
      if (field) add(t, [...t.before.filter(e => !e.states?.includes('editable')), field, { ...field, id: field.id + '-duplicate' }], { action: 'blocked' }, 'synthetic-ambiguous')
    }
    if (t.after.some(e => e.name === t.goal.name && e.role === t.goal.role)) add(t, t.after, { action: 'done' }, 'recorded-complete')
  }
  await writeFile(resolve(output, `${split}.jsonl`), rows.map(r => JSON.stringify(r)).join('\n') + '\n')
  console.log(split, rows.length)
}
