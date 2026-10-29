/** Routes using the owner seat must also work after a headless microVM wake. */
export function needsOwnerDisplay(method: string | undefined, path: string): boolean {
  return (method === 'POST' && (path === '/v1/open' || /^\/v1\/apps\/[^/]+\/launch$/.test(path)
    || /^\/v1\/agents\/[^/]+\/sign-in$/.test(path)))
    || (method === 'GET' && path === '/v1/screen/elements')
    || (method === 'POST' && ['/v1/screen/act', '/v1/screen/type', '/v1/screen/keys'].includes(path))
}
