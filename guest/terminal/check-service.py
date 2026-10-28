#!/usr/bin/env python3
"""Run the real terminal service in Linux and drive it as the host does: sessions, input,
resize, detach and reattach, replacement, backpressure, hangup, exit and a started program."""
import asyncio
import base64
import importlib.util
import json
import os
import tempfile
import urllib.error
import urllib.request

from websockets.asyncio.client import connect
from websockets.exceptions import ConnectionClosed

root = tempfile.mkdtemp()
token_file = os.path.join(root, 'token')
with open(token_file, 'w') as f:
    f.write('test-token')
os.environ['CABOOSE_TERMINAL_TOKEN_FILE'] = token_file
os.environ['CABOOSE_TERMINAL_DISPLAY_ENV'] = os.path.join(root, 'display.env')
with open(os.environ['CABOOSE_TERMINAL_DISPLAY_ENV'], 'w') as f:
    f.write("WAYLAND_DISPLAY='wayland-caboose-0'\n")
spec = importlib.util.spec_from_file_location('terminal', os.path.join(os.path.dirname(__file__), 'caboose-terminal.py'))
terminal = importlib.util.module_from_spec(spec)
spec.loader.exec_module(terminal)
AUTH = {'Authorization': 'Bearer test-token'}


class Client:
    def __init__(self, socket):
        self.socket, self.output, self.controls, self.received = socket, bytearray(), [], 0

    async def until(self, needle, timeout=10):
        async def read():
            while needle not in self.output:
                message = await self.socket.recv()
                if isinstance(message, bytes):
                    self.output += message
                    self.received += len(message)
                else:
                    self.controls.append(json.loads(message))
        await asyncio.wait_for(read(), timeout)

    async def run(self, command, marker):
        await self.socket.send(command.encode() + b'\r')
        await self.until(marker.encode())


async def open_client(port, query):
    socket = await connect(f'ws://127.0.0.1:{port}/?{query}', additional_headers=AUTH, max_size=None)
    hello = json.loads(await socket.recv())
    assert hello['type'] == 'hello', hello
    client = Client(socket)
    client.received = hello['offset']
    return client, hello


def http(port, path, headers=AUTH):
    request = urllib.request.Request(f'http://127.0.0.1:{port}{path}', headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=5) as response:
            return response.status, json.loads(response.read())
    except urllib.error.HTTPError as error:
        return error.code, json.loads(error.read() or b'null')


async def check():
    started = asyncio.get_running_loop().create_future()
    service = asyncio.ensure_future(terminal.main('127.0.0.1', 0, lambda server, svc: started.set_result((server, svc))))
    server, _ = await started
    port = server.sockets[0].getsockname()[1]
    loop = asyncio.get_running_loop()
    get = lambda path, headers=AUTH: loop.run_in_executor(None, http, port, path, headers)

    assert (await get('/sessions', {}))[0] == 401
    assert (await get('/sessions', {'Authorization': 'Bearer wrong'}))[0] == 401
    assert await get('/sessions') == (200, {'sessions': []})
    assert (await get('/nowhere'))[0] == 404

    # A new session is a login shell with a colour terminal and the owner's display.
    first, hello = await open_client(port, 'cols=80&rows=24')
    assert hello['offset'] == 0 and hello['reset'] is True and hello['modes'] == {}, hello
    session = hello['session']
    await first.run('echo "caboose-$((6*7)) $TERM $COLORTERM $WAYLAND_DISPLAY"; shopt -q login_shell && echo login-$((0+1))', 'login-1')
    assert b'caboose-42 xterm-256color truecolor wayland-caboose-0' in first.output, first.output

    # Resize reaches the terminal.
    await first.socket.send(json.dumps({'type': 'resize', 'cols': 100, 'rows': 30}))
    await first.run('stty size', '30 100')

    # Output written while detached is replayed from the client's offset, not repeated.
    await first.socket.send(b'sleep 0.5; echo after-$((40+2))-detach\r')
    await first.until(b'sleep 0.5')
    offset = first.received
    await first.socket.close()
    await asyncio.sleep(1.2)
    status, listing = await get('/sessions')
    assert status == 200 and listing['sessions'][0]['id'] == session and listing['sessions'][0]['attached'] is False, listing
    assert listing['sessions'][0]['cols'] == 100 and listing['sessions'][0]['command'] == 'bash', listing
    second, hello = await open_client(port, f'cols=90&rows=20&session={session}&offset={offset}')
    assert hello == {'type': 'hello', 'session': session, 'offset': offset, 'reset': False}, hello
    await second.until(b'after-42-detach')
    assert b'stty size' not in second.output
    await second.run('stty size', '20 90')

    # A client that has nothing gets what is kept, with a reset.
    third, hello = await open_client(port, f'cols=90&rows=20&session={session}')
    assert hello['reset'] is True and hello['offset'] == 0, hello
    await third.until(b'after-42-detach')
    # ...and replaces the client that was attached.
    try:
        await asyncio.wait_for(second.socket.recv(), 5)
        while True:
            await asyncio.wait_for(second.socket.recv(), 5)
    except ConnectionClosed:
        assert second.socket.close_code == 4001, second.socket.close_code

    # Modes survive a replay that no longer holds the sequence that set them.
    await third.run("printf '\\033[?2004h'; head -c 300000 /dev/zero | tr '\\0' x; echo; echo modes-$((1+1))", 'modes-2')
    _, hello = await open_client(port, f'cols=90&rows=20&session={session}&offset=1')
    assert hello['reset'] is True and hello['offset'] > 1 and hello['modes'].get('2004') is True, hello

    # A fast producer is paced by the reader rather than buffered.
    fourth, _ = await open_client(port, f'cols=90&rows=20&session={session}&offset={2**40}')
    await fourth.run('head -c 4000000 /dev/zero | tr "\\0" y; echo; echo bulk-$((2+2))', 'bulk-4')
    assert fourth.output.count(b'y') >= 4000000

    # Bad control messages close the connection; the session stays.
    await fourth.socket.send('{"type":"exec"}')
    try:
        while True:
            await asyncio.wait_for(fourth.socket.recv(), 5)
    except ConnectionClosed:
        assert fourth.socket.close_code == 4400, fourth.socket.close_code
    assert len((await get('/sessions'))[1]['sessions']) == 1

    # Exit ends the session and says how.
    fifth, _ = await open_client(port, f'cols=90&rows=20&session={session}&offset={2**40}')
    await fifth.socket.send(b'exit 3\r')
    try:
        while True:
            message = await asyncio.wait_for(fifth.socket.recv(), 10)
            if isinstance(message, str):
                fifth.controls.append(json.loads(message))
    except ConnectionClosed:
        assert fifth.socket.close_code == 1000, fifth.socket.close_code
    assert fifth.controls[-1] == {'type': 'exit', 'code': 3}, fifth.controls
    assert (await get('/sessions'))[1] == {'sessions': []}
    try:
        await open_client(port, f'cols=80&rows=24&session={session}')
        raise AssertionError('an ended session was attached')
    except ConnectionClosed as error:
        assert error.rcvd.code == 4404, error

    # Hangup from the listing side ends a session with SIGHUP.
    sixth, hello = await open_client(port, 'cols=80&rows=24')
    await sixth.run('echo ready-$((3*3))', 'ready-9')
    assert (await get(f'/hangup?session={hello["session"]}'))[0] == 200
    assert (await get(f'/hangup?session={"0" * 32}'))[0] == 404
    try:
        while True:
            message = await asyncio.wait_for(sixth.socket.recv(), 10)
            if isinstance(message, str):
                sixth.controls.append(json.loads(message))
    except ConnectionClosed:
        pass
    assert sixth.controls[-1] == {'type': 'exit', 'code': None, 'signal': 1}, sixth.controls

    # In-band hangup, and the session cap makes room by hanging up the longest-detached session.
    sessions = []
    for _ in range(terminal.MAX_SESSIONS):
        client, hello = await open_client(port, 'cols=80&rows=24')
        sessions.append(hello['session'])
        await client.socket.close()
    extra, hello = await open_client(port, 'cols=80&rows=24')
    await asyncio.sleep(0.5)
    live = [s['id'] for s in (await get('/sessions'))[1]['sessions']]
    assert sessions[0] not in live and hello['session'] in live and len(live) == terminal.MAX_SESSIONS, live
    await extra.socket.send('{"type":"hangup"}')
    try:
        while True:
            await asyncio.wait_for(extra.socket.recv(), 10)
    except ConnectionClosed:
        assert extra.socket.close_code == 1000

    # A session started with one program runs it, not a shell, and ends with its exit.
    argv = base64.urlsafe_b64encode(json.dumps(['/bin/sh', '-c', 'read answer; echo "got-$answer"; exit 4']).encode()).decode().rstrip('=')
    status, started = await get(f'/start?cols=80&rows=24&argv={argv}')
    assert status == 200 and terminal.SESSION_ID.fullmatch(started['session']), started
    assert (await get('/start?cols=80&rows=24&argv=W10'))[0] == 400
    assert (await get(f'/start?cols=80&rows=24&argv={argv}', {}))[0] == 401
    program, hello = await open_client(port, f'cols=80&rows=24&session={started["session"]}')
    await program.run('caboose', 'got-caboose')
    try:
        while True:
            message = await asyncio.wait_for(program.socket.recv(), 10)
            if isinstance(message, str):
                program.controls.append(json.loads(message))
    except ConnectionClosed:
        pass
    assert program.controls[-1] == {'type': 'exit', 'code': 4}, program.controls

    # Without a session to reattach, an invalid request is refused.
    try:
        await open_client(port, 'cols=0&rows=24')
        raise AssertionError('accepted cols=0')
    except ConnectionClosed as error:
        assert error.rcvd.code == 4400

    print('terminal service: ok')


async def run():
    try:
        await asyncio.wait_for(check(), 120)
    finally:
        for task in asyncio.all_tasks() - {asyncio.current_task()}:
            task.cancel()


asyncio.run(run())
