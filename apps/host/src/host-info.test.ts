import { expect, it } from 'vitest'
import { config } from './config.js'
import { describeHost } from './host-info.js'

it('describes a microVM host with defaults marked, and never shows the owner token', () => {
  const env = { CABOOSE_OWNER_TOKEN: 'very-secret', CABOOSE_IMAGE_ROOT: '/srv/caboose' }
  const info = describeHost(config(env), env, { push: true, liveActivities: true })
  expect(info).toMatchObject({ runtime: 'microvm', gpu: null, image: 'Debian 13 golden image (/srv/caboose/base.raw)', push: true, liveActivities: true })
  expect(info.version).toMatch(/^\d+\.\d+\.\d+/)
  expect(info.settings.find(setting => setting.name === 'CABOOSE_IMAGE_ROOT')).toEqual({ name: 'CABOOSE_IMAGE_ROOT', value: '/srv/caboose', default: false })
  // Container-only settings are not shown for a microVM.
  expect(info.settings.some(setting => setting.name === 'CABOOSE_GPU')).toBe(false)
  expect(JSON.stringify(info)).not.toContain('very-secret')
})

it('reports the GPU a container is given, detected unless set, and hides credentials in a registry URL', () => {
  const env = { CABOOSE_OWNER_TOKEN: 't', CABOOSE_RUNTIME: 'container', CABOOSE_AGENT_REGISTRY_URL: 'https://user:pass@mirror.example.com/registry.json', CABOOSE_CONTAINER_ARGS: '-e API_KEY=hidden' }
  const info = describeHost(config(env), env, { push: false, liveActivities: false, exists: path => path === '/dev/dxg' })
  expect(info).toMatchObject({ runtime: 'container', gpu: 'wsl', image: 'caboose-computer:latest' })
  expect(info.settings.find(setting => setting.name === 'CABOOSE_GPU')).toEqual({ name: 'CABOOSE_GPU', value: 'auto', default: true })
  expect(info.settings.find(setting => setting.name === 'CABOOSE_AGENT_REGISTRY_URL')?.value).toBe('https://mirror.example.com/registry.json')
  expect(JSON.stringify(info)).not.toContain('pass')
  expect(JSON.stringify(info)).not.toContain('hidden')
  const fixed = { ...env, CABOOSE_GPU: 'nvidia' }
  expect(describeHost(config(fixed), fixed, { push: false, liveActivities: false, exists: () => true }).gpu).toBe('nvidia')
})
