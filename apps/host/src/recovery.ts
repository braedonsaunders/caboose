import type { IncomingMessage, ServerResponse } from 'node:http'
import type { ComputerBackups, RestoreContext } from './backup.js'
import { json, readJson } from './http.js'
import type { Principal } from './server.js'
import { SettingsInputError } from './settings.js'

/** The server resolves tenant ownership before entering this handler. */
export async function recoveryRoute(backups: ComputerBackups | undefined, request: IncomingMessage, response: ServerResponse, path: string, principal: Principal, context: RestoreContext): Promise<void> {
  if (principal.kind === 'phone') return json(response, 403, { error: 'Only administrators manage host captures' })
  if (!backups) return json(response, request.method === 'GET' ? 200 : 409, { available: false, reason: 'Host captures require a Linux microVM with parked Files enabled', captures: [], captureReady: false, retention: { newest: 2, downloadingPhoneCapturesPinned: true }, lastOperation: null })
  if (path === '/v1/recovery' && request.method === 'GET') return json(response, 200, await backups.recoveryStatus())
  if (path === '/v1/recovery/capture' && request.method === 'POST') {
    await backups.manageRecovery('capture', context)
    return json(response, 200, await backups.recoveryStatus())
  }
  const restore = /^\/v1\/recovery\/captures\/([a-f0-9-]{36})\/restore$/.exec(path)
  if (restore && request.method === 'POST') {
    const body = await readJson(request)
    if (body.confirm !== restore[1]) throw new SettingsInputError('Confirm the selected capture id: restore replaces the disk, discards memory and all changes since capture, and restarts the computer')
    await backups.manageRecovery('restore', context, restore[1])
    return json(response, 200, await backups.recoveryStatus())
  }
  return json(response, 404, { error: 'not found' })
}
