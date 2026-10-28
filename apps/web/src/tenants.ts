import type { Quotas } from './api.js'

/** Quotas as typed in the console: whole numbers as text, memory in GiB, empty for no limit. */
export interface QuotaDraft { memoryGb: string; vcpus: string; diskGb: string }

export function quotaDraft(quotas: Quotas | null): QuotaDraft {
  return {
    memoryGb: quotas?.memoryMb ? String(quotas.memoryMb / 1024) : '',
    vcpus: quotas?.vcpus ? String(quotas.vcpus) : '',
    diskGb: quotas?.diskGb ? String(quotas.diskGb) : '',
  }
}

export function quotasFromDraft(draft: QuotaDraft): { ok: true; quotas: Quotas } | { ok: false; error: string } {
  const read = (text: string, label: string, max: number): number | null | string => {
    const value = text.trim()
    if (!value) return null
    if (!/^\d+$/.test(value)) return `${label} must be a whole number, or empty for no limit.`
    const number = Number(value)
    if (number < 1 || number > max) return `${label} must be from 1 to ${max}.`
    return number
  }
  const memory = read(draft.memoryGb, 'Memory', 1024)
  const vcpus = read(draft.vcpus, 'vCPUs', 1024)
  const disk = read(draft.diskGb, 'Disk', 1_000_000)
  for (const value of [memory, vcpus, disk]) if (typeof value === 'string') return { ok: false, error: value }
  return { ok: true, quotas: { memoryMb: memory === null ? null : (memory as number) * 1024, vcpus: vcpus as number | null, diskGb: disk as number | null } }
}
