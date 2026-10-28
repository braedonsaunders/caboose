import { execFileSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { expect, it } from 'vitest'

it('checks guest path confinement, ranges, versions and change anchors', () => {
  const script = fileURLToPath(new URL('../../../guest/files/test_logic.py', import.meta.url))
  expect(() => execFileSync('python3', [script], { env: { ...process.env, PYTHONDONTWRITEBYTECODE: '1' } })).not.toThrow()
})
