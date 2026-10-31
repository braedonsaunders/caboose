// Real-host check for /v1/commands: runs owner commands in the computer and checks their results.
import { randomBytes } from 'node:crypto'

const base = process.env.CABOOSE_URL, token = process.env.CABOOSE_OWNER_TOKEN
if (!base || !token) {
  console.error('Set CABOOSE_URL and CABOOSE_OWNER_TOKEN.')
  process.exit(2)
}
async function request(path, options = {}, accepted = [200]) {
  const response = await fetch(new URL(path, base), { ...options, headers: { authorization: `Bearer ${token}`, ...options.headers } })
  if (!accepted.includes(response.status)) throw new Error(`${options.method ?? 'GET'} ${path}: HTTP ${response.status}: ${(await response.text()).slice(0, 300)}`)
  return response
}
const fsPath = (operation, path) => `/v1/fs/${operation}?path=${encodeURIComponent(path)}`
const run = async (body, accepted = [201]) => (await request('/v1/commands', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) }, accepted)).json()
const expect = (condition, message, value) => { if (!condition) throw new Error(`${message}: ${JSON.stringify(value).slice(0, 600)}`) }
const jobs = []
try {
  // An input file staged through /v1/fs, standard input, an output file and the owner's login shell.
  const id = randomBytes(16).toString('hex'), dir = `.caboose-jobs/cmd-${id}`
  jobs.push(dir)
  await request(fsPath('mkdir', '.caboose-jobs'), { method: 'POST' }, [201, 409])
  await request(fsPath('mkdir', dir), { method: 'POST' }, [201])
  await request(fsPath('mkdir', `${dir}/in`), { method: 'POST' }, [201])
  await request(fsPath('content', `${dir}/in/notes.txt`), { method: 'PUT', headers: { 'if-none-match': '*' }, body: 'caboose check\n' }, [200, 201])
  const script = [
    'set -e',
    'test "$(id -un)" = caboose',
    'test "$PWD" = "$CABOOSE_JOB"',
    'shopt -q login_shell',
    'tr a-z A-Z < "$CABOOSE_IN/notes.txt"',
    'cat > "$CABOOSE_OUT/stdin.txt"',
    'echo to-stderr >&2',
  ].join('\n')
  const first = await run({ id, script, stdin: 'from stdin', inputs: ['notes.txt'], wait: 60 })
  expect(first.status === 'succeeded' && first.exitCode === 0, 'the command did not succeed', first)
  expect(first.stdout === 'CABOOSE CHECK\n' && first.stderr === 'to-stderr\n', 'unexpected output', first)
  expect(JSON.stringify(first.outputs) === '["stdin.txt"]' && first.directory === dir, 'unexpected outputs', first)
  const copied = await (await request(fsPath('content', `${dir}/out/stdin.txt`))).text()
  expect(copied === 'from stdin', 'the output file does not hold standard input', copied)
  expect((await run({ id, script: 'true' }, [409])).error, 'a reused id was accepted', id)

  // Exit codes, bounded output, time limits and cancellation.
  const failed = await run({ script: 'echo failing >&2; exit 7', wait: 60 })
  jobs.push(failed.directory)
  expect(failed.status === 'failed' && failed.exitCode === 7 && failed.stderr === 'failing\n', 'a non-zero exit was not reported', failed)
  const large = await run({ script: 'head -c 2000000 /dev/zero | tr "\\0" a', wait: 60 })
  jobs.push(large.directory)
  expect(large.status === 'succeeded' && large.truncated.stdout && large.stdout.length === 1024 * 1024, 'stdout was not bounded', { ...large, stdout: large.stdout.length })
  const limited = await run({ script: 'sleep 60', timeout: 2, wait: 30 })
  jobs.push(limited.directory)
  expect(limited.status === 'timed-out', 'the time limit did not stop the command', limited)
  const long = await run({ script: 'sleep 600' })
  jobs.push(long.directory)
  expect(long.status === 'running', 'a command without a wait did not return at once', long)
  await request('/v1/session/park', { method: 'POST' }, [409])
  const cancelled = await (await request(`/v1/commands/${long.id}/cancel`, { method: 'POST' })).json()
  expect(cancelled.status === 'cancelled', 'cancelling did not stop the command', cancelled)

  // A command keeps running after its request returns, and its result stays retrievable.
  const detached = await run({ script: 'sleep 3; echo late' })
  jobs.push(detached.directory)
  const later = await (await request(`/v1/commands/${detached.id}?wait=30`)).json()
  expect(later.status === 'succeeded' && later.stdout === 'late\n', 'a detached command did not finish', later)
  const listed = await (await request('/v1/commands')).json()
  expect(listed.commands.some(item => item.id === detached.id && item.status === 'succeeded'), 'the command is not listed', listed)
  console.log('Commands ran as caboose with inputs, stdin and outputs; exit codes, bounds, time limits, cancellation and detached runs behaved.')
} finally {
  for (const dir of jobs) await request(fsPath('item', dir), { method: 'DELETE' }, [200, 204, 404]).catch(error => console.error(`Could not trash ${dir}: ${error.message}`))
}
