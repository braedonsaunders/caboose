import { expect, it, vi } from 'vitest'
import { DesktopNotifications, parseDesktopNotification } from './desktop-notifications.js'
const item = { id: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', app: 'Editor', summary: 'Saved', body: 'Done', created: 1000 }
it('validates untrusted desktop records and ignores stale or future entries', () => {
  expect(parseDesktopNotification(JSON.stringify(item), 1_000_000)).toEqual(item)
  expect(parseDesktopNotification(JSON.stringify(item), 1_121_000)).toBeUndefined()
  expect(parseDesktopNotification(JSON.stringify({ ...item, id: '../bad' }), 1_000_000)).toBeUndefined()
  expect(parseDesktopNotification('{', 1_000_000)).toBeUndefined()
})
it('drains the owner queue through the guest and ignores malformed records', async () => {
  const notify = { ...item, created: Math.floor(Date.now() / 1000) }
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
