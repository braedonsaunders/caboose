// Choice rows from verified real-application oracle runs (check/specialist-apps.mjs): each
// step's prompt is rebuilt from the recorded observation and window, and the answer is the
// oracle's action, plus explicit synthetic BLOCKED rows. Cases that did not complete, or whose
// effect check failed, give no rows.
// usage: node specialist-app-data.mjs CASES RESULTS OUTPUT
import { readFile, writeFile } from 'node:fs/promises'
import { actionChoices } from '../choices.mjs'
const [casesPath, resultsPath, output] = process.argv.slice(2)
const cases = JSON.parse(await readFile(casesPath, 'utf8'))
const results = (await readFile(resultsPath, 'utf8')).trim().split('\n').map(JSON.parse)
const traces = (await readFile(resultsPath + '.traces.jsonl', 'utf8')).trim().split('\n').map(JSON.parse)
const good = new Set(results.filter(r => r.model === 'oracle' && r.completed).map(r => r.case))
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b)
const rows = []
for (const t of traces) {
  if (t.policy !== 'oracle' || !good.has(t.case)) continue
  const spec = cases[t.case]
  const request = actionChoices({ objective: t.objective, goal: t.goal, elements: t.before, ...(spec.values.length ? { values: spec.values } : {}), ...(t.window ? { window: t.window } : {}) })
  const expected = request.candidates.findIndex(c => same(c.action, t.action))
  if (expected < 0) throw new Error(`case ${t.case}: the oracle's action is not a grounded choice`)
  rows.push({ split: spec.split, case: t.case, family: spec.family, kind: 'recorded-action', prompt: request.prompt, state: request.state,
              choices: request.candidates.map(c => c.label), expected, acceptable: [expected] })
  // Explicit synthetic negatives: the value a SET step needs, or a control the objective names,
  // is gone, so the step cannot be taken and the answer is BLOCKED.
  const blocked = (kind, elements, values) => {
    const negative = actionChoices({ objective: t.objective, goal: t.goal, elements, ...(values.length ? { values } : {}), ...(t.window ? { window: t.window } : {}) })
    const index = negative.candidates.findIndex(c => c.action.action === 'blocked')
    rows.push({ split: spec.split, case: t.case, family: spec.family, kind, prompt: negative.prompt, state: negative.state,
                choices: negative.candidates.map(c => c.label), expected: index, acceptable: [index] })
  }
  const target = t.before.find(e => e.id === t.action.id)
  if (t.action.action === 'set_text') {
    const source = spec.values.find(v => v.value === t.action.text)
    if (source) blocked('synthetic-missing-value', t.before, spec.values.filter(v => v !== source))
  } else if (target?.name && t.objective.includes(target.name)) {
    blocked('synthetic-missing-control', t.before.filter(e => e.id !== target.id), spec.values)
  }
}
await writeFile(output, rows.map(r => JSON.stringify(r)).join('\n') + '\n')
console.log(`${good.size}/${results.length} cases verified, ${rows.length} rows`)
