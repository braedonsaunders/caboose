import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { expect, it } from 'vitest'

it('checks the guest terminal service\'s requests, replay, modes, titles and environment', () => {
  const script = fileURLToPath(new URL('../../../guest/terminal/test_logic.py', import.meta.url))
  expect(() => execFileSync('python3', [script], { env: { ...process.env, PYTHONDONTWRITEBYTECODE: '1' }, stdio: 'pipe' })).not.toThrow()
})
