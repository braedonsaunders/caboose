// Convert only fixture-generated oracle traces; never collect product observations.
import { readFile, writeFile, mkdir } from 'node:fs/promises'
import { resolve } from 'node:path'
import { decisionMessages, goalSatisfied } from '../specialist.mjs'
const [input, output] = process.argv.slice(2)
if (!input || !output) throw new Error('usage: node specialist-dataset.mjs INPUT_DIR OUTPUT_DIR')
await mkdir(output, { recursive: true })
const manifest = {}
for (const [split, filename] of [['train', 'train'], ['validation', 'valid'], ['heldout', 'test']]) {
  const results = (await readFile(resolve(input, `${split}-results.jsonl`), 'utf8')).trim().split('\n').map(JSON.parse)
  const traces = (await readFile(resolve(input, `${split}-results.jsonl.traces.jsonl`), 'utf8')).trim().split('\n').map(JSON.parse)
  const cases = new Map(results.map(r => [r.case, r]))
  if (cases.size !== results.length || results.some(r => r.model !== 'oracle' || !r.completed || r.wrongActions)) throw new Error(`${split}: invalid oracle results`)
  const rows = traces.map(t => {
    if (t.policy !== 'oracle' || t.split !== split || !cases.has(t.case)) throw new Error('unverified trace')
    if (!t.before.some(e => e.id === t.action.id)) throw new Error('ungrounded oracle action')
    return { messages: [...decisionMessages({ objective: t.objective, goal: t.goal, elements: t.before }), { role: 'assistant', content: JSON.stringify(t.action) }] }
  })
  for (const id of cases.keys()) {
    const steps = traces.filter(t => t.case === id)
    if (!steps.length || !goalSatisfied(steps.at(-1).goal, steps.at(-1).after)) throw new Error('missing completion evidence')
  }
  await writeFile(resolve(output, `${filename}.jsonl`), rows.map(r => JSON.stringify(r)).join('\n') + '\n')
  manifest[split] = { trajectories: cases.size, actions: rows.length }
}
await writeFile(resolve(output, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n')
console.log(JSON.stringify(manifest))
