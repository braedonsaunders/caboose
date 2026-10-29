import { AgentInputError, AgentNotFoundError } from './agents.js'

/** One of a desktop entry's actions (`Actions=` and its `[Desktop Action <id>]` group). */
export interface AppAction { id: string; name: string }

/** Desktop action ids are [A-Za-z0-9-]; guest-apps.py lists and launches the same bound. */
export const APP_ACTION_ID = /^[A-Za-z0-9-]{1,64}$/

/** The optional `POST /v1/apps/:id/launch` body: `{ action }` names one of the entry's actions. */
export function parseAppLaunch(body: Record<string, unknown>): { action?: string } {
  const { action } = body
  if (action === undefined) return {}
  if (typeof action !== 'string' || !APP_ACTION_ID.test(action)) throw new AgentInputError('action must be a desktop action id: 1 to 64 of A-Z, a-z, 0-9 and -')
  return { action }
}

/** guest-apps.py's arguments: `launch <id> [file]`, or `action <id> <action>`. */
export function guestLaunchArgs(id: string, path?: string, action?: string): string[] {
  if (action === undefined) return ['launch', id, ...(path ? [path] : [])]
  if (path) throw new AgentInputError('an action launch does not open a file')
  if (!APP_ACTION_ID.test(action)) throw new AgentInputError('invalid desktop action id')
  return ['action', id, action]
}

/** Runs a launch in the guest; an entry or action the guest does not have is a 404. */
export async function guestLaunch(run: (args: string[]) => Promise<string>, id: string, path?: string, action?: string): Promise<void> {
  try {
    await run(guestLaunchArgs(id, path, action))
  } catch (error) {
    const message = error instanceof Error ? error.message : ''
    if (message.includes('Application action not found')) throw new AgentNotFoundError('Application action not found')
    if (message.includes('Application not found')) throw new AgentNotFoundError('Application not found')
    throw error
  }
}
