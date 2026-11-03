// One fixture process, multiple independent real GUI trajectories. Oracle emits
// supervised actions; --model uses exactly the product specialist protocol.
import { readFile, appendFile } from 'node:fs/promises'
import { Worker } from '../worker.mjs'
import { choiceDecision } from '../choices.mjs'
import { runSpecialist, phoneDecision } from '../specialist.mjs'
const [casesPath, fixturePid, output] = process.argv.slice(2)
const choices = process.argv.includes('--choices')
const model = process.argv.includes('--model') ? process.argv[process.argv.indexOf('--model') + 1] : undefined
const cases = JSON.parse(await readFile(casesPath, 'utf8'))
const a11y = new Worker(new URL('../a11y.py', import.meta.url).pathname, ['--display=:101'], 10_000)
const seat = new Worker(new URL('../seat.py', import.meta.url).pathname, [], 10_000)
const env = { ...process.env }
const call = async (worker, body) => { const r = await worker.request(body, env); if (r.error) throw new Error(r.error); return r }
let latestElements = []
const observe = async () => {
  const state = await call(a11y, { op: 'elements' })
  const listing = await call(seat, { args: ['windows'] })
  latestElements = state.elements ?? []
  return { ...state, focused: listing.focused, windows: listing.windows }
}
try {
  for (const [index, spec] of cases.entries()) {
    let initial
    for (let retry = 0; retry < 100; retry++) {
      initial = await observe()
      if (initial.window?.title === `Specialist case ${index}` && initial.elements?.length >= spec.fields.length + 3) break
      await new Promise(r => setTimeout(r, 50))
    }
    if (initial.window?.title !== `Specialist case ${index}`) throw new Error('fixture did not advance')
    const task = { objective: spec.objective, goal: spec.goal, window: initial.focused, maxActions: 8, ...(choices ? { values: spec.fields } : {}) }
    let wrongTextActions = 0
    let perturb = !!spec.stale
    const options = {
      observe,
      decide: async (observation, signal) => {
        const policy = choices ? choiceDecision(process.env.CABOOSE_SPECIALIST_ENDPOINT) : model ? phoneDecision(model, process.env.CABOOSE_SPECIALIST_ENDPOINT) : async ({ elements }) => {
        for (const field of spec.fields) {
          const element = elements.find(e => e.name === field.name && e.role === 'text')
          if (element?.value !== field.value) return { action: 'set_text', id: element?.id, text: field.value }
        }
        const toggle = elements.find(e => e.name === spec.toggle && e.role === 'check box')
        return { action: 'click_element', id: toggle?.states.includes('checked') ? elements.find(e => e.name === spec.submit)?.id : toggle?.id }
        }
        const choice = await policy(observation, signal)
        if (perturb) {
          perturb = false
          process.kill(Number(fixturePid), 'SIGUSR2')
          for (let retry = 0; retry < 100; retry++) {
            const events = (await readFile('/tmp/workflow-effects.jsonl', 'utf8')).split('\n').filter(Boolean).map(JSON.parse)
            if (events.some(e => e.case === index && e.event === 'rearranged')) break
            await new Promise(r => setTimeout(r, 20))
          }
        }
        return choice
      },
      act: async action => {
        if (action.action === 'set_text') {
          const target = latestElements.find(e => e.id === action.id)
          const field = spec.fields.find(f => f.name === target?.name)
          if (!field || action.text !== field.value) wrongTextActions++
        }
        const r = await call(a11y, { op: 'act', element: action.id, action: action.action === 'set_text' ? 'set-text' : action.action === 'focus_element' ? 'focus' : 'press', ...(action.text !== undefined ? { text: action.text } : {}) })
        if (!r.ok) throw new Error('action outcome unknown')
      },
      trace: row => appendFile(output + '.traces.jsonl', JSON.stringify({ split: spec.split, case: index, policy: choices ? 'choices' : model ?? 'oracle', ...row }) + '\n'),
    }
    let result = await runSpecialist(task, options)
    let staleResult
    if (spec.stale) {
      staleResult = result
      if (result.status === 'rejected' && result.metrics.actions === 0) result = await runSpecialist(task, options)
    }
    const effects = (await readFile('/tmp/workflow-effects.jsonl', 'utf8')).split('\n').filter(Boolean).map(JSON.parse).filter(e => e.case === index)
    const wrongActions = wrongTextActions + effects.filter(e => e.event === 'wrong_control' || e.event === 'submit' && !e.correct).length
    const completed = spec.ambiguous ? result.status === 'needs_clarification' && result.metrics.actions === 0 : result.status === 'verified' && effects.some(e => e.event === 'submit' && e.correct) && (!spec.stale || staleResult.status === 'rejected' && staleResult.metrics.actions === 0)
    await appendFile(output, JSON.stringify({ split: spec.split, case: index, model: choices ? 'choices' : model ?? 'oracle', ...result, ...(staleResult ? { staleResult } : {}), completed, wrongActions }) + '\n')
    if (!completed || wrongActions) process.exitCode = 1
    process.kill(Number(fixturePid), 'SIGUSR1')
  }
} finally { a11y.close(); seat.close() }
