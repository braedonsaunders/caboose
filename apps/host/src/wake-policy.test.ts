import { expect, it } from 'vitest'
import { needsOwnerDisplay } from './wake-policy.js'

it('promotes owner-seat operations, leaving file and agent work headless', () => {
  for (const [method, path] of [['POST', '/v1/open'], ['POST', '/v1/apps/foo.desktop/launch'], ['POST', '/v1/agents/codex-acp/sign-in'], ['GET', '/v1/screen/elements'], ['POST', '/v1/screen/act'], ['POST', '/v1/screen/type'], ['POST', '/v1/screen/keys']] as const) {
    expect(needsOwnerDisplay(method, path), `${method} ${path}`).toBe(true)
  }
  for (const [method, path] of [['GET', '/v1/fs/list'], ['POST', '/v1/catalog/pdfcraft/run'], ['POST', '/v1/agent/tasks'], ['POST', '/v1/agents/codex-acp/sign-in/callback'], ['GET', '/v1/computer'], ['GET', '/v1/apps']] as const) {
    expect(needsOwnerDisplay(method, path), `${method} ${path}`).toBe(false)
  }
})
