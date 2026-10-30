import { describe, expect, it, vi } from 'vitest'
import { AgentTasks } from './agents.js'
import { PhoneHandoff } from './phone.js'
import { DesktopNotifications } from './desktop-notifications.js'

const id = '12345678-1234-1234-1234-123456789abc'
function tasks() {
  const emitted: unknown[] = []
  const eventsChanged = vi.fn()
  const tasks = new AgentTasks(() => ({ run: vi.fn() }), e => emitted.push(e), () => () => {}, { resolver: {} as never, eventsChanged })
  const entry = { task: { id, status: 'running', turns: 1 }, offset: 0, carry: Buffer.alloc(0), turn: 1, pending: [], queue: [], journal: {} }
  ;(tasks as any).tracked.set(id, entry)
  return { tasks, entry, emitted, eventsChanged }
}
function tick(text: string, offset = 0) {
  return { id, offset, nextOffset: offset + Buffer.byteLength(text), chunk: 65536, output: `T\t${id}\t\t\t${Buffer.from(text).toString('base64')}\n` }
}

describe('event adapters', () => {
  it('consumes transcript offsets once, rejects arbitrary tasks, and resets truncated carry', async () => {
    const { tasks: agent, entry, emitted } = tasks()
    const frame = tick('{"type":"text","text":"hello"}\n')
    await agent.acceptTick({ ...frame, id: '../owner' })
    expect(entry.offset).toBe(0)
    await agent.acceptTick(frame)
    const count = emitted.length
    expect(count).toBeGreaterThan(0)
    await agent.acceptTick(frame)
    expect(emitted).toHaveLength(count)
    entry.carry = Buffer.from('partial old line')
    await agent.acceptTick({ ...tick('{"type":"text","text":"reset"}\n'), reset: true })
    expect(entry.carry.length).toBe(0)
    expect(emitted.length).toBeGreaterThan(count)
    entry.task.status = 'succeeded'
    expect(agent.eventTasks()).toEqual([])
  })

  it('bounds unterminated transcript lines and resumes at the next newline', async () => {
    const { tasks: agent, entry, emitted } = tasks()
    for (let i = 0; i < 40; i++) await agent.acceptTick(tick('x'.repeat(65536), entry.offset))
    expect(entry.carry.length).toBeLessThanOrEqual(2097152)
    await agent.acceptTick(tick('\n{"type":"text","text":"after"}\n', entry.offset))
    expect(emitted.some((e: any) => e.text === 'after')).toBe(true)
  })

  it('does not start idle exec loops and keeps phone and notification validators', async () => {
    vi.useFakeTimers()
    try {
      const run = vi.fn(), emit = vi.fn()
      const phone = new PhoneHandoff(() => ({ run }), emit)
      const notifications = new DesktopNotifications(() => ({ run }), emit)
      phone.setActive(true); notifications.setActive(true)
      await vi.advanceTimersByTimeAsync(60000)
      expect(run).not.toHaveBeenCalled()
      phone.accept({ type: 'phone.open', url: 'file:///etc/passwd' })
      notifications.accept({ id: '../escape' })
      expect(emit).not.toHaveBeenCalled()
      phone.accept({ type: 'phone.open', url: 'https://example.com' })
      expect(emit).toHaveBeenCalledOnce()
      phone.setActive(false); notifications.setActive(false)
    } finally { vi.useRealTimers() }
  })
})
