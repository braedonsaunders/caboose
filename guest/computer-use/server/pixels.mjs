// What the accessibility tree leaves out, read from pixels: a window's picture, and its words
// by OCR (tesseract, enlarged and in grey by ImageMagick first) as lines with their centres in
// seat coordinates.
import { spawn } from 'node:child_process'
import { mkdtemp, readFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { seat } from './seat.mjs'

const OCR_HEADER = "Text read from pixels (OCR; x,y are seat coordinates of each line's centre):"

/** Runs `work(file, shot, png)` on a picture of the focused window, in a directory removed after. */
async function focusedPicture(work) {
  const listing = await seat('windows')
  const window = listing.windows.find(w => w.id === listing.focused)
  if (!window) return null
  const dir = await mkdtemp(join(tmpdir(), 'caboose-shot-'))
  try {
    const file = join(dir, 'window.png')
    const shot = await seat('screenshot', '--out', file, '--window', String(window.id))
    return await work({ file, dir, shot, window, png: await readFile(file) })
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
}
const size = png => [png.readUInt32BE(16), png.readUInt32BE(20)]

/** For a window with no accessibility tree (SDL, games, custom-drawn toolkits): its picture and words. */
export async function pixelFallback() {
  return await focusedPicture(async ({ file, shot, window, png }) => {
    const parts = [{ type: 'text', text: `No accessibility tree in ${window.kind} ${window.id}: its picture follows (read from pixels).` },
      { type: 'image', data: png.toString('base64'), mimeType: 'image/png' }]
    const words = await ocr(file, shot.rect, ...size(png))
    if (words) parts.push({ type: 'text', text: `${OCR_HEADER}\n${words}` })
    return parts
  }) ?? []
}

/** The focused window's words read from its pixels. */
export async function windowWords() {
  return await focusedPicture(async ({ file, shot, png }) => {
    const words = await ocr(file, shot.rect, ...size(png))
    return words ? `${OCR_HEADER}\n${words}` : 'No text was read from pixels.'
  }) ?? 'No window has the keyboard.'
}

/**
 * Scrolled areas the application draws but leaves out of its tree (a11y.py's `unread`: a list
 * or icon view a toolkit does not expose): their words read from the window's pixels.
 */
export async function unreadWords(regions) {
  return await focusedPicture(async ({ file, dir, shot, png }) => {
    const [width, height] = size(png)
    const [x0, y0, w, h] = shot.rect ?? [0, 0, width, height]
    const sx = width / w, sy = height / h
    const lines = []
    for (const [index, [x, y, rw, rh]] of regions.entries()) {
      const crop = { x: Math.max(0, Math.round((x - x0) * sx)), y: Math.max(0, Math.round((y - y0) * sy)), w: Math.round(rw * sx), h: Math.round(rh * sy) }
      if (crop.w < 8 || crop.h < 8) continue
      const out = join(dir, `region-${index}.png`)
      if (!await convert([file, '-crop', `${crop.w}x${crop.h}+${crop.x}+${crop.y}`, '+repage', '-colorspace', 'Gray', '-resize', '200%', out])) continue
      const words = await read(out, [x, y, rw, rh], crop.w * 2, crop.h * 2)
      if (words) lines.push(`In ${x},${y},${rw}x${rh}, drawn but not exposed by the application (read from pixels; x,y are each line's centre):\n${words}`)
    }
    return lines.join('\n')
  }) ?? ''
}

function convert(args) {
  return new Promise(resolve => {
    const child = spawn('convert', args, { stdio: 'ignore' })
    child.on('error', () => resolve(false))
    child.on('close', code => resolve(code === 0))
  })
}

// Small interface text reads better enlarged and in grey, and as sparse text rather than a
// page (tesseract --psm 11).
async function ocr(file, rect, width, height) {
  const enlarged = file.replace(/\.png$/, '-x2.png')
  if (await convert([file, '-colorspace', 'Gray', '-resize', '200%', enlarged])) return read(enlarged, rect, width * 2, height * 2)
  return read(file, rect, width, height)
}

/** Tesseract's TSV for a picture `width` x `height` pixels showing `rect` of the seat: its lines of words with their centres. */
export function words(tsv, rect, width, height) {
  const [x0, y0, w, h] = rect ?? [0, 0, width, height]
  const sx = w / width, sy = h / height
  const lines = new Map()
  for (const row of tsv.split('\n').slice(1)) {
    const f = row.split('\t')
    // Words only: textures and icons read as stray symbols at low confidence. A short name
    // with digits ("p1") counts when it is read with high confidence.
    if (f.length < 12 || Number(f[10]) < 70 || !(/[\p{L}]{3,}|\p{N}{2,}/u.test(f[11]) || (Number(f[10]) >= 85 && /\p{L}[\p{L}\p{N}]|\p{N}\p{L}/u.test(f[11])))) continue
    const key = `${f[2]}.${f[3]}.${f[4]}`
    const line = lines.get(key) ?? { words: [], left: Infinity, top: Infinity, right: 0, bottom: 0 }
    line.words.push(f[11].trim())
    line.left = Math.min(line.left, +f[6]); line.top = Math.min(line.top, +f[7])
    line.right = Math.max(line.right, +f[6] + +f[8]); line.bottom = Math.max(line.bottom, +f[7] + +f[9])
    lines.set(key, line)
  }
  return [...lines.values()].slice(0, 80).map(l => `${JSON.stringify(l.words.join(' '))} at ${Math.round(x0 + (l.left + l.right) / 2 * sx)},${Math.round(y0 + (l.top + l.bottom) / 2 * sy)}`).join('\n')
}

function read(file, rect, width, height) {
  return new Promise(resolve => {
    const child = spawn('tesseract', [file, '-', '--psm', '11', 'tsv'], { stdio: ['ignore', 'pipe', 'ignore'] })
    let out = ''
    child.stdout.on('data', chunk => { out += chunk })
    child.on('error', () => resolve(''))
    child.on('close', () => resolve(words(out, rect, width, height)))
  })
}
