import { test } from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, writeFile, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { Worker } from './worker.mjs'

test('worker stays warm, restarts after exit/timeout, and never replays a failed request', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'caboose-worker-'))
  const path = join(dir, 'helper.py')
  await writeFile(path, `import sys, json, os, time
for line in sys.stdin:
    request = json.loads(line)
    if request.get('exit'): sys.exit(1)
    if request.get('hang'): time.sleep(10)
    print(json.dumps({'pid': os.getpid(), 'value': request.get('value')}), flush=True)
`)
  const worker = new Worker(path, [], 1000)
  try {
    const first = await worker.request({ value: 1 }, process.env)
    assert.equal((await worker.request({ value: 2 }, process.env)).pid, first.pid)
    await assert.rejects(worker.request({ exit: true }, process.env), /exited/)
    const second = await worker.request({ value: 3 }, process.env)
    assert.notEqual(second.pid, first.pid)
    await assert.rejects(worker.request({ hang: true }, process.env), /timed out/)
    assert.equal((await worker.request({ value: 4 }, process.env)).value, 4)
  } finally { worker.close(); await rm(dir, { recursive: true, force: true }) }
})
