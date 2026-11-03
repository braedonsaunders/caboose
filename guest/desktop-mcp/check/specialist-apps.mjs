// Real applications, real trajectories: each case launches its application in a fresh home,
// runs the product controller (runSpecialist) with the oracle or --choices, and checks the
// effect independently (window title or control state, plus the file it wrote).
// usage: node specialist-apps.mjs CASES OUTPUT [--choices]
import { spawn } from 'node:child_process'
import { readFile, appendFile, mkdir, rm, writeFile } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import { Worker } from '../worker.mjs'
import { actionChoices, choiceDecision } from '../choices.mjs'
import { runSpecialist, taskWindows } from '../specialist.mjs'
const [casesPath, output] = process.argv.slice(2)
const choices = process.argv.includes('--choices')
const cases = JSON.parse(await readFile(casesPath, 'utf8'))
const home = process.env.HOME
const a11y = new Worker(new URL('../a11y.py', import.meta.url).pathname, ['--display=:101'], 10_000)
const seat = new Worker(new URL('../seat.py', import.meta.url).pathname, [], 10_000)
const env = { ...process.env }
const call = async (worker, body) => { const r = await worker.request(body, env); if (r.error) throw new Error(r.error); return r }
const sleep = ms => new Promise(r => setTimeout(r, ms))
const observe = async () => {
  await call(seat, { args: ['settle'] })
  const state = await call(a11y, { op: 'elements' })
  const listing = await call(seat, { args: ['windows'] })
  return { ...state, focused: listing.focused, windows: listing.windows }
}
try {
  for (const [index, spec] of cases.entries()) {
    for (const dir of ['.config', '.local', '.cache', 'Documents']) await rm(join(home, dir), { recursive: true, force: true })
    for (const [path, content] of Object.entries(spec.files)) { await mkdir(dirname(join(home, path)), { recursive: true }); await writeFile(join(home, path), content) }
    const app = spawn(spec.app, spec.args, { env, detached: true, stdio: 'ignore' })
    let window
    for (let retry = 0; retry < 150 && !window; retry++) {
      await sleep(100)
      const listing = await call(seat, { args: ['windows'] }).catch(() => ({ windows: [] }))
      window = listing.windows.find(w => w.kind === 'toplevel' && w.app_id === spec.app && w.focused && w.title)
    }
    let result, oracleStep = 0
    if (!window) result = { status: 'interrupted', reason: 'application window did not appear', metrics: {} }
    else {
      await sleep(400)
      const task = { objective: spec.objective, goal: spec.goal, window: window.id, maxActions: 12, ...(spec.values.length ? { values: spec.values } : {}) }
      const policy = choices ? choiceDecision(process.env.CABOOSE_SPECIALIST_ENDPOINT) : async observation => {
        const pattern = new RegExp(spec.oracle[oracleStep] ?? '^$')
        const chosen = actionChoices(observation).candidates.find(c => pattern.test(c.label))
        if (!chosen) return { action: 'blocked', reason: `oracle step ${oracleStep} has no matching choice` }
        oracleStep++
        return chosen.action
      }
      result = await runSpecialist(task, {
        observe, decide: policy,
        act: async action => {
          const r = await call(a11y, { op: 'act', element: action.id, action: action.action === 'set_text' ? 'set-text' : action.action === 'focus_element' ? 'focus' : 'press', ...(action.text !== undefined ? { text: action.text } : {}) })
          if (!r.ok) throw new Error('action outcome unknown')
        },
        trace: row => appendFile(output + '.traces.jsonl', JSON.stringify({ split: spec.split, case: index, family: spec.family, policy: choices ? 'choices' : 'oracle', ...row }) + '\n'),
      })
    }
    let checked = true
    if (spec.check?.file) checked = await readFile(join(home, spec.check.file), 'utf8').then(text => text.replace(/\n$/, '') === spec.check.content, () => false)
    const completed = result.status === 'verified' && checked
    // A failure records the seat's windows, so focus and ownership problems can be read back.
    const windows = completed ? undefined : (await call(seat, { args: ['windows'] }).catch(() => ({}))).windows?.map(w => ({ id: w.id, parent: w.parent, kind: w.kind, pid: w.pid, app: w.app_id, title: w.title, focused: w.focused }))
    await appendFile(output, JSON.stringify({ split: spec.split, case: index, family: spec.family, model: choices ? 'choices' : 'oracle', task: window?.id, ...result, checked, completed, ...(windows ? { windows } : {}) }) + '\n')
    if (!completed) process.exitCode = 1
    try { process.kill(-app.pid, 'SIGTERM') } catch {}
    for (let retry = 0; retry < 50; retry++) {
      const listing = await call(seat, { args: ['windows'] }).catch(() => ({ windows: [] }))
      if (!listing.windows.some(w => w.app_id === spec.app)) break
      await sleep(100)
    }
  }
} finally { a11y.close(); seat.close() }
