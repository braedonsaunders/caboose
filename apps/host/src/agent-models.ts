import { AgentInputError } from './agents.js'

export interface AgentModels {
  currentModelId: string
  availableModels: Array<{ id: string; name: string; description?: string }>
}
export function modelId(value: unknown): string | undefined {
  if (value === undefined) return undefined
  if (typeof value !== 'string' || !value.length || value.length > 512 || /[\u0000-\u001f\u007f]/.test(value)) throw new AgentInputError('model must be an advertised model id (1–512 characters)')
  return value
}
/** Validate untrusted guest state; configId stays inside the runner. */
export function publicModels(value: unknown): AgentModels | undefined {
  const v = value as any
  if (!v || typeof v.currentModelId !== 'string' || !Array.isArray(v.availableModels) || v.availableModels.length > 500) return undefined
  try {
    const currentModelId = modelId(v.currentModelId)!
    const availableModels = v.availableModels.map((item: any) => {
      const id = modelId(item?.id)
      if (!id || typeof item.name !== 'string' || !item.name.length || item.name.length > 500) throw new Error('Invalid model')
      return { id, name: item.name, ...(typeof item.description === 'string' ? { description: item.description.slice(0, 2000) } : {}) }
    })
    if (!availableModels.length || new Set(availableModels.map((m: { id: string }) => m.id)).size !== availableModels.length) return undefined
    return { currentModelId, availableModels }
  } catch { return undefined }
}
