import { expect, it } from 'vitest'
import { modelId, publicModels } from './agent-models.js'

it('validates guest-advertised choices without manufacturing model ids', () => {
  expect(publicModels({ currentModelId: 'custom/id', configId: 'secret-internal', availableModels: [{ id: 'custom/id', name: 'Custom' }] })).toEqual({ currentModelId: 'custom/id', availableModels: [{ id: 'custom/id', name: 'Custom' }] })
  expect(publicModels({ currentModelId: 'x', availableModels: [{ id: 'x', name: 'X' }, { id: 'x', name: 'Duplicate' }] })).toBeUndefined()
  expect(publicModels({ currentModelId: 'x', availableModels: [{ id: '../safe-model-id', name: null }] })).toBeUndefined()
  expect(publicModels(undefined)).toBeUndefined()
  expect(() => modelId('bad\u0000id')).toThrow('model must')
})
