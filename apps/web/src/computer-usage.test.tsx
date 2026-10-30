import * as React from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import { expect, it } from 'vitest'
import { UsageMetrics, cpuHistoryLabel } from './components/ComputerUsage.js'
import type { ComputerUsage } from '../../../packages/capacity/types.js'
const usage: ComputerUsage = { sampledAt: 1000, memoryBytes: 512 * 1024 ** 2, cacheBytes: 1000, memoryLimitBytes: 2 * 1024 ** 3, memoryKind: 'cgroup', cpuPercent: 50, cpuSeconds30d: 120, coveredSeconds30d: 60, collectingSince: 1000 }
it('renders actual memory separately from limits and explains CPU normalization and coverage', () => {
  const html = renderToStaticMarkup(<UsageMetrics usage={usage} />)
  for (const text of ['Memory charged', '512.0 MiB', 'Runtime limit: 2.0 GiB', '50.0%', '100% = all runtime vCPUs busy', '120 CPU seconds', 'Missing intervals are excluded']) expect(html).toContain(text)
})
it('does not present absent coverage as a measured zero month', () => {
  expect(cpuHistoryLabel({ ...usage, coveredSeconds30d: 0, cpuSeconds30d: 0 })).toBe('Collecting samples')
  expect(cpuHistoryLabel({ ...usage, cpuSeconds30d: 0 })).toBe('0 CPU seconds')
  const html = renderToStaticMarkup(<UsageMetrics usage={{ ...usage, memoryBytes: null, cpuPercent: null }} />)
  expect(html).toContain('Unavailable')
})
