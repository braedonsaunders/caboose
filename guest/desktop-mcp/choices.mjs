// A decision model selects a bounded option; only this module constructs actions.
// Conditions the controller can establish exactly (busy, nothing actionable, ambiguous
// labels, completion) are decided here or by the runner, never by the model.
import { createHash } from 'node:crypto'

const TOGGLE_ROLES = new Set(['check box', 'radio button', 'toggle button', 'check menu item', 'radio menu item'])
const PRESS_ROLES = new Set(['button', 'check box', 'radio button', 'toggle button', 'menu item', 'check menu item', 'radio menu item', 'page tab'])
const quote = text => JSON.stringify(text)
export const LETTERS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef'

// The one decision prompt every runtime and the trainer use. The answer is one token: the
// letter of a choice. The task line opens every step of a task unchanged, so a runtime can
// keep its KV cache; observed values are listed whether or not their control offers an action.
export function decisionPrompt(objective, elements, labels) {
  const values = elements.filter(e => e.value).map(e => `${e.name}=${quote(e.value)}`)
  return [`Task: ${objective}`, ...(values.length ? [`Values: ${values.join('; ')}`] : []),
    ...labels.map((label, i) => `${LETTERS[i]} ${label}`), 'Next:'].join('\n')
}

export function actionChoices({ objective, goal, elements, values = [] }) {
  const supplied = [...values]
  for (const part of goal.all ?? [goal]) {
    if (part.value !== undefined && !supplied.some(v => v.name === part.name && v.value === part.value))
      supplied.push({ name: part.name, value: part.value })
  }
  if (supplied.length > 12) throw new Error('too many value sources; delegate a smaller task')
  const editable = elements.filter(e => e.states?.includes('editable') && !e.states.includes('read-only') && !e.states.includes('disabled'))
  // A source named after an editable control is bound to it; other sources may fill any editable control.
  const bound = source => editable.some(e => e.name === source.name)
  const candidates = [{ label: 'BLOCKED the objective needs a control or value that no other choice provides', action: { action: 'blocked' } }]
  const controls = []
  for (const element of elements) {
    if (element.name.length > 200 || (element.value?.length ?? 0) > 200) throw new Error('control text exceeds compact observation budget')
    controls.push([element.role, element.name, element.value ?? '', element.states ?? []])
    if (element.states?.includes('disabled')) continue
    const actions = element.actions ?? (PRESS_ROLES.has(element.role) ? ['press'] : [])
    if (actions.includes('press')) {
      const detail = TOGGLE_ROLES.has(element.role) ? `${element.role}, ${element.states?.includes('checked') ? 'checked' : 'not checked'}` : element.role
      candidates.push({ label: `PRESS ${element.name} (${detail})`, action: { action: 'click_element', id: element.id } })
    }
    if (editable.includes(element)) {
      const own = supplied.filter(s => s.name === element.name)
      for (const source of own.length ? own : supplied.filter(s => !bound(s))) {
        if (element.value === source.value) continue
        const current = element.value ? `${quote(element.value)}` : 'empty'
        const origin = source.name === element.name ? '' : ` (source ${source.name})`
        candidates.push({ label: `SET ${element.name} from ${current} to ${quote(source.value)}${origin}`, action: { action: 'set_text', id: element.id, text: source.value } })
      }
    }
  }
  if (candidates.length > LETTERS.length) throw new Error('more than 32 choices; delegate a smaller task')
  const state = JSON.stringify({ objective, goal, controls })
  const revision = createHash('sha256').update(JSON.stringify({ state, candidates })).digest('hex').slice(0, 24)
  return { state, revision, candidates, prompt: decisionPrompt(objective, elements, candidates.map(c => c.label)) }
}

// The phone's decision model through Caboose AI (docs/ai.md § Decisions); the development MLX
// service (check/specialist-mlx-decide.py) answers the same request on another port.
export function choiceDecision(endpoint = 'http://127.0.0.1:11434/v1/decision', model = '') {
  return async (observation, signal) => {
    if (observation.elements.some(e => e.states?.includes('busy'))) return { action: 'wait' }
    let request
    try { request = actionChoices(observation) }
    catch (error) { return { action: 'blocked', reason: error.message } }
    if (request.candidates.length < 2) return { action: 'blocked', reason: 'no enabled control offers an action' }
    if (new Set(request.candidates.map(c => c.label)).size !== request.candidates.length) return { action: 'blocked', reason: 'controls are ambiguous without more context' }
    if (request.prompt.length > 6000) return { action: 'blocked', reason: 'observation exceeds the decision budget; delegate a smaller task' }
    const response = await fetch(endpoint, {
      method: 'POST', signal: AbortSignal.any([AbortSignal.timeout(10_000), ...(signal ? [signal] : [])]),
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ model, prompt: request.prompt, revision: request.revision, choices: request.candidates.length }),
    })
    if (!response.ok) throw new Error(`decision service unavailable (HTTP ${response.status})`)
    const selected = await response.json()
    if ((selected.revision !== undefined && selected.revision !== request.revision) || !Number.isInteger(selected.choice) || !request.candidates[selected.choice])
      throw new Error('decision does not identify a choice from this observation')
    return request.candidates[selected.choice].action
  }
}
