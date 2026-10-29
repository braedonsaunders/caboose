import { expect, it, vi } from 'vitest'
import { ownerScopeCommand } from './owner-scope.js'

it('routes only standard owner invocations through the scope, preserving arguments', async () => {
  const probe = vi.fn(async () => true)
  expect(await ownerScopeCommand('/usr/sbin/runuser', ['-u', 'caboose', '--', '/bin/echo', 'a b'], probe)).toEqual({ command: '/usr/local/libexec/caboose-owner-run', args: ['/bin/echo', 'a b'] })
  expect(await ownerScopeCommand('/usr/sbin/runuser', ['-u', 'root', '--', '/bin/echo'], probe)).toEqual({ command: '/usr/sbin/runuser', args: ['-u', 'root', '--', '/bin/echo'] })
  expect(probe).toHaveBeenCalledTimes(1)
})

it('keeps legacy guest commands unchanged when the wrapper is absent', async () => {
  const args = ['-u', 'caboose', '--', '/bin/echo']
  expect(await ownerScopeCommand('/usr/sbin/runuser', args, async () => false)).toEqual({ command: '/usr/sbin/runuser', args })
})
