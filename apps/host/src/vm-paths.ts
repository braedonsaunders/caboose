import { existsSync } from 'node:fs'
import { join } from 'node:path'

/** Preserve a computer's disk layout after template opt-in changes. */
export function vmPaths(root: string, id: string, newTemplate = false) {
  const overlays = join(root, 'overlays')
  const legacyDisk = join(overlays, `${id}.raw`), legacySnapshot = join(overlays, `${id}.snapshot`)
  const templateDir = join(overlays, `${id}.template`)
  const legacyData = [legacyDisk, legacySnapshot, `${legacySnapshot}.cold.json`].some(path => existsSync(path))
  const template = existsSync(templateDir)
  const legacy = legacyData || (!template && [join(overlays, `${id}.system-image.json`), join(overlays, `${id}.resources.json`)].some(existsSync))
  if (legacyData && template) throw new Error(`Computer ${id} has conflicting disk layouts; recovery is required`)
  if (template || (!legacy && newTemplate)) return { template: true, directory: templateDir, disk: join(templateDir, 'disk.raw'), snapshot: join(templateDir, `${id}.snapshot`) }
  return { template: false, directory: overlays, disk: legacyDisk, snapshot: legacySnapshot }
}
