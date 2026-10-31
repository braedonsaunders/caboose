import { expect, it } from 'vitest'
import { openPortableStorage } from './config.js'
it('preserves disabled local defaults and rejects invalid explicit configuration', async () => {
  expect(await openPortableStorage({}, 'container', 'darwin')).toBeUndefined()
  expect(await openPortableStorage({ CABOOSE_PORTABLE_STORAGE: 'off' }, 'microvm', 'linux')).toBeUndefined()
  await expect(openPortableStorage({ CABOOSE_PORTABLE_STORAGE: 'yes' }, 'microvm', 'linux')).rejects.toThrow('on or off')
  await expect(openPortableStorage({ CABOOSE_PORTABLE_STORAGE: 'on' }, 'container', 'linux')).rejects.toThrow('microVM')
  await expect(openPortableStorage({ CABOOSE_PORTABLE_STORAGE: 'on' }, 'microvm', 'linux')).rejects.toThrow('absolute path')
})
