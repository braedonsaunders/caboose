import type { FileService } from './fs-proxy.js'

type Fetcher = (url: string, init?: RequestInit) => Promise<Response>

/**
 * Writes a file under the computer's home through its file service, so its contents never
 * pass through a command line. The service writes privately (0600) and replaces a file only
 * with the version it has, so each write states it: creating only if absent, else replacing
 * exactly the version just seen, and trying again when the file changed in between.
 */
export async function replaceGuestFile(service: FileService, relative: string, data: Buffer, fetcher: Fetcher = fetch): Promise<void> {
  const path = encodeURIComponent(relative)
  const authorization = `Bearer ${service.token}`
  for (let attempt = 0; attempt < 4; attempt++) {
    const stat = await fetcher(`${service.url}/stat?path=${path}`, { headers: { authorization }, signal: AbortSignal.timeout(15_000) })
    let condition: Record<string, string>
    if (stat.status === 404) condition = { 'if-none-match': '*' }
    else if (stat.ok) {
      const etag = (await stat.json() as { etag?: unknown }).etag
      if (typeof etag !== 'string' || !etag || etag.length > 200) throw new Error('The computer reported no version for the file')
      condition = { 'if-match': etag }
    } else throw new Error(`The computer could not check the file (${stat.status})`)
    const put = await fetcher(`${service.url}/content?path=${path}`, {
      method: 'PUT', body: new Uint8Array(data), signal: AbortSignal.timeout(15_000),
      headers: { authorization, 'content-length': String(data.length), ...condition },
    })
    if (put.ok) return
    if (put.status !== 412) throw new Error(`The computer did not take the file (${put.status})`)
  }
  throw new Error('The file kept changing on the computer; try again')
}
