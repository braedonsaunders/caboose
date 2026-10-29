/** Account cookies only: owner and phone bearer tokens never enter these requests. */
export async function securityRequest<T = Record<string, unknown>>(path: string, body?: unknown): Promise<T> {
  const response = await fetch(`/v1/auth/${path}`, {
    method: body === undefined ? 'GET' : 'POST', credentials: 'same-origin',
    headers: body === undefined ? undefined : { 'content-type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  const result = await response.json()
  if (!response.ok) throw new Error(result.message ?? result.error ?? 'Account security request failed')
  return result as T
}
