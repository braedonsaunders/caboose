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
    }
    onStatus({ state: 'succeeded', version: payload.version })
  } catch (error) {
    onStatus({ state: 'failed', message: error instanceof Error ? error.message : String(error) })
  }
}
