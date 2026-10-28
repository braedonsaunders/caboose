import type { AgentGuest } from './agents.js'
import type { AgentToolJournal, ToolRequest } from './agent-tools-journal.js'

// dir_fd + O_NOFOLLOW means a guest symlink cannot redirect a privileged read. The
// helper itself runs as caboose; it only visits UUID directories supplied by the host.
const SCRIPT = String.raw`
import os, sys, json, stat, re, base64, itertools, time
U = re.compile(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
root = os.open('/home/caboose/Agents', flags)
def box(task):
    if not U.fullmatch(task): raise ValueError('task')
    t = os.open(task, flags, dir_fd=root)
    try: return os.open('tool-mailbox', flags, dir_fd=t)
    finally: os.close(t)
def read(fd, name, limit):
    f = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
    try:
        st = os.fstat(f)
        if not stat.S_ISREG(st.st_mode) or st.st_size > limit: raise ValueError('invalid file')
        data = os.read(f, limit + 1)
        if len(data) > limit: raise ValueError('too large')
        return data
    finally: os.close(f)
if sys.argv[1] == 'poll':
    out = []
    cursors = []
    for arg in sys.argv[2:]:
        task, turn, offset = arg.split(':')
        turn, offset = int(turn), int(offset)
        count = 0
        full = False
        try:
            d = box(task)
            try:
                for entry in itertools.islice(os.scandir(d), offset, offset + 256):
                    if len(out) >= 16:
                        full = True
                        break
                    count += 1
                    name = entry.name
                    if name.endswith('.response') and U.fullmatch(name[:-9]):
                        try: os.stat(name[:-9] + '.request', dir_fd=d, follow_symlinks=False)
                        except FileNotFoundError:
                            try: os.unlink(name, dir_fd=d)
                            except FileNotFoundError: pass
                        continue
                    if not name.endswith('.request') or not U.fullmatch(name[:-8]): continue
                    try:
                        st = os.stat(name, dir_fd=d, follow_symlinks=False)
                        try:
                            response = os.stat(name[:-8] + '.response', dir_fd=d, follow_symlinks=False)
                        except FileNotFoundError: response = None
                        # A caller can wait up to 120 seconds. Leave its response in place
                        # until that window has elapsed, even if the turn has changed.
                        if response is not None:
                            if time.time() - max(st.st_mtime, response.st_mtime) > 120:
                                os.unlink(name, dir_fd=d)
                                os.unlink(name[:-8] + '.response', dir_fd=d)
                            continue
                        data = read(d, name, 65536)
                        try: value = json.loads(data)
                        except (ValueError, UnicodeDecodeError): value = None
                        valid = (isinstance(value, dict) and set(value) == {'id', 'turn', 'tool', 'arguments'}
                                 and value['id'] == name[:-8] and type(value['turn']) is int
                                 and isinstance(value['tool'], str) and isinstance(value['arguments'], dict))
                        if not valid or value['turn'] != turn:
                            if time.time() - st.st_mtime > 120 and (not valid or value['turn'] < turn):
                                os.unlink(name, dir_fd=d)
                            continue
                        out.append([task, name[:-8], base64.b64encode(data).decode()])
                    except (OSError, ValueError): pass
            finally: os.close(d)
        except OSError: pass
        cursors.append([task, offset + count if full or count == 256 else 0])
    print(json.dumps([cursors, out]))
elif sys.argv[1] == 'respond':
    task, req = sys.argv[2:4]
    payload = "".join(sys.argv[4:])
    if not U.fullmatch(req): raise ValueError('request')
    d = box(task)
    try:
        read(d, req + '.request', 65536)
        name = '.' + req + '.' + os.urandom(12).hex()
        f = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=d)
        try:
            data = base64.b64decode(payload, validate=True)
            with os.fdopen(f, 'wb') as out: out.write(data); out.flush(); os.fsync(out.fileno())
            os.rename(name, req + '.response', src_dir_fd=d, dst_dir_fd=d)
            os.fsync(d)
        finally:
            try: os.unlink(name, dir_fd=d)
            except FileNotFoundError: pass
    finally: os.close(d)
`
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
export interface LiveToolTask { id: string; profileId: string; turn: number }
async function run(guest: AgentGuest, args: string[]): Promise<string> {
  return guest.run('/usr/sbin/runuser', ['-u', 'caboose', '--', 'python3', '-c', SCRIPT, ...args], 15_000)
}
const pollStates = new WeakMap<AgentToolJournal, { taskOffset: number; offsets: Map<string, number> }>()
/** Poll separately from task delivery chains: an ACP prompt can be waiting on this call. */
export async function pollAgentTools(guest: AgentGuest, journal: AgentToolJournal, live: LiveToolTask[], stillLive: (task: LiveToolTask) => boolean): Promise<void> {
  const tasks = new Map(live.filter(t => UUID.test(t.id) && UUID.test(t.profileId) && journal.profileForTask(t.id) === t.profileId).map(t => [t.id, t]))
  if (!tasks.size) return
  let state = pollStates.get(journal)
  if (!state) { state = { taskOffset: 0, offsets: new Map() }; pollStates.set(journal, state) }
  for (const id of state.offsets.keys()) if (!tasks.has(id)) state.offsets.delete(id)
  const ids = [...tasks.keys()]
  const start = state.taskOffset++ % ids.length
  const ordered = [...ids.slice(start), ...ids.slice(0, start)]
  const offsets = new Map(ordered.map(id => [id, state.offsets.get(id) ?? 0]))
  const output = await run(guest, ['poll', ...ordered.map(id => `${id}:${tasks.get(id)!.turn}:${offsets.get(id)}`)])
  if (Buffer.byteLength(output) > 1_500_000) throw new Error('Tool mailbox poll too large')
  const result: unknown = JSON.parse(output)
  if (!Array.isArray(result) || result.length !== 2 || !Array.isArray(result[0]) || result[0].length !== ordered.length) throw new Error('Invalid tool mailbox poll')
  for (const cursor of result[0]) {
    if (!Array.isArray(cursor) || cursor.length !== 2 || typeof cursor[0] !== 'string' || !offsets.has(cursor[0]) || !Number.isSafeInteger(cursor[1]) || (cursor[1] !== 0 && (cursor[1] < offsets.get(cursor[0])! || cursor[1] > offsets.get(cursor[0])! + 256))) throw new Error('Invalid tool mailbox cursor')
    state.offsets.set(cursor[0], cursor[1])
  }
  const rows: unknown = result[1]
  if (!Array.isArray(rows) || rows.length > 16) throw new Error('Invalid tool mailbox poll')
  for (const row of rows) {
    if (!Array.isArray(row) || row.length !== 3 || !row.every(x => typeof x === 'string')) continue
    const [taskId, id, encoded] = row as string[]
    const task = tasks.get(taskId!)
    if (!task || !id || !UUID.test(id) || !encoded || encoded.length > 90000 || !stillLive(task)) continue
    let value: unknown
    try { value = JSON.parse(Buffer.from(encoded, 'base64').toString('utf8')) } catch { continue }
    if (!value || typeof value !== 'object' || Array.isArray(value)) continue
    const envelope = value as Record<string, unknown>
    if (Object.keys(envelope).sort().join(',') !== 'arguments,id,tool,turn' || envelope.id !== id || envelope.turn !== task.turn || typeof envelope.tool !== 'string' || !envelope.arguments || typeof envelope.arguments !== 'object' || Array.isArray(envelope.arguments)) continue
    let result
    try { result = await journal.execute({ taskId: task.id, profileId: task.profileId, turn: task.turn }, { id, tool: envelope.tool, arguments: envelope.arguments } as ToolRequest, () => stillLive(task)) }
    catch (error) { result = { ok: false, error: error instanceof Error ? error.message.slice(0, 2000) : 'Tool request failed' } }
    if (!stillLive(task)) continue
    const response = Buffer.from(JSON.stringify({ id, ...result })).toString('base64')
    await run(guest, ['respond', task.id, id, ...(response.match(/.{1,48000}/g) ?? [])]).catch(() => {})
  }
}
