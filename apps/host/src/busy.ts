import type { RunningApps } from './running-apps.js'

/** An app using at least this much of one core, or moving this much disk I/O, is working. */
export const APP_BUSY_CPU_PERCENT = 5
export const APP_BUSY_IO_BYTES_PER_SECOND = 1024 * 1024

/**
 * Whether an app the owner runs is working right now (a download, a build, a game), by its
 * last sample: CPU or disk I/O over the thresholds. Caboose's own session (the desktop, its
 * services) is not an app.
 */
export function appsBusy(running: Pick<RunningApps, 'apps' | 'services'>): boolean {
  const working = (item: { cpuPercent: number; io: { readBytesPerSecond: number; writeBytesPerSecond: number } }) =>
    item.cpuPercent >= APP_BUSY_CPU_PERCENT || item.io.readBytesPerSecond + item.io.writeBytesPerSecond >= APP_BUSY_IO_BYTES_PER_SECOND
  return running.apps.some(app => app.kind === 'app' && working(app)) || running.services.some(service => service.state === 'active' && working(service))
}
