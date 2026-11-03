// Real GTK/AT-SPI evaluation. Default policy is an oracle for harness latency,
// NOT a trained model. --model MODEL measures the same tasks with inference.
import { readFile, appendFile } from 'node:fs/promises'
import { Worker } from '../worker.mjs'
import { runSpecialist, phoneDecision } from '../specialist.mjs'
const variant = process.argv[2]
const model = process.argv.includes('--model') ? process.argv[process.argv.indexOf('--model') + 1] : undefined
const a11y = new Worker(new URL('../a11y.py', import.meta.url).pathname, ['--display=:101'], 10_000)
const seat = new Worker(new URL('../seat.py', import.meta.url).pathname, [], 10_000)
const env = { ...process.env }
const request = async (worker, body) => { const r = await worker.request(body, env); if (r.error) throw new Error(r.error); return r }
const observe = async () => {
  const state = await request(a11y, { op: 'elements' })
  const listing = await request(seat, { args: ['windows'] })
  return { ...state, focused: listing.focused }
}
try {
  let initial
  for (let i = 0; i < 50; i++) {
    initial = await observe()
    if (initial.elements?.length >= 3) break
    await new Promise(r => setTimeout(r, 100))
  }
  const [name, toggle] = variant === 'development' ? ['Title', 'Enable alerts'] : ['Destination', 'Keep receipt']
  const goals = [{ name, role: 'text', value: variant === 'development' ? 'sample report' : 'archive 2026' }, { name: toggle, role: 'check box', state: 'checked' }]
  for (const goal of goals) {
    const beforeLog = (await readFile('/tmp/specialist-effects.jsonl', 'utf8').catch(() => '')).split('\n').filter(Boolean).length
    const task = { window: initial.focused, objective: goal.value ? `Replace ${goal.name} with ${goal.value}` : `Check ${goal.name}`, goal, maxActions: 4 }
    const result = await runSpecialist(task, {
      observe,
      decide: model ? phoneDecision(model, process.env.CABOOSE_SPECIALIST_ENDPOINT) : async ({ elements }) => {
        const target = elements.find(e => e.name === goal.name && e.role === goal.role)
        return { action: goal.value ? 'set_text' : 'click_element', id: target?.id, ...(goal.value ? { text: goal.value } : {}) }
      },
      act: async action => {
        const r = await request(a11y, { op: 'act', element: action.id, action: action.action === 'set_text' ? 'set-text' : action.action === 'focus_element' ? 'focus' : 'press', ...(action.text ? { text: action.text } : {}) })
        if (!r.ok) throw new Error('action outcome unknown')
      },
      // Explicitly opt in only in this fixture, whose strings contain no user data.
      trace: row => appendFile('/tmp/specialist-traces.jsonl', JSON.stringify({ variant, model: model ?? 'oracle', ...row }) + '\n'),
    })
    await new Promise(r => setTimeout(r, 50))
    const effects = (await readFile('/tmp/specialist-effects.jsonl', 'utf8').catch(() => '')).split('\n').filter(Boolean).slice(beforeLog).map(JSON.parse)
    const wrongActions = effects.filter(e => e.name !== goal.name).length
    console.log(JSON.stringify({ variant, policy: model ?? 'oracle-harness-only', goal, ...result, wrongActions, effects }))
    if (result.status !== 'verified' || wrongActions) process.exitCode = 1
  }
} finally { a11y.close(); seat.close() }
