/** APNs transport, independent of Caboose's event and device models. */
import { createPrivateKey, sign, type KeyObject } from 'node:crypto'
import { connect, constants } from 'node:http2'
import { readFile } from 'node:fs/promises'

export type APNsEnvironment = 'sandbox' | 'production'
export interface APNsConfig { key: KeyObject; keyId: string; teamId: string; topic: string }
export interface APNsMessage { token: string; environment: APNsEnvironment; payload: object; topic?: string; pushType?: 'alert' | 'liveactivity'; collapseId?: string }
export interface APNsResult { status: number; reason?: string }

/** Apple's provider tokens expire after one hour. Refresh at 50 minutes. */
export class ProviderToken {
  private cached?: { value: string; issued: number }
  constructor(private config: APNsConfig, private now: () => number = Date.now) {}
  get(): string {
    const issued = Math.floor(this.now() / 1000)
    if (this.cached && issued >= this.cached.issued && issued - this.cached.issued < 3000) return this.cached.value
    const encode = (value: object) => Buffer.from(JSON.stringify(value)).toString('base64url')
    const input = `${encode({ alg: 'ES256', kid: this.config.keyId })}.${encode({ iss: this.config.teamId, iat: issued })}`
    const signature = sign('sha256', Buffer.from(input), { key: this.config.key, dsaEncoding: 'ieee-p1363' }).toString('base64url')
    const value = `${input}.${signature}`
    this.cached = { value, issued }
    return value
  }
}

/** Fail startup on partial or invalid configuration instead of silently disabling push. */
export async function apnsFromEnvironment(env: NodeJS.ProcessEnv): Promise<APNsConfig | undefined> {
  const values = [env.CABOOSE_APNS_KEY_PATH, env.CABOOSE_APNS_KEY_ID, env.CABOOSE_APNS_TEAM_ID, env.CABOOSE_APNS_TOPIC]
  if (values.every(value => !value)) return undefined
  if (values.some(value => !value)) throw new Error('All CABOOSE_APNS_KEY_PATH, CABOOSE_APNS_KEY_ID, CABOOSE_APNS_TEAM_ID and CABOOSE_APNS_TOPIC are required')
  const key = createPrivateKey(await readFile(values[0]!))
  if (key.asymmetricKeyType !== 'ec' || key.asymmetricKeyDetails?.namedCurve !== 'prime256v1') throw new Error('APNs key must be a P-256 private key')
  return { key, keyId: values[1]!, teamId: values[2]!, topic: values[3]! }
}

/** One bounded HTTP/2 connection per request; no token or private key is logged. */
export class APNsSender {
  private token: ProviderToken
  constructor(private config: APNsConfig) { this.token = new ProviderToken(config) }
  send(message: APNsMessage): Promise<APNsResult> {
    return new Promise((resolve, reject) => {
      const client = connect(message.environment === 'sandbox' ? 'https://api.sandbox.push.apple.com' : 'https://api.push.apple.com')
      let settled = false
      const finish = (error?: Error, result?: APNsResult) => {
        if (settled) return
        settled = true
        clearTimeout(timer)
        client.destroy()
        if (error) reject(error); else resolve(result!)
      }
      const timer = setTimeout(() => finish(new Error('APNs request timed out')), 15_000)
      client.on('error', error => finish(error))
      const headers: Record<string, string> = {
        [constants.HTTP2_HEADER_METHOD]: 'POST', [constants.HTTP2_HEADER_PATH]: `/3/device/${message.token}`,
        authorization: `bearer ${this.token.get()}`, 'apns-topic': message.topic ?? this.config.topic,
        'apns-push-type': message.pushType ?? 'alert', 'content-type': 'application/json',
      }
      if (message.collapseId) headers['apns-collapse-id'] = message.collapseId
      const request = client.request(headers)
      let status = 0, body = ''
      request.setEncoding('utf8')
      request.on('response', headers => { status = Number(headers[':status']) })
      request.on('data', chunk => { body += chunk })
      request.on('error', error => finish(error))
      request.on('end', () => {
        let reason: string | undefined
        try { reason = (JSON.parse(body) as { reason?: string }).reason } catch {}
        finish(undefined, { status, ...(reason ? { reason } : {}) })
      })
      request.end(JSON.stringify(message.payload))
    })
  }
}
