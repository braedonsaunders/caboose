// Real applications, real trajectories: each case launches its application in a fresh home,
// runs the product controller (runSpecialist) with the oracle or --choices, and checks the
// effect independently (window title or control state, plus the file it wrote). A case
// without a goal is one stage of a longer task, recorded for its steps: the oracle run is
// complete when every oracle step was taken and the effect check passes.
// usage: node specialist-apps.mjs CASES OUTPUT [--choices]
import { spawn, spawnSync } from 'node:child_process'
import { readFile, appendFile, mkdir, rm, stat, writeFile } from 'node:fs/promises'
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
// When the last action went in, on the compositor's clock (CLOCK_MONOTONIC), so the next
// observation waits for the seat to react to it.
let actedAt, typed = false
const observe = async (_window, { settle = true } = {}) => {
  // A text edit is processed asynchronously (completion, validation): wait for the window to
  // go quiet. After a press, the first reaction is enough for an accessibility read.
  if (settle) await call(seat, { args: ['settle', typed ? 'quiet' : 'react', ...(actedAt === undefined ? [] : [String(actedAt)])] })
  if (settle) typed = false
  if (settle) actedAt = undefined
  const state = await call(a11y, { op: 'elements' })
  const listing = await call(seat, { args: ['windows'] })
  return { ...state, focused: listing.focused, windows: listing.windows }
}
try {
  for (const [index, spec] of cases.entries()) {
    for (const dir of ['.config', '.local', '.cache', 'Documents']) await rm(join(home, dir), { recursive: true, force: true })
    for (const [path, content] of Object.entries(spec.files)) { await mkdir(dirname(join(home, path)), { recursive: true }); await writeFile(join(home, path), content) }
    const app = spawn(spec.app, spec.args, { env, detached: true, stdio: 'ignore' })
    const appId = spec.app_id ?? spec.app
    let window
    for (let retry = 0; retry < 150 && !window; retry++) {
      await sleep(100)
      const listing = await call(seat, { args: ['windows'] }).catch(() => ({ windows: [] }))
      window = listing.windows.find(w => w.kind === 'toplevel' && w.app_id === appId && w.focused && w.title)
    }
    let result, oracleStep = 0, waited = 0
    if (!window) result = { status: 'interrupted', reason: 'application window did not appear', metrics: {} }
    else {
      await sleep(400)
      const task = { objective: spec.objective, goal: spec.goal ?? { title: '(one stage of a longer task)' }, window: window.id, maxActions: 12, ...(spec.values.length ? { values: spec.values } : {}) }
      const policy = choices ? choiceDecision(process.env.CABOOSE_SPECIALIST_ENDPOINT) : async observation => {
        if (!spec.goal && oracleStep === spec.oracle.length) return { action: 'blocked', reason: 'oracle complete' }
        // After its last step the oracle lets a goal that shows asynchronously (a page's title) arrive.
        if (oracleStep === spec.oracle.length && waited++ < 10) return { action: 'wait' }
        const pattern = new RegExp(spec.oracle[oracleStep] ?? '^$')
        const chosen = actionChoices(observation).candidates.find(c => pattern.test(c.label))
        if (!chosen) return { action: 'blocked', reason: `oracle step ${oracleStep} has no matching choice` }
        oracleStep++
        return chosen.action
      }
      result = await runSpecialist(task, {
        observe, decide: policy,
        act: async action => {
          actedAt = Number(process.hrtime.bigint() / 1000n); typed = action.action === 'set_text'
          const r = await call(a11y, { op: 'act', element: action.id, action: action.action === 'set_text' ? 'set-text' : action.action === 'focus_element' ? 'focus' : 'press', ...(action.text !== undefined ? { text: action.text } : {}) })
          if (!r.ok) throw new Error('action outcome unknown')
        },
        trace: row => appendFile(output + '.traces.jsonl', JSON.stringify({ split: spec.split, case: index, family: spec.family, policy: choices ? 'choices' : 'oracle', ...row }) + '\n'),
      })
    }
    let checked = true
    if (spec.check?.file) checked = await readFile(join(home, spec.check.file), 'utf8').then(text => text.replace(/\n$/, '') === spec.check.content, () => false)
    if (spec.check?.dir) checked = await stat(join(home, spec.check.dir)).then(s => s.isDirectory(), () => false)
    const completed = checked && (result.status === 'verified' || (!choices && !spec.goal && result.reason === 'oracle complete'))
    // A failure records the seat's windows, so focus and ownership problems can be read back.
    const windows = completed ? undefined : (await call(seat, { args: ['windows'] }).catch(() => ({}))).windows?.map(w => ({ id: w.id, parent: w.parent, kind: w.kind, pid: w.pid, app: w.app_id, title: w.title, focused: w.focused }))
    await appendFile(output, JSON.stringify({ split: spec.split, case: index, family: spec.family, model: choices ? 'choices' : 'oracle', task: window?.id, ...result, checked, completed, ...(windows ? { windows } : {}) }) + '\n')
    if (!completed) process.exitCode = 1
    try { process.kill(-app.pid, 'SIGTERM') } catch {}
    // An application may hand its window to an existing or forked process.
    for (const w of (await call(seat, { args: ['windows'] }).catch(() => ({ windows: [] }))).windows)
      if (w.app_id === appId && w.pid) try { process.kill(w.pid, 'SIGTERM') } catch {}
    for (let retry = 0; retry < 50; retry++) {
      const listing = await call(seat, { args: ['windows'] }).catch(() => ({ windows: [] }))
      if (!listing.windows.some(w => w.app_id === appId)) break
      await sleep(100)
    }
    // Settings an application keeps outside the case's home (its settings daemon) are reset.
    if (spec.reset) spawnSync(spec.reset[0], spec.reset.slice(1), { env, stdio: 'ignore', timeout: 5000 })
  }
} finally { a11y.close(); seat.close() }
