import { expect, it, vi } from 'vitest'
import { AgentInputError, AgentNotFoundError, AgentUnavailableError } from './agents.js'
import { DesktopNotifications, parseDesktopNotification, parseNotificationResponse, respondToNotification } from './desktop-notifications.js'
import { desktopNotificationFor } from './push.js'
const id = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
const item = { id, app: 'Editor', summary: 'Saved', body: 'Done', created: 1000 }
const plain = { ...item, desktopEntry: null, actions: [], defaultAction: false, reply: null }
const actionable = { ...item, desktopEntry: 'org.signal.Signal', actions: [{ key: 'read', label: 'Mark as Read' }], defaultAction: true, reply: { label: 'Reply', placeholder: 'Message Ada' } }
it('validates untrusted desktop records and ignores stale or future entries', () => {
  expect(parseDesktopNotification(JSON.stringify(item), 1_000_000)).toEqual(plain)
  expect(parseDesktopNotification(JSON.stringify(item), 1_121_000)).toBeUndefined()
  expect(parseDesktopNotification(JSON.stringify({ ...item, id: '../bad' }), 1_000_000)).toBeUndefined()
  expect(parseDesktopNotification(JSON.stringify({ ...item, id: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaa-' }), 1_000_000)).toBeUndefined()
  expect(parseDesktopNotification('{', 1_000_000)).toBeUndefined()
})
it('keeps actions, the default action, an inline reply and the desktop entry, and discards malformed ones', () => {
  expect(parseDesktopNotification(JSON.stringify(actionable), 1_000_000)).toEqual(actionable)
  expect(parseDesktopNotification(JSON.stringify({ ...plain, actions: [{ key: '0', label: '✓ Done 🎉' }] }), 1_000_000)?.actions).toEqual([{ key: '0', label: '✓ Done 🎉' }])
  for (const change of [
    { desktopEntry: '../evil' }, { desktopEntry: 'a'.repeat(256) }, { desktopEntry: 7 },
    { actions: [{ key: 'default', label: 'Open' }] }, { actions: [{ key: 'inline-reply', label: 'Reply' }] },
    { actions: [{ key: 'a', label: 'A' }, { key: 'a', label: 'Again' }] }, { actions: [{ key: '', label: 'Empty' }] },
    { actions: [{ key: 'a\nb', label: 'Control' }] }, { actions: [{ key: 'a', label: '' }] }, { actions: [{ key: 'a', label: 'x'.repeat(65) }] },
    { actions: Array.from({ length: 5 }, (_, n) => ({ key: String(n), label: 'N' })) }, { actions: {} }, { actions: [null] },
    { defaultAction: 'yes' }, { reply: { label: 'Reply' } }, { reply: { label: 'Reply', placeholder: 'x'.repeat(101) } }, { reply: 'Reply' },
  ]) expect(parseDesktopNotification(JSON.stringify({ ...actionable, ...change }), 1_000_000), JSON.stringify(change)).toBeUndefined()
})
it('pushes the record id, desktop entry and default action, with a reply category only when the application accepts replies', () => {
  expect(desktopNotificationFor(plain)).toEqual({ kind: 'desktop', collapseId: `desktop-${id}`, payload: {
    aps: { alert: { title: 'Saved', body: 'Done' }, 'thread-id': 'desktop-Editor', sound: 'default' }, notificationId: id } })
  expect(desktopNotificationFor(actionable).payload).toEqual({
    aps: { alert: { title: 'Saved', body: 'Done' }, 'thread-id': 'desktop-Editor', sound: 'default', category: 'DESKTOP_REPLY' },
    notificationId: id, desktopEntry: 'org.signal.Signal', defaultAction: true })
})
it('accepts exactly one action key or bounded reply text', () => {
  expect(parseNotificationResponse({ action: 'default' })).toEqual({ action: 'default' })
  expect(parseNotificationResponse({ reply: 'On my way\n🚲' })).toEqual({ reply: 'On my way\n🚲' })
  expect(parseNotificationResponse({ reply: '😀'.repeat(2000) })).toEqual({ reply: '😀'.repeat(2000) })
  for (const body of [{}, { action: 'a', reply: 'b' }, { action: '' }, { action: 'a'.repeat(65) }, { action: 'a\tb' }, { action: 7 },
    { reply: '' }, { reply: 'x'.repeat(2001) }, { reply: 'a\u0000b' }, { reply: '\ud800' }, { reply: 3 }, { other: 'x' }]) {
    expect(() => parseNotificationResponse(body), JSON.stringify(body)).toThrow(AgentInputError)
  }
})
it('answers through caboose-notify as caboose, with argument vectors and the endpoint\'s result', async () => {
  const run = vi.fn(async (_command: string, _args: string[]) => '{"result": "responded"}\n')
  expect(await respondToNotification({ run }, id, { reply: '--help; rm -rf ~' })).toEqual({ responded: true })
  expect(run).toHaveBeenCalledWith('/usr/sbin/runuser', ['-u', 'caboose', '--', '/usr/bin/env', 'HOME=/home/caboose',
    'DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus', '/usr/bin/python3', '/opt/caboose/notifications/caboose-notify', 'respond', id, '--reply=--help; rm -rf ~'], 20_000)
  await respondToNotification({ run }, id, { action: 'default' })
  expect(run.mock.calls.at(-1)?.[1].at(-1)).toBe('--action=default')
  run.mockResolvedValueOnce('{"result": "unknown-notification"}\n')
  await expect(respondToNotification({ run }, id, { action: 'default' })).rejects.toThrow(new AgentNotFoundError('The notification is no longer on the computer'))
  run.mockResolvedValueOnce('{"result": "unknown-action"}\n')
  await expect(respondToNotification({ run }, id, { action: 'x' })).rejects.toThrow(AgentNotFoundError)
  run.mockResolvedValueOnce('surprise')
  await expect(respondToNotification({ run }, id, { action: 'x' })).rejects.toThrow('unexpected answer')
  await expect(respondToNotification({ run }, '../x', { action: 'x' })).rejects.toThrow(AgentInputError)
  await expect(respondToNotification(undefined, id, { action: 'x' })).rejects.toThrow(AgentUnavailableError)
})
it('drains the owner queue through the guest and ignores malformed records', async () => {
  const notify = { ...actionable, created: Math.floor(Date.now() / 1000) }
  const emit = vi.fn()
  const run = vi.fn(async () => JSON.stringify(notify) + '\nnot json\n')
  const monitor = new DesktopNotifications(() => ({ run }), emit)
  await monitor.poll()
  expect(run).toHaveBeenCalledOnce()
  expect(emit).toHaveBeenCalledWith(notify)
})
it('waits for an in-flight queue drain before pausing the guest', async () => {
  let finish!: (value: string) => void
  const monitor = new DesktopNotifications(() => ({ run: () => new Promise<string>(resolve => { finish = resolve }) }), () => {})
  const polling = monitor.poll()
  const done = vi.fn()
  const quiesced = monitor.quiesce().then(done)
  await Promise.resolve()
  expect(done).not.toHaveBeenCalled()
  finish('')
  await polling
  await quiesced
  expect(done).toHaveBeenCalledOnce()
})
