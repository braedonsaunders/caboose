import type { AgentGuest } from './agents.js'

/**
 * The operator's root access to a running computer, whatever its runtime (docs/architecture.md §
 * Host): a command with its exit status and both outputs, and a file written into it. It is how
 * caboose-release installs a sealed release into a microVM, which has no `docker exec`.
 */

/** Runs "$@" and appends its exit status and its standard error (base64) as a last line. */
export const EXEC_WRAPPER = 'e=$(mktemp) || exit 125; "$@" 2>"$e"; c=$?; printf "\\n\\036%s %s" "$c" "$(base64 -w0 < "$e")"; rm -f "$e"'

export interface ExecResult { exitCode: number; stdout: string; stderr: string }

export class HostExecInputError extends Error {}

/** The command, its arguments and its time limit from a request body. */
export function parseExec(body: unknown): { command: string; args: string[]; timeoutMs: number } {
  const value = (body ?? {}) as Record<string, unknown>
  if (typeof body !== 'object' || body === null || Object.keys(value).some(key => !['command', 'args', 'timeoutMs'].includes(key))) throw new HostExecInputError('The body is { command, args?, timeoutMs? }')
  if (typeof value.command !== 'string' || !value.command.startsWith('/') || value.command.length > 4096 || value.command.includes('\0')) throw new HostExecInputError('command must be an absolute path')
  const args = value.args ?? []
  if (!Array.isArray(args) || args.length > 256 || !args.every(arg => typeof arg === 'string' && !arg.includes('\0') && arg.length <= 65536)) throw new HostExecInputError('args must be at most 256 strings')
  const timeoutMs = value.timeoutMs ?? 60_000
  if (!Number.isInteger(timeoutMs) || (timeoutMs as number) < 1000 || (timeoutMs as number) > 3_600_000) throw new HostExecInputError('timeoutMs must be 1000 to 3600000')
  return { command: value.command, args: args as string[], timeoutMs: timeoutMs as number }
}

/** The wrapped command's output split into its standard output, exit status and standard error. */
export function parseWrapped(output: string): ExecResult {
  const at = output.lastIndexOf('\n\x1e')
  if (at < 0) throw new Error('The computer did not report the command\'s exit status')
  const [code, stderr = ''] = output.slice(at + 2).trim().split(' ')
  const exitCode = Number(code)
  if (!Number.isInteger(exitCode)) throw new Error('The computer reported an invalid exit status')
  return { exitCode, stdout: output.slice(0, at), stderr: Buffer.from(stderr, 'base64').toString('utf8') }
}

export async function execute(guest: AgentGuest, command: string, args: string[], timeoutMs: number): Promise<ExecResult> {
  return parseWrapped(await guest.run('/bin/sh', ['-c', EXEC_WRAPPER, 'sh', command, ...args], timeoutMs))
}

/** An absolute guest path and an octal mode from a file request's query. */
export function parseFileTarget(query: URLSearchParams): { path: string; mode: string } {
  const path = query.get('path') ?? ''
  if (!path.startsWith('/') || path.length > 4096 || path.includes('\0') || path.split('/').includes('..') || path.endsWith('/')) throw new HostExecInputError('path must be an absolute file path without ".."')
  const mode = query.get('mode') ?? '0600'
  if (!/^0?[0-7]{3,4}$/.test(mode)) throw new HostExecInputError('mode must be octal, such as 0644')
  return { path, mode }
}

const CHUNK = 48 * 1024

/** Writes `data` to `path` in the computer as root: beside it first, then renamed into place. */
export async function writeFile(guest: AgentGuest, path: string, mode: string, data: Buffer): Promise<void> {
  const partial = `${path}.caboose-upload`
  await guest.run('/bin/sh', ['-c', 'mkdir -p "${1%/*}" && : > "$1" && chmod "$2" "$1"', 'sh', partial, mode], 15_000)
  const base64 = data.toString('base64')
  for (let offset = 0; offset < base64.length; offset += CHUNK) {
    await guest.run('/bin/sh', ['-c', 'printf %s "$2" | base64 -d >> "$1"', 'sh', partial, base64.slice(offset, offset + CHUNK)], 60_000)
  }
  await guest.run('/bin/mv', ['-f', '--', partial, path], 15_000)
}
