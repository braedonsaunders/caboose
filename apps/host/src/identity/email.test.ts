import { expect, it, vi } from 'vitest'
const send = vi.hoisted(() => vi.fn())
vi.mock('@braedonsaunders/appkit-emails', async importOriginal => {
  const actual = await importOriginal<typeof import('@braedonsaunders/appkit-emails')>()
  return { ...actual, sendVia: send }
})
import { accountEmail } from './email.js'

it('requires a complete real transport and propagates delivery failures without credentials', async () => {
  expect(accountEmail({})).toBeUndefined()
  expect(() => accountEmail({ CABOOSE_EMAIL_PROVIDER: 'smtp' })).toThrow(/invalid/)
  const sender = accountEmail({ CABOOSE_EMAIL_PROVIDER: 'smtp', CABOOSE_EMAIL_FROM: 'accounts@example.test', CABOOSE_SMTP_HOST: 'smtp.example.test', CABOOSE_SMTP_USERNAME: 'sender', CABOOSE_EMAIL_SECRET: 'private-password' })!
  const mail = { kind: 'password-reset' as const, to: 'admin@example.test', subject: 'Reset', text: 'Reset link', html: '<p>Reset link</p>' }
  send.mockRejectedValueOnce(new Error('SMTP rejected private-password'))
  await expect(sender(mail)).rejects.toThrow('Administrator recovery email delivery failed')
  send.mockResolvedValueOnce({ id: 'accepted-by-provider' })
  await expect(sender(mail)).resolves.toBeUndefined()
  expect(send).toHaveBeenLastCalledWith(expect.objectContaining({ provider: 'smtp', host: 'smtp.example.test' }), mail)
})
