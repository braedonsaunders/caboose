// Choice rows from verified real-application oracle runs (check/specialist-apps.mjs): each
// step's prompt is rebuilt from the recorded observation and window, and the answer is the
// oracle's action. Cases that did not complete, or whose effect check failed, give no rows.
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
}
await writeFile(output, rows.map(r => JSON.stringify(r)).join('\n') + '\n')
console.log(`${good.size}/${results.length} cases verified, ${rows.length} rows`)
