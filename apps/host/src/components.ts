import { createHash } from 'node:crypto'
import { readFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import { join } from 'node:path'
import type { AgentGuest } from './agents.js'

export type ComponentsMode = 'vm' | 'container'
export interface Bundle { version: string; files: { name: string; data: Buffer }[] }
export interface UpgradeStatus { state: 'checking' | 'updating' | 'succeeded' | 'failed'; version?: string; message?: string }
const root = fileURLToPath(new URL('../../../guest/', import.meta.url))
const CHUNK = 48 * 1024

/** Hash filenames and exact bytes; the guest image builder computes the same hash. */
export async function readBundle(directory = root): Promise<Bundle> {
  const manifest = await readFile(join(directory, 'components/manifest.json'))
  const names: unknown = JSON.parse(manifest.toString())
  if (!Array.isArray(names) || !names.length || names.some(n => typeof n !== 'string' || !/^[a-z0-9][a-z0-9._/-]*$/.test(n) || n.split('/').includes('..'))) throw new Error('Invalid components manifest')
  const hash = createHash('sha256')
  const files: Bundle['files'] = []
  for (const name of names as string[]) {
    const data = await readFile(join(directory, name))
    hash.update(name).update('\0').update(data).update('\0')
    files.push({ name, data })
  }
  files.push({ name: 'components/manifest.json', data: manifest })
  return { version: hash.digest('hex'), files }
}

export function needsUpgrade(installed: string, wanted: string): boolean { return installed.trim() !== wanted }

/** Guard optional printing in an older container without changing its display implementation. */
export async function guardContainerPrinting(guest: AgentGuest): Promise<void> {
  const script = String.raw`import os, pathlib, stat, tempfile
p = pathlib.Path('/usr/local/bin/caboose-session')
if p.exists():
    original = p.read_text()
    guard = '  [ -x /usr/local/libexec/caboose-phone-printer-setup ] && command -v lpstat >/dev/null && [ -x /usr/sbin/cupsd ] || return 0\n'
    updated = original
    if guard not in updated:
        updated = updated.replace('start_printing() {\n', 'start_printing() {\n' + guard)
    updated = updated.replace('start_printing; ', 'start_printing || echo "Printing unavailable" >&2; ')
    if updated != original:
        fd, tmp = tempfile.mkstemp(prefix='.caboose-session-', dir=p.parent)
        try:
            with os.fdopen(fd, 'w') as f: f.write(updated)
            os.chmod(tmp, stat.S_IMODE(p.stat().st_mode))
            os.replace(tmp, p)
        finally:
            if os.path.exists(tmp): os.unlink(tmp)`
  await guest.run('/usr/bin/python3', ['-c', script], 30_000)
}

/** Root-owned staging; arguments are bounded below the guest exec channel's per-argument limit. */
export async function upgradeComponents(guest: AgentGuest, mode: ComponentsMode, onStatus: (s: UpgradeStatus) => void, bundle?: Bundle): Promise<void> {
  onStatus({ state: 'checking' })
  try {
    const payload = bundle ?? await readBundle()
    const installed = await guest.run('/bin/sh', ['-c', 'cat /usr/local/share/caboose/components.version 2>/dev/null || true'], 15_000)
    if (needsUpgrade(installed, payload.version)) {
      onStatus({ state: 'updating', version: payload.version })
      const dir = (await guest.run('/bin/mktemp', ['-d', '/tmp/caboose-components.XXXXXXXX'], 15_000)).trim()
      if (!/^\/tmp\/caboose-components\.[A-Za-z0-9]+$/.test(dir)) throw new Error('Guest returned an invalid staging directory')
      try {
        for (const file of payload.files) {
          const path = `${dir}/${file.name}`
          await guest.run('/bin/sh', ['-c', 'mkdir -p "${1%/*}" && : > "$1"', 'sh', path], 15_000)
          const base64 = file.data.toString('base64')
          for (let offset = 0; offset < base64.length; offset += CHUNK) {
            await guest.run('/bin/sh', ['-c', 'printf %s "$2" | base64 -d >> "$1"', 'sh', path, base64.slice(offset, offset + CHUNK)], 30_000)
          }
        }
        await guest.run('/bin/bash', [`${dir}/components/install.sh`, mode], 900_000)
        const actual = await guest.run('/bin/cat', ['/usr/local/share/caboose/components.version'], 15_000)
        if (needsUpgrade(actual, payload.version)) throw new Error('Guest components version did not match the installed bundle')
      } finally {
        await guest.run('/bin/rm', ['-rf', '--', dir], 15_000).catch(() => {})
      }
    } else if (mode === 'container') {
      await guest.run('/usr/local/libexec/caboose-components-services', [], 70_000)
    } else {
      await guest.run('/bin/sh', ['-c', 'systemctl start caboose-files.service; for i in $(seq 1 60); do systemctl is-active --quiet caboose-files.service && ss -lnt | grep -Eq ":14700[[:space:]]" && exit 0; sleep 1; done; echo file-service-not-ready >&2; exit 1'], 70_000)
    }
    onStatus({ state: 'succeeded', version: payload.version })
  } catch (error) {
    onStatus({ state: 'failed', message: upgradeFailure(error) })
  }
}

/**
 * What a failed upgrade reports: the guest's own last lines, without the command channel's
 * prefix, with repeats collapsed and at most 300 characters, so a status screen can show it.
 */
export function upgradeFailure(error: unknown): string {
  const text = (error instanceof Error ? error.message : String(error)).replace(/^(Guest command failed|docker exec failed):\s*/, '')
  const lines: string[] = []
  for (const line of text.split('\n').map(item => item.trim()).filter(Boolean)) if (lines.at(-1) !== line) lines.push(line)
  const summary = lines.slice(-2).join(' — ')
  return summary.length > 300 ? `${summary.slice(0, 299)}…` : summary || 'The upgrade failed.'
}
