// A decision model selects a bounded option; only this module constructs actions.
import { createHash } from 'node:crypto'

export function actionChoices({ objective, goal, elements, values = [] }) {
  const supplied = [...values]
  for (const part of goal.all ?? [goal]) {
    if (part.value !== undefined && !supplied.some(v => v.name === part.name && v.value === part.value))
      supplied.push({ name: part.name, value: part.value })
  }
  if (supplied.length > 12) throw new Error('too many value sources; delegate a smaller task')
  const candidates = [
    { label: 'WAIT for pending interface changes', action: { action: 'wait' } },
    { label: 'DONE all requested outcomes are observed', action: { action: 'done' } },
    { label: 'BLOCKED cannot safely choose from these controls or values', action: { action: 'blocked' } },
  ]
  const controls = []
  for (const [index, element] of elements.entries()) {
    if (element.name.length > 200 || (element.value?.length ?? 0) > 200) throw new Error('control text exceeds compact observation budget')
    controls.push([index, element.role, element.name, element.value ?? '', element.states ?? []])
    if (element.states?.includes('disabled')) continue
    const actions = element.actions ?? (['button', 'check box', 'radio button', 'menu item', 'page tab'].includes(element.role) ? ['press'] : [])
    if (actions.includes('press')) candidates.push({ label: `PRESS ${element.name} (${element.role})`, action: { action: 'click_element', id: element.id } })
    if (element.states?.includes('editable') && !element.states?.includes('read-only')) {
      for (const source of supplied) {
        if (element.value === source.value) continue
        candidates.push({ label: `SET ${element.name} = ${source.value} (source ${source.name})`, action: { action: 'set_text', id: element.id, text: source.value } })
      }
    }
  }
  if (candidates.length > 32) throw new Error('more than 32 choices; delegate a smaller task')
  const state = JSON.stringify({ objective, goal, controls })
  const revision = createHash('sha256').update(JSON.stringify({ state, candidates })).digest('hex').slice(0, 24)
  return { state, revision, candidates }
}

export function choiceDecision(endpoint = 'http://127.0.0.1:11435/v1/decision') {
  return async (observation, signal) => {
    let request
    try { request = actionChoices(observation) }
    catch (error) { return { action: 'blocked', reason: error.message } }
    if (new Set(request.candidates.map(c => c.label)).size !== request.candidates.length) return { action: 'blocked', reason: 'controls are ambiguous without more context' }
    const response = await fetch(endpoint, {
      method: 'POST', signal: AbortSignal.any([AbortSignal.timeout(10_000), ...(signal ? [signal] : [])]),
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ state: request.state, revision: request.revision, choices: request.candidates.map(c => c.label) }),
    })
    if (!response.ok) throw new Error(`decision service unavailable (HTTP ${response.status})`)
    const selected = await response.json()
    if (selected.revision !== request.revision || !Number.isInteger(selected.choice) || !request.candidates[selected.choice])
      throw new Error('decision does not identify a choice from this observation')
    return request.candidates[selected.choice].action
  }
}
