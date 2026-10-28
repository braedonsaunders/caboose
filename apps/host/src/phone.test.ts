import { describe, expect, it, vi } from 'vitest'
import { parsePhoneEvent, PhoneHandoff, readPhoneFile } from './phone.js'
const id = 'a'.repeat(32)
const file = { type: 'phone.share', id, path: `/home/caboose/.cache/caboose/phone/files/${id}`, name: 'photo.png', size: 3, contentType: 'image/png' }

describe('phone handoff', () => {
  it('accepts only supported URLs and bounded staged files', () => {
    expect(parsePhoneEvent({ type: 'phone.open', url: 'mailto:person@example.com' })).toEqual({ type: 'phone.open', url: 'mailto:person@example.com' })
    for (const url of ['file:///etc/passwd', 'javascript:alert(1)', 'tel:12\n3']) expect(parsePhoneEvent({ type: 'phone.open', url })).toBeNull()
    expect(parsePhoneEvent(file)).toEqual(file)
    expect(parsePhoneEvent({ ...file, path: '/etc/passwd' })).toBeNull()
    expect(parsePhoneEvent({ ...file, name: '../secret' })).toBeNull()
    expect(parsePhoneEvent({ ...file, size: 10485761 })).toBeNull()
    expect(parsePhoneEvent({ ...file, type: 'phone.print' })).toBeNull()
  })
  it('relays only validated events and does not poll without a guest', async () => {
    const emit = vi.fn()
    const run = vi.fn().mockResolvedValue(JSON.stringify([file, { ...file, id: 'bad' }]))
    const handoff = new PhoneHandoff(() => ({ run }), emit)
    await handoff.poll()
    expect(emit).toHaveBeenCalledExactlyOnceWith(file)
    await new PhoneHandoff(() => undefined, emit).poll()
    expect(run).toHaveBeenCalledOnce()
  })
  it('downloads bounded chunks and rejects invalid IDs and truncated content', async () => {
    const run = vi.fn().mockImplementation(async (_cmd: string, args: string[]) => args.includes('info') ? '3' : 'YWJj')
    expect(await readPhoneFile({ run }, id)).toEqual({ data: 'YWJj' })
    await expect(readPhoneFile({ run }, '../bad')).rejects.toThrow()
    run.mockImplementation(async (_cmd: string, args: string[]) => args.includes('info') ? '4' : 'YWJj')
    await expect(readPhoneFile({ run }, id)).rejects.toThrow('changed')
  })
})
