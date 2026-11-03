// Reuses verified oracle fixture traces. Negative rows are explicit synthetic augmentations,
// not UI recordings. Busy, empty, ambiguous and completed observations never reach the
// model (choices.mjs and the runner decide them exactly), so they are not training data.
// usage: node specialist-choice-data.mjs ROOT OUTPUT SPLIT...   (ROOT holds cases/ and dataset/)
import { readFile, writeFile, mkdir } from 'node:fs/promises'
import { resolve } from 'node:path'
import { actionChoices } from '../choices.mjs'
const [root, output, ...splits] = process.argv.slice(2)
await mkdir(output, { recursive: true })
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b)
for (const split of splits.length ? splits : ['train', 'validation', 'heldout']) {
  const cases = JSON.parse(await readFile(resolve(root, 'cases', `${split}.json`), 'utf8'))
  const results = (await readFile(resolve(root, 'dataset', `${split}-results.jsonl`), 'utf8')).trim().split('\n').map(JSON.parse)
  if (results.length !== cases.length || results.some(r => r.model !== 'oracle' || !r.completed || r.wrongActions)) throw new Error(`${split}: unverified oracle results`)
  const traces = (await readFile(resolve(root, 'dataset', `${split}-results.jsonl.traces.jsonl`), 'utf8')).trim().split('\n').map(JSON.parse)
  const rows = []
  // Every step the fixture accepts in any order is correct; the submit control only once nothing is pending.
  const pendingActions = (spec, elements) => {
    const steps = spec.fields.flatMap(field => {
      const element = elements.find(e => e.name === field.name && e.role === 'text')
      return element && element.value !== field.value ? [{ action: 'set_text', id: element.id, text: field.value }] : []
    })
    const toggle = elements.find(e => e.name === spec.toggle && e.role === 'check box')
    if (toggle && !toggle.states?.includes('checked')) steps.push({ action: 'click_element', id: toggle.id })
    const submit = elements.find(e => e.name === spec.submit && e.role === 'button')
    return steps.length ? steps : [{ action: 'click_element', id: submit.id }]
  }
  const add = (t, kind, elements, values, accepted) => {
    const request = actionChoices({ objective: t.objective, goal: t.goal, elements, values })
    const acceptable = request.candidates.flatMap((c, i) => accepted.some(a => same(a, c.action)) ? [i] : [])
    if (acceptable.length !== accepted.length) throw new Error(`${split} case ${t.case}: accepted action absent from grounded choices`)
    const expected = kind === 'recorded-action' ? request.candidates.findIndex(c => same(c.action, t.action)) : acceptable[0]
    if (!acceptable.includes(expected)) throw new Error(`${split} case ${t.case}: oracle action is not an accepted step`)
    rows.push({ split, case: t.case, kind, prompt: request.prompt, state: request.state, choices: request.candidates.map(c => c.label), expected, acceptable })
  }
  for (const [index, t] of traces.entries()) {
    const spec = cases[t.case]
    add(t, 'recorded-action', t.before, spec.fields, pendingActions(spec, t.before))
    const pending = spec.fields.find(f => t.before.some(e => e.name === f.name && e.role === 'text' && e.value !== f.value))
    if (index % 6 === 0 && pending) {
      add(t, 'synthetic-missing-value', t.before, spec.fields.filter(f => f !== pending), [{ action: 'blocked' }])
      add(t, 'synthetic-missing-control', t.before.filter(e => e.name !== pending.name), spec.fields, [{ action: 'blocked' }])
    }
    // The final step with one field never filled: everything else is done, only the submit is
    // left, and it must not go in. Oracle traces never pass through this state themselves.
    const last = !pending && spec.fields[t.case % Math.max(1, spec.fields.length)]
    if (index % 2 === 0 && last) {
      const cleared = t.before.map(e => e.name === last.name && e.role === 'text' ? { ...e, value: '' } : e)
      add(t, 'synthetic-final-missing-value', cleared, spec.fields.filter(f => f !== last), [{ action: 'blocked' }])
      add(t, 'synthetic-final-missing-control', t.before.filter(e => e.name !== last.name), spec.fields, [{ action: 'blocked' }])
    }
  }
  await writeFile(resolve(output, `${split}.jsonl`), rows.map(r => JSON.stringify(r)).join('\n') + '\n')
  console.log(split, rows.length, Object.entries(Object.groupBy(rows, r => r.kind)).map(([k, v]) => `${k}=${v.length}`).join(' '))
}
