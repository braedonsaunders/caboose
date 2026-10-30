import { expect, it, vi } from 'vitest'
import type { IncomingMessage, ServerResponse } from 'node:http'
import { recoveryRoute } from './recovery.js'
import type { ComputerBackups, RestoreContext } from './backup.js'

it('rejects missing, null and sibling origins before cookie-authenticated recovery mutations', async () => {
  const manageRecovery = vi.fn()
  const backups = { manageRecovery, recoveryStatus: async () => ({}) } as unknown as ComputerBackups
  const principal = { kind: 'admin' as const, userId: 'admin', name: 'Admin', email: 'admin@example.test', operator: true, tenantIds: [] }
  for (const origin of [undefined, 'null', 'https://evil.example.test', 'https://host.example.test:8443']) {
    const request = { method: 'POST', headers: { host: 'host.example.test', 'x-forwarded-proto': 'https', origin } } as unknown as IncomingMessage
    const response = { writeHead: vi.fn(), end: vi.fn() } as unknown as ServerResponse
    await recoveryRoute(backups, request, response, '/v1/recovery/capture', principal, {} as RestoreContext)
    expect(response.writeHead).toHaveBeenCalledWith(403, expect.anything())
  }
  expect(manageRecovery).not.toHaveBeenCalled()
  const request = { method: 'POST', headers: { host: 'host.example.test', 'x-forwarded-proto': 'https', origin: 'https://host.example.test' } } as unknown as IncomingMessage
  const response = { writeHead: vi.fn(), end: vi.fn() } as unknown as ServerResponse
  await recoveryRoute(backups, request, response, '/v1/recovery/capture', principal, {} as RestoreContext)
  expect(manageRecovery).toHaveBeenCalledOnce()
  request.headers.origin = undefined
  await recoveryRoute(backups, request, response, '/v1/recovery/capture', { kind: 'owner' }, {} as RestoreContext)
  expect(manageRecovery).toHaveBeenCalledTimes(2)
})
