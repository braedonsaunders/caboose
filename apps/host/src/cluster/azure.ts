import type { FenceProvider, FenceReceipt, Host } from './coordinator.js'

const resourcePattern = /^\/subscriptions\/[0-9a-f-]{36}\/resourceGroups\/[A-Za-z0-9_.()-]+\/providers\/Microsoft\.Compute\/virtualMachines\/[A-Za-z0-9_.-]+$/i
export function azureResource(value: string): string {
  if (!resourcePattern.test(value)) throw new Error('Cluster fencing requires an Azure VM resource ID')
  return value.toLowerCase()
}
/** Uses the host VM's managed identity; no cloud keys or CLI login state. */
export class AzureFence implements FenceProvider {
  constructor(private readonly request: typeof fetch = fetch) {}
  async fence(host: Host): Promise<FenceReceipt> {
    const resource = azureResource(host.resource)
    const tokenResponse = await this.request('http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fmanagement.azure.com%2F', { headers: { Metadata: 'true' }, signal: AbortSignal.timeout(10_000), redirect: 'error' })
    if (!tokenResponse.ok) throw new Error('Azure managed identity unavailable')
    const token = await tokenResponse.json() as { access_token?: string }
    if (!token.access_token) throw new Error('Azure managed identity returned no token')
    const headers = { Authorization: `Bearer ${token.access_token}` }
    const base = `https://management.azure.com${resource}`
    const response = await this.request(`${base}/deallocate?api-version=2024-03-01`, { method: 'POST', headers, signal: AbortSignal.timeout(30_000), redirect: 'error' })
    if (!response.ok) throw new Error(`Azure deallocation refused (${response.status})`)
    // Acceptance/202 is never proof. Query provider state independently, bounded to five minutes.
    const deadline = Date.now() + 300_000
    while (Date.now() < deadline) {
      const view = await this.request(`${base}/instanceView?api-version=2024-03-01`, { headers, signal: AbortSignal.timeout(10_000), redirect: 'error' })
      if (!view.ok) throw new Error(`Azure fence verification failed (${view.status})`)
      const state = await view.json() as { statuses?: { code?: string }[] }
      if (state.statuses?.some(s => s.code === 'PowerState/deallocated')) return { provider: 'azure', resource: host.resource, hostId: host.id, verifiedAt: new Date().toISOString(), state: 'PowerState/deallocated' }
      await new Promise(resolve => setTimeout(resolve, 2000))
    }
    throw new Error('Azure did not confirm deallocation; takeover refused')
  }
}
