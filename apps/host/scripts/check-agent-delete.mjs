#!/usr/bin/env node
// Run only in a disposable Linux container; argv[2] is the exported DELETE_TASK script.
import assert from 'node:assert/strict'
import { execFile, spawn } from 'node:child_process'
import { once } from 'node:events'
import { mkdtemp, mkdir, readFile, readdir, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { promisify } from 'node:util'
const exec = promisify(execFile)
const deletion = await readFile(process.argv[2], 'utf8')
const root = await mkdtemp(join(tmpdir(), 'caboose-delete-process-'))
const children = new Set()
const wait = ms => new Promise(resolve => setTimeout(resolve, ms))
async function runner(dir, name) {
  await mkdir(dir)
  const script = join(root, name)
  await writeFile(script, `import{writeFileSync}from'node:fs';writeFileSync('ready','yes');setInterval(()=>{},1000);`)
  // This is LAUNCH's detached shell wrapper, including the runner's inherited cwd.
  const child = spawn('/bin/sh', ['-c', `node ${script} run "$PWD" >> stderr.log 2>&1; echo $? > exit-code`], { cwd: dir, detached: true, stdio: 'ignore' })
  children.add(child)
  child.done = once(child, 'exit')
  child.on('exit', () => children.delete(child))
  await writeFile(join(dir, 'pid'), String(child.pid))
  for (let i = 0; i < 100; i++) {
    if (await readFile(join(dir, 'ready'), 'utf8').catch(() => '') === 'yes') return child
    await wait(20)
  }
  throw Error('Runner did not become ready')
}
try {
  for (const paused of [false, true]) {
    const id = paused ? '22222222-2222-4222-8222-222222222222' : '11111111-1111-4111-8111-111111111111'
    const dir = join(root, id)
    const child = await runner(dir, 'caboose-agentd.mjs')
    await writeFile(join(dir, 'prompt.txt'), 'private history')
    await writeFile(join(dir, 'report.txt'), 'keep report')
    if (paused) process.kill(-child.pid, 'SIGSTOP')
    await exec(process.execPath, ['-e', deletion, dir], { timeout: 10000 })
    await child.done
    assert.equal(await readFile(join(dir, 'report.txt'), 'utf8'), 'keep report')
    assert.equal((await readdir(dir)).includes('prompt.txt'), false)
    assert.deepEqual(await readdir(join(root, `.deleted-${id}`)), [])
    console.log(`PASS ${paused ? 'paused' : 'running'} runner group stopped; generated file preserved; durable tombstone present`)
  }
  const dir = join(root, '33333333-3333-4333-8333-333333333333')
  const unrelated = await runner(dir, 'unrelated.mjs')
  await writeFile(join(dir, 'prompt.txt'), 'keep history')
  await assert.rejects(exec(process.execPath, ['-e', deletion, dir], { timeout: 10000 }), /Cannot identify this chat runner/)
  assert.equal(await readFile(join(dir, 'prompt.txt'), 'utf8'), 'keep history')
  assert.equal(unrelated.exitCode, null)
  console.log('PASS unrelated process group refused; history preserved')
} finally {
  for (const child of children) {
    for (const signal of ['SIGCONT', 'SIGTERM']) try { process.kill(-child.pid, signal) } catch (error) { if (error.code !== 'ESRCH') throw error }
  }
  await Promise.all([...children].map(child => child.done))
  await rm(root, { recursive: true, force: true })
}
