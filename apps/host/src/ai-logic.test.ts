import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { expect, it } from 'vitest'

it('checks the guest Caboose AI service\'s translation, relay and fallback', () => {
  const script = fileURLToPath(new URL('../../../guest/ai/test_caboose_ai.py', import.meta.url))
  expect(() => execFileSync('python3', [script], { env: { ...process.env, PYTHONDONTWRITEBYTECODE: '1' }, stdio: 'pipe' })).not.toThrow()
})
