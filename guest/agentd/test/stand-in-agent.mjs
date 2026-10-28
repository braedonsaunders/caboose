#!/usr/bin/env node
// A stand-in ACP agent for caboose-agentd's tests and the shell check, written with the
// official SDK's agent side. It needs no model: what it does is chosen by words in the prompt.
//
//   STAND_IN_STATE  directory for sessions (so a new process can load or resume) and sign-in
//   STAND_IN_CAPS   comma list of: load, resume, image
//   STAND_IN_AUTH   "1": session/new answers auth_required until signed in
//   STAND_IN_CALLBACK  "1": signing in opens a page with xdg-open, as a browser sign-in does,
//                   and finishes when http://localhost:<port>/callback is requested
//   --login         terminal sign-in: marks the state signed in and exits 0
//
// Each sign-in writes `sign-in-env` in the state directory: its DISPLAY (or "none") and STAND_IN_LOGIN.
//
// Prompt words: tool, plan, env (reports STAND_IN_GREETING), ask, stream (one message in slow chunks), slow (waits for cancel), stubborn (ignores cancel),
// write-home, write-outside, crash, refuse. Every turn answers "heard: <first line>" and a
// line describing what it received.
import { execFileSync } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { createServer } from 'node:http'
import { join } from 'node:path'
import { Readable, Writable } from 'node:stream'
import { setTimeout as sleep } from 'node:timers/promises'
import * as acp from '@agentclientprotocol/sdk'

const state = process.env.STAND_IN_STATE ?? process.cwd()
mkdirSync(state, { recursive: true })
const signedInFile = join(state, 'signed-in')
const recordSignInEnv = () => writeFileSync(join(state, 'sign-in-env'), `${process.env.DISPLAY || 'none'} ${process.env.STAND_IN_LOGIN || 'none'}`)
if (process.argv.includes('--login')) {
  recordSignInEnv()
  writeFileSync(signedInFile, 'terminal')
  console.log('Signed in to the stand-in agent.')
  process.exit(0)
}

/** A browser sign-in: opens the provider's page, which sends the browser back to a server here. */
function browserSignIn() {
  return new Promise((resolvePromise, reject) => {
    const server = createServer((request, response) => {
      if (request.url === '/done') { response.writeHead(200).end('Signed in.'); return }
      if (!request.url?.startsWith('/callback?code=')) { response.writeHead(404).end(); return }
      response.writeHead(302, { location: '/done' }).end()
      resolvePromise()
    })
    server.listen(0, '127.0.0.1', () => {
      const back = `http://localhost:${server.address().port}/callback`
      try { execFileSync('xdg-open', [`https://example.com/authorize?redirect_uri=${encodeURIComponent(back)}`]) } catch (error) { reject(error) }
    })
  })
}
const caps = new Set((process.env.STAND_IN_CAPS ?? '').split(',').filter(Boolean))
function modelState(session) {
  if (caps.has('models')) return { configOptions: [{ id: 'engine', name: 'Model', category: 'model', type: 'select', currentValue: session.model ?? 'alpha', options: [{ group: 'test', name: 'Test', options: [{ value: 'alpha', name: 'Alpha' }, { value: 'beta', name: 'Beta' }] }] }] }
  if (caps.has('legacy-models')) return { models: { currentModelId: session.model ?? 'alpha', availableModels: [{ id: 'alpha', name: 'Alpha' }, { id: 'beta', name: 'Beta' }] } }
  return {}
}
const sessions = new Map()
const sessionFile = id => join(state, `session-${id}.json`)
const save = session => writeFileSync(sessionFile(session.id), JSON.stringify({ id: session.id, history: session.history, mcp: session.mcp, model: session.model }))
const restore = id => existsSync(sessionFile(id)) ? { ...JSON.parse(readFileSync(sessionFile(id), 'utf8')), cancelled: false } : undefined
const needsSignIn = () => process.env.STAND_IN_AUTH === '1' && !existsSync(signedInFile)

const app = acp.agent({ name: 'stand-in' })
  .onRequest('initialize', () => ({
    protocolVersion: acp.PROTOCOL_VERSION,
    agentCapabilities: {
      loadSession: caps.has('load'),
      promptCapabilities: { image: caps.has('image'), audio: false, embeddedContext: false },
      sessionCapabilities: caps.has('resume') ? { resume: {} } : {},
    },
    agentInfo: { name: 'stand-in', title: 'Stand-in', version: '1.0.0' },
    authMethods: [
      { id: 'stand-in-login', name: 'Stand-in account', description: 'Sign in through the agent' },
      { id: 'stand-in-terminal', name: 'Stand-in terminal', type: 'terminal', args: ['--login'], env: { STAND_IN_LOGIN: '1' } },
    ],
  }))
  .onRequest('authenticate', async ({ params }) => {
    if (params.methodId !== 'stand-in-login') throw acp.RequestError.invalidParams(undefined, 'unknown method')
    recordSignInEnv()
    if (process.env.STAND_IN_CALLBACK === '1') await browserSignIn()
    writeFileSync(signedInFile, 'agent')
    return {}
  })
  .onRequest('session/new', ({ params }) => {
    if (needsSignIn()) throw acp.RequestError.authRequired(undefined, 'Sign in to the stand-in first')
    const session = { id: `stand-in-${Date.now()}-${Math.random().toString(16).slice(2, 8)}`, history: [], mcp: params.mcpServers.map(server => server.name), cancelled: false }
    sessions.set(session.id, session)
    save(session)
    return { ...modelState(session), sessionId: session.id, modes: { currentModeId: 'default', availableModes: [{ id: 'default', name: 'Default' }] } }
  })
  .onRequest('session/load', async ({ params, client }) => {
    if (!caps.has('load')) throw acp.RequestError.methodNotFound('session/load')
    const session = restore(params.sessionId)
    if (!session) throw acp.RequestError.resourceNotFound(params.sessionId)
    for (const turn of session.history) {
      await client.notify('session/update', { sessionId: session.id, update: { sessionUpdate: 'user_message_chunk', content: { type: 'text', text: turn.user } } })
      await client.notify('session/update', { sessionId: session.id, update: { sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: turn.agent } } })
    }
    session.mcp = params.mcpServers.map(server => server.name)
    sessions.set(session.id, session)
    return modelState(session)
  })
  .onRequest('session/resume', ({ params }) => {
    if (!caps.has('resume')) throw acp.RequestError.methodNotFound('session/resume')
    const session = restore(params.sessionId)
    if (!session) throw acp.RequestError.resourceNotFound(params.sessionId)
    session.mcp = (params.mcpServers ?? []).map(server => server.name)
    sessions.set(session.id, session)
    return modelState(session)
  })
  .onRequest('session/set_config_option', ({ params }) => {
    const session = sessions.get(params.sessionId)
    if (!caps.has('models') || params.configId !== 'engine' || !['alpha', 'beta'].includes(params.value)) throw acp.RequestError.invalidParams()
    session.model = params.value; save(session)
    return modelState(session)
  })
  .onRequest('session/set_model', value => value, ({ params }) => {
    const session = sessions.get(params.sessionId)
    if (!caps.has('legacy-models') || !['alpha', 'beta'].includes(params.modelId)) throw acp.RequestError.invalidParams()
    session.model = params.modelId; save(session); return {}
  })
  .onNotification('session/cancel', ({ params }) => {
    const session = sessions.get(params.sessionId)
    if (session) session.cancelled = true
  })
  .onRequest('session/prompt', async ({ params, client }) => {
    const session = sessions.get(params.sessionId)
    if (!session) throw acp.RequestError.resourceNotFound(params.sessionId)
    session.cancelled = false
    const text = params.prompt.filter(block => block.type === 'text').map(block => block.text).join('\n')
    const send = update => client.notify('session/update', { sessionId: session.id, update })
    const say = async (words, messageId = `m-${Math.random().toString(16).slice(2)}`) => {
      const middle = Math.ceil(words.length / 2)
      await send({ sessionUpdate: 'agent_message_chunk', messageId, content: { type: 'text', text: words.slice(0, middle) } })
      await send({ sessionUpdate: 'agent_message_chunk', messageId, content: { type: 'text', text: words.slice(middle) } })
    }
    const last = text.trim().split('\n').at(-1) ?? ''
    if (/\bcrash\b/.test(last)) process.exit(3)
    await send({ sessionUpdate: 'agent_thought_chunk', content: { type: 'text', text: 'Thinking about it.' } })
    await say(`heard: ${last}`)
    const blocks = params.prompt.map(block => block.type === 'image' ? `image:${block.mimeType}` : block.type === 'resource_link' ? `link:${block.name}` : block.type).join(',')
    await say(`turns in session: ${session.history.length + 1}; mcp: ${session.mcp.join(',') || 'none'}; blocks: ${blocks}; recap: ${text.includes('could not be reloaded') ? 'yes' : 'no'}; display: ${process.env.DISPLAY ?? ''}`)
    if (/\btool\b/.test(last)) {
      await send({ sessionUpdate: 'tool_call', toolCallId: 'call-1', title: 'Run echo hi', kind: 'execute', status: 'pending', rawInput: { command: 'echo hi' } })
      await send({ sessionUpdate: 'tool_call_update', toolCallId: 'call-1', status: 'in_progress' })
      await send({ sessionUpdate: 'tool_call_update', toolCallId: 'call-1', status: 'completed', content: [{ type: 'content', content: { type: 'text', text: 'hi' } }] })
    }
    if (last.includes('switch-model') && caps.has('models')) {
      session.model = 'beta'; save(session)
      await send({ sessionUpdate: 'config_option_update', ...modelState(session) })
    }
    if (/\bmodel\b/.test(last)) await say(`model: ${session.model ?? 'alpha'}`)
    if (/\benv\b/.test(last)) await say(`env: ${process.env.STAND_IN_GREETING ?? 'unset'}`)
    if (/\bplan\b/.test(last)) {
      await send({ sessionUpdate: 'plan', entries: [{ content: 'Look around', priority: 'high', status: 'completed' }, { content: 'Do the thing', priority: 'medium', status: 'pending' }] })
    }
    if (/\bask\b/.test(last)) {
      await send({ sessionUpdate: 'tool_call', toolCallId: 'call-2', title: 'Delete build', kind: 'delete', status: 'pending', rawInput: { command: 'rm -rf build' } })
      const answer = await client.request('session/request_permission', {
        sessionId: session.id,
        toolCall: { toolCallId: 'call-2' },
        options: [
          { optionId: 'yes', name: 'Allow', kind: 'allow_once' },
          { optionId: 'always', name: 'Always allow', kind: 'allow_always' },
          { optionId: 'no', name: 'Reject', kind: 'reject_once' },
        ],
      })
      if (answer.outcome.outcome === 'cancelled') return { stopReason: 'cancelled' }
      await say(`permission: ${answer.outcome.optionId}`)
    }
    if (/\bwrite-home\b/.test(last)) {
      const path = join(process.env.HOME, 'notes', 'stand-in.txt')
      await client.request('fs/write_text_file', { sessionId: session.id, path, content: 'one\ntwo\nthree' })
      const read = await client.request('fs/read_text_file', { sessionId: session.id, path, line: 2, limit: 1 })
      await say(`read back: ${read.content}`)
    }
    if (/\bwrite-outside\b/.test(last)) {
      try {
        await client.request('fs/write_text_file', { sessionId: session.id, path: '/etc/stand-in.txt', content: 'x' })
        await say('outside write: allowed')
      } catch (error) {
        await say(`outside write: refused (${error.message})`)
      }
    }
    if (/\bstream\b/.test(last)) {
      for (const word of ['one', 'two', 'three', 'four', 'five', 'six']) {
        await send({ sessionUpdate: 'agent_message_chunk', messageId: 'streamed', content: { type: 'text', text: `${word} ` } })
        await sleep(150)
      }
    }
    if (/\bslow\b/.test(last)) {
      for (let i = 0; i < 300 && !session.cancelled; i++) await sleep(100)
      if (session.cancelled) {
        await send({ sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'stopping' } })
        return { stopReason: 'cancelled' }
      }
    }
    if (/\bstubborn\b/.test(last)) await new Promise(() => {})
    await send({ sessionUpdate: 'usage_update', used: 100 * (session.history.length + 1), size: 1000 })
    session.history.push({ user: text, agent: `heard: ${last}` })
    save(session)
    await say(`done: ${last}`)
    if (/\brefuse\b/.test(last)) return { stopReason: 'refusal' }
    return { stopReason: 'end_turn' }
  })

const connection = app.connect(acp.ndJsonStream(Writable.toWeb(process.stdout), Readable.toWeb(process.stdin)))
await connection.closed
