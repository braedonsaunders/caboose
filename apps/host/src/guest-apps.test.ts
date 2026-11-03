import { spawnSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync, existsSync, symlinkSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, describe, expect, it } from 'vitest'
import { AgentInputError, AgentNotFoundError } from './agents.js'
import { guestLaunch, guestLaunchArgs, parseAppLaunch } from './guest-apps.js'

const roots: string[] = []
afterEach(() => { for (const root of roots.splice(0)) rmSync(root, { recursive: true, force: true }) })

/** Stands in for PyGObject: icons render as fixed bytes, launches are recorded as JSON lines. */
const FAKE_GI = `import json, os
def _record(entry):
    with open(os.environ['TEST_LAUNCHES'], 'a') as log:
        log.write(json.dumps(entry) + '\\n')
class _Icon:
    def save_to_bufferv(self, *args):
        return True, b'png'
class _Theme:
    def load_icon(self, *args):
        return _Icon()
class Gtk:
    class IconTheme:
        @staticmethod
        def get_default():
            return _Theme()
    class IconLookupFlags:
        FORCE_SIZE = 0
class _Info:
    def __init__(self, path):
        self.path = path
    def launch(self, files, context):
        _record({'launch': os.path.basename(self.path), 'files': files})
        return True
    def launch_action(self, action, context):
        _record({'launch': os.path.basename(self.path), 'action': action})
class Gio:
    class AppLaunchContext:
        def setenv(self, name, value):
            pass
    class DesktopAppInfo:
        @staticmethod
        def new_from_filename(path):
            return _Info(path)
    class File:
        @staticmethod
        def new_for_path(path):
            return path
`

function fixture(entries: Record<string, string>, overrides: Record<string, string> = {}) {
  const root = mkdtempSync(join(tmpdir(), 'caboose-apps-test-')); roots.push(root)
  const applications = join(root, 'applications'), personal = join(root, 'personal'), gi = join(root, 'gi')
  mkdirSync(applications); mkdirSync(personal); mkdirSync(join(gi, 'repository'), { recursive: true })
  for (const [name, body] of Object.entries(overrides)) writeFileSync(join(personal, name), body)
  writeFileSync(join(gi, '__init__.py'), 'def require_version(*args):\n    pass\n')
  writeFileSync(join(gi, 'repository', '__init__.py'), FAKE_GI)
  for (const [name, body] of Object.entries(entries)) writeFileSync(join(applications, name), body)
  const original = readFileSync(new URL('./guest-apps.py', import.meta.url), 'utf8')
  const script = original.replace(/^ROOTS = .*$/m, `ROOTS = [pathlib.Path(${JSON.stringify(personal)}), pathlib.Path(${JSON.stringify(applications)})]`)
  expect(script).not.toBe(original)
  const launches = join(root, 'launches.jsonl')
  const env = { ...process.env, PYTHONPATH: root, HOME: root, TEST_LAUNCHES: launches }
  const run = Object.assign((...args: string[]) => spawnSync('/usr/bin/python3', ['-c', script, ...args], { env, encoding: 'utf8' }),
    { command: ['/usr/bin/python3', '-c', script], options: { env, encoding: 'utf8' as const } })
  const recorded = () => existsSync(launches) ? readFileSync(launches, 'utf8').trim().split('\n').map(line => JSON.parse(line) as unknown) : []
  return { run, recorded, root }
}

const CHROMIUM = `[Desktop Entry]
Type=Application
Name=Chromium
Exec=chromium %u
StartupWMClass=ChromiumWindow
Actions=new-window;new-private-window;bad id;new-window;no-exec;nameless;undeclared;

[Desktop Action new-window]
Name=New Window
Name[de]=Neues Fenster
Exec=chromium --new-window

[Desktop Action new-private-window]
Name=New Private Window
Exec=chromium --private-window

[Desktop Action no-exec]
Name=No Exec

[Desktop Action nameless]
Exec=chromium

[Desktop Action bad id]
Name=Bad
Exec=chromium
`

const MANY = `[Desktop Entry]
Type=Application
Name=Many
Exec=many
Actions=${Array.from({ length: 20 }, (_, i) => `a${i}`).join(';')}
${Array.from({ length: 20 }, (_, i) => `\n[Desktop Action a${i}]\nName=${'n'.repeat(150)}\nExec=many ${i}\n`).join('')}`

const ENTRIES = {
  'chromium.desktop': CHROMIUM,
  'many.desktop': MANY,
  'portal.desktop': '[Desktop Entry]\nType=Application\nName=Portal\nExec=portal\nDBusActivatable=true\nActions=open;\n\n[Desktop Action open]\nName=Open\n',
  'plain.desktop': '[Desktop Entry]\nType=Application\nName=Plain\nExec=plain\n',
  'hidden.desktop': '[Desktop Entry]\nType=Application\nName=Hidden\nExec=hidden\nNoDisplay=true\nActions=go;\n\n[Desktop Action go]\nName=Go\nExec=hidden --go\n',
}

describe('guest-apps.py', () => {
  it('lists each entry\'s launchable desktop actions, bounded, and leaves hidden entries out', () => {
    const { run } = fixture(ENTRIES)
    const result = run('list', '0')
    expect(result.stderr).toBe('')
    const apps = JSON.parse(result.stdout) as { id: string; actions: { id: string; name: string }[] }[]
    expect(apps.find(app => app.id === 'chromium.desktop')).toHaveProperty('startupWMClass', 'ChromiumWindow')
    expect(apps.find(app => app.id === 'plain.desktop')).toHaveProperty('startupWMClass', null)
    const byId = Object.fromEntries(apps.map(app => [app.id, app.actions]))
    expect(Object.keys(byId).sort()).toEqual(['chromium.desktop', 'many.desktop', 'plain.desktop', 'portal.desktop'])
    expect(byId['chromium.desktop']).toEqual([{ id: 'new-window', name: 'New Window' }, { id: 'new-private-window', name: 'New Private Window' }])
    expect(byId['many.desktop']).toHaveLength(16)
    expect(byId['many.desktop']!.every(action => action.name.length === 100)).toBe(true)
    // A D-Bus activated application's action needs no Exec.
    expect(byId['portal.desktop']).toEqual([{ id: 'open', name: 'Open' }])
    expect(byId['plain.desktop']).toEqual([])
  })

  it('lists an installed entry that a personal copy with a missing TryExec program would shadow', () => {
    const { run } = fixture(ENTRIES, {
      'plain.desktop': '[Desktop Entry]\nType=Application\nName=Stale\nExec=/nonexistent/stale\nTryExec=/nonexistent/stale\n',
      'chromium.desktop': '[Desktop Entry]\nType=Application\nName=Chromium\nExec=chromium\nHidden=true\n',
    })
    const apps = JSON.parse(run('list', '0').stdout) as { id: string; name: string; exec: string }[]
    // The stale copy is absent, so the installed entry shows; a Hidden copy still hides its entry.
    expect(apps.find(app => app.id === 'plain.desktop')).toMatchObject({ name: 'Plain', exec: 'plain' })
    expect(apps.find(app => app.id === 'chromium.desktop')).toBeUndefined()
  })

  it('launches a listed action through GLib, and refuses actions and entries it does not list', () => {
    const { run, recorded } = fixture(ENTRIES)
    expect(run('action', 'chromium.desktop', 'new-private-window').status).toBe(0)
    expect(run('launch', 'chromium.desktop').status).toBe(0)
    expect(recorded()).toEqual([{ launch: 'chromium.desktop', action: 'new-private-window' }, { launch: 'chromium.desktop', files: [] }])
    for (const action of ['no-exec', 'undeclared', 'bad id', 'missing']) {
      const refused = run('action', 'chromium.desktop', action)
      expect(refused.status).not.toBe(0)
      expect(refused.stderr).toContain('Application action not found')
    }
    const hidden = run('action', 'hidden.desktop', 'go')
    expect(hidden.stderr).toContain('Application not found')
    expect(recorded()).toHaveLength(2)
  })
})

describe('app launch requests', () => {
  it('accepts no body or a desktop action id', () => {
    expect(parseAppLaunch({})).toEqual({})
    expect(parseAppLaunch({ action: 'new-private-window' })).toEqual({ action: 'new-private-window' })
    expect(parseAppLaunch({ action: 'A-z-09' })).toEqual({ action: 'A-z-09' })
    for (const action of ['', 'new window', 'a_b', 'a.b', '../x', 'a'.repeat(65), null, 3, ['x']]) {
      expect(() => parseAppLaunch({ action })).toThrow(AgentInputError)
    }
  })

  it('builds the guest command and reports a missing entry or action as not found', async () => {
    expect(guestLaunchArgs('gimp.desktop')).toEqual(['launch', 'gimp.desktop'])
    expect(guestLaunchArgs('gimp.desktop', 'Pictures/a.png')).toEqual(['launch', 'gimp.desktop', 'Pictures/a.png'])
    expect(guestLaunchArgs('chromium.desktop', undefined, 'new-window')).toEqual(['action', 'chromium.desktop', 'new-window'])
    expect(() => guestLaunchArgs('chromium.desktop', 'a.html', 'new-window')).toThrow(AgentInputError)
    const failing = (stderr: string) => async () => { throw new Error(`Guest command failed: ${stderr}`) }
    await expect(guestLaunch(failing('Application action not found'), 'chromium.desktop', undefined, 'x')).rejects.toEqual(new AgentNotFoundError('Application action not found'))
    await expect(guestLaunch(failing('Application not found'), 'gone.desktop')).rejects.toBeInstanceOf(AgentNotFoundError)
    await expect(guestLaunch(failing('Application could not be started'), 'gimp.desktop')).rejects.not.toBeInstanceOf(AgentNotFoundError)
  })
})

describe('desktop shortcuts', () => {
  it('copies a standard installed entry atomically and refuses collisions', () => {
    const f = fixture({ 'chromium.desktop': CHROMIUM })
    expect(f.run('desktop-shortcut', 'chromium.desktop').status).toBe(0)
    const path = join(f.root, 'Desktop', 'chromium.desktop')
    const text = readFileSync(path, 'utf8')
    expect(text).toContain('Exec=chromium %u')
    expect(text).toContain('X-Caboose-AppId=chromium.desktop')
    expect(f.run('desktop-shortcut', 'chromium.desktop').stderr).toContain('already exists')
    expect(readFileSync(path, 'utf8')).toBe(text)
    expect(f.recorded()).toEqual([])
  })
  it('rejects unknown IDs, traversal, hidden entries and a symlink Desktop', () => {
    const f = fixture({ 'chromium.desktop': CHROMIUM, 'hidden.desktop': CHROMIUM.replace('Type=Application', 'Type=Application\nHidden=true') })
    expect(f.run('desktop-shortcut', '../chromium.desktop').status).not.toBe(0)
    expect(f.run('desktop-shortcut', 'missing.desktop').stderr).toContain('Application not found')
    expect(f.run('desktop-shortcut', 'hidden.desktop').stderr).toContain('Application not found')
    const outside = join(f.root, 'elsewhere')
    mkdirSync(outside)
    symlinkSync(outside, join(f.root, 'Desktop'))
    expect(f.run('desktop-shortcut', 'chromium.desktop').status).not.toBe(0)
    expect(existsSync(join(outside, 'chromium.desktop'))).toBe(false)
  })
  it('bounds copied content and refuses destination symlinks', () => {
    const f = fixture({ 'big.desktop': CHROMIUM + '#'.repeat(262144), 'chromium.desktop': CHROMIUM })
    expect(f.run('desktop-shortcut', 'big.desktop').stderr).toContain('too large')
    mkdirSync(join(f.root, 'Desktop'))
    const target = join(f.root, 'keep')
    writeFileSync(target, 'keep')
    symlinkSync(target, join(f.root, 'Desktop', 'chromium.desktop'))
    expect(f.run('desktop-shortcut', 'chromium.desktop').status).not.toBe(0)
    expect(readFileSync(target, 'utf8')).toBe('keep')
  })
})
