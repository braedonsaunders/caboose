export class AuthInputError extends Error {
  constructor(message: string, readonly status: 400 | 413) { super(message) }
}

/** Bound wrapper input before parsing; do not include request contents in errors. */
export async function readAuthObject(request: Request, limit = 64 * 1024): Promise<Record<string, unknown>> {
  if (!request.body) return {}
  const reader = request.body.getReader()
  const chunks: Uint8Array[] = []
  let size = 0
  try {
    for (;;) {
      const { value, done } = await reader.read()
      if (done) break
      size += value.byteLength
      if (size > limit) {
        void reader.cancel().catch(() => {})
        throw new AuthInputError('Request body too large', 413)
      }
      chunks.push(value)
    }
    if (!size) return {}
    const value: unknown = JSON.parse(Buffer.concat(chunks).toString('utf8'))
    if (value && typeof value === 'object' && !Array.isArray(value)) return value as Record<string, unknown>
    throw new AuthInputError('Request body must be a JSON object', 400)
  } catch (error) {
    if (error instanceof AuthInputError) throw error
    throw new AuthInputError('Request body must be a JSON object', 400)
  } finally { reader.releaseLock() }
}
