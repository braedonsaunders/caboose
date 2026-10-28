import { defineConfig } from 'vitest/config'

// The runner tests start real processes (the runner and a stand-in agent).
export default defineConfig({ test: { testTimeout: 30_000, hookTimeout: 30_000 } })
