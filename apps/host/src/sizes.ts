import { SettingsInputError } from './settings.js'

/** Presets describe CPU and memory; GPU access is a property of the host runtime. */
export function computerSizes(gpuEnabled: boolean) {
  return [
    { id: 'micro', name: 'Micro', memoryMb: 2048, vcpus: 2, available: true },
    { id: 'standard', name: 'Standard', memoryMb: 4096, vcpus: 4, available: true },
    { id: 'gpu', name: 'GPU', memoryMb: 8192, vcpus: 8, available: gpuEnabled },
  ]
}

/** Expand a preset at the API boundary; custom resource fields remain supported. */
export function expandSize(input: Record<string, unknown>, gpuEnabled: boolean): Record<string, unknown> {
  if (!('size' in input)) return input
  if ('memoryMb' in input || 'vcpus' in input) throw new SettingsInputError('size cannot be combined with memoryMb or vcpus')
  const size = computerSizes(gpuEnabled).find(entry => entry.id === input.size)
  if (!size) throw new SettingsInputError('Unknown computer size')
  if (!size.available) throw new SettingsInputError('GPU size requires a container host with GPU access enabled')
  const { size: _size, ...rest } = input
  return { ...rest, memoryMb: size.memoryMb, vcpus: size.vcpus }
}
