import { buildTransport, sendVia, type EmailTransport } from '@braedonsaunders/appkit-emails'
import type { AuthEmailSender } from '@braedonsaunders/appkit-auth'

/** Host infrastructure transport for global administrator identities. */
export function accountEmail(env: NodeJS.ProcessEnv = process.env): AuthEmailSender | undefined {
  if (!env.CABOOSE_EMAIL_PROVIDER) return undefined
  const transport: EmailTransport | null = buildTransport({
    provider: env.CABOOSE_EMAIL_PROVIDER as Parameters<typeof buildTransport>[0]['provider'],
    fromEmail: env.CABOOSE_EMAIL_FROM, fromName: 'Caboose', secret: env.CABOOSE_EMAIL_SECRET,
    smtpHost: env.CABOOSE_SMTP_HOST, smtpPort: env.CABOOSE_SMTP_PORT ? Number(env.CABOOSE_SMTP_PORT) : undefined,
    smtpSecure: env.CABOOSE_SMTP_SECURE === 'true', smtpUsername: env.CABOOSE_SMTP_USERNAME,
    mailgunDomain: env.CABOOSE_MAILGUN_DOMAIN, mailgunRegion: env.CABOOSE_MAILGUN_REGION === 'eu' ? 'eu' : 'us',
  })
  if (!transport) throw new Error('Administrator email transport configuration is invalid')
  return async message => {
    try { await sendVia(transport, message) }
    catch { throw new Error('Administrator recovery email delivery failed') }
  }
}
