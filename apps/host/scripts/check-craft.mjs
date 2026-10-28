// Real-host check for the installed Craft CLIs. Stages files and checks output signatures.
import { createReadStream } from 'node:fs'
import { randomBytes } from 'node:crypto'
import { basename, extname } from 'node:path'

const base = process.env.CABOOSE_URL, token = process.env.CABOOSE_OWNER_TOKEN
const [app, ...inputs] = process.argv.slice(2)
const formats = { photocraft: 'png', pdfcraft: 'pdf', lightcraft: 'png', filmcraft: 'mp4' }
const format = formats[app]
if (!base || !token || !format || !inputs.length || (app === 'pdfcraft' && inputs.length < 2) || (app !== 'photocraft' && app !== 'pdfcraft' && inputs.length !== 1)) {
  console.error('Set CABOOSE_URL and CABOOSE_OWNER_TOKEN; pass photocraft|pdfcraft|lightcraft|filmcraft followed by input files.')
  process.exit(2)
}
const names = inputs.map((file, index) => {
  const ext = extname(basename(file)).slice(1).toLowerCase()
  if (!/^[a-z0-9]{1,12}$/.test(ext)) throw new Error('Inputs need a filename extension')
  return `input-${index}.${ext}`
})
const job = randomBytes(16).toString('hex'), dir = `.caboose-jobs/${job}`
async function request(path, options = {}, accepted = [200]) {
  const response = await fetch(new URL(path, base), { ...options, headers: { authorization: `Bearer ${token}`, ...options.headers } })
  if (!accepted.includes(response.status)) throw new Error(`${path}: HTTP ${response.status}: ${(await response.text()).slice(0, 300)}`)
  return response
}
const fsPath = (operation, path) => `/v1/fs/${operation}?path=${encodeURIComponent(path)}`
await request(fsPath('mkdir', '.caboose-jobs'), { method: 'POST' }, [201, 409])
await request(fsPath('mkdir', dir), { method: 'POST' }, [201])
for (let i = 0; i < inputs.length; i++) {
  await request(fsPath('content', `${dir}/${names[i]}`), { method: 'PUT', headers: { 'if-none-match': '*' }, body: createReadStream(inputs[i]), duplex: 'half' }, [200, 201])
}
const response = await request(`/v1/catalog/${app}/run`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ job, inputs: names, format }) })
const { outputs, warnings } = await response.json()
const count = app === 'photocraft' ? inputs.length : 1
if (!Array.isArray(outputs) || outputs.length !== count || outputs.some((path, i) => path !== `${dir}/output-${i}.${format}`)) throw new Error('Unexpected output paths')
for (const path of outputs) {
  const reader = (await request(fsPath('content', path))).body.getReader()
  let header = new Uint8Array()
  while (header.length < 12) {
    const { value, done } = await reader.read()
    if (done) break
    const combined = new Uint8Array(header.length + value.length); combined.set(header); combined.set(value, header.length); header = combined
  }
  await reader.cancel()
  const signature = format === 'png' ? [137, 80, 78, 71, 13, 10, 26, 10] : format === 'pdf' ? [37, 80, 68, 70, 45] : null
  if (signature ? !signature.every((byte, i) => header[i] === byte) : !(header.length >= 12 && String.fromCharCode(...header.slice(4, 8)) === 'ftyp')) throw new Error('Unexpected output signature')
}
await request(fsPath('item', dir), { method: 'DELETE' })
console.log(`${app} produced ${outputs.length} verified output(s); job moved to Trash.`)
if (warnings?.length) console.log(`CLI output: ${warnings.join('\n')}`)
