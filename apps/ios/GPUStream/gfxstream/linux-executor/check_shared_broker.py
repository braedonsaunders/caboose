#!/usr/bin/env python3
"""The computer's shared GPU broker serves two seats from one executor (docs/gpu-live.md, "Seats").

  python3 check_shared_broker.py COMPUTER WORK REPO [--port N]

COMPUTER is a running computer with its release installed (the broker modules in
/usr/local/libexec/caboose-gpu and the driver in /usr/local/lib/caboose-gpu-live). WORK is a
Linux executor build (WORK/build/libcaboose_gpu_executor.so); REPO a checkout whose broker
(guest/gpu/gfxstream) and compositor (guest/display/target/release/caboose-display) are under
test. In a directory of its own in the computer the check starts one shared broker
(`--dir`, `--listen`), an owner-seat and an agent-seat compositor joined to it
(`--private-gpu-broker`), and then a Linux executor, on ports and sockets of its own; it
touches no display of the computer's. It requires that:

- both compositors join their own seat's control socket;
- with no executor, the agent seat's applications draw and its compositor renders on the
  computer: a screenshot of an application's window there has a picture;
- the executor, connecting to the broker itself, makes each seat's sockets and reaches
  both compositors (EXECUTOR_READY);
- with a viewer on the owner seat, an application there binds its surface and presents
  through the executor;
- an application on the agent seat is refused its surface bind by an executor that does
  not route by seat, and keeps drawing on the computer;
- a process's stream on the owner socket and its surface on the agent socket is refused.
"""
import argparse
import json
import os
import shlex
import struct
import subprocess
import sys
import time
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
PHONE = ('guest-handles,guest-handle-arrays,completion-feed,ordered-present,guest-images,guest-query-pools,'
         'shader-cache,executor-resume,zstd-stream,upload-cache,guest-buffer-views,batched-descriptor-sets-inline')


def run(*args, check=True, **kwargs):
    return subprocess.run(args, check=check, capture_output=True, text=True, **kwargs).stdout


class Check:
    def __init__(self, o):
        self.o = o
        self.computer = o.computer
        self.dir = f'/tmp/caboose-shared-broker-{os.getpid()}'
        self.executor_name = f'caboose-shared-broker-{os.getpid()}'
        self.failures = []

    def sh(self, command, user=None, detach=False, check=True):
        args = ['docker', 'exec'] + (['-d'] if detach else []) + (['-u', user] if user else []) + [self.computer, 'sh', '-c', command]
        return run(*args, check=check)

    def require(self, ok, what):
        print(('PASS ' if ok else 'FAIL ') + what, flush=True)
        if not ok: self.failures.append(what)

    def wait(self, predicate, seconds):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if predicate(): return True
            time.sleep(0.25)
        return False

    def log(self, name):
        return self.sh(f'cat {self.dir}/{name} 2>/dev/null', check=False)

    def start(self):
        d, o = self.dir, self.o
        self.sh(f'mkdir -m 0700 -p {d}/run {d}/home {d}/bin && cp -a /usr/local/libexec/caboose-gpu {d}/libexec && '
                f'head -c 24 /dev/urandom | od -An -tx1 | tr -d " \\n" > {d}/token')
        gfx = os.path.join(o.repo, 'guest/gpu/gfxstream')
        run('docker', 'cp', '-q', os.path.join(gfx, 'caboose-gpu-broker'), f'{self.computer}:{d}/libexec/broker.py')
        for module in ('gpu_admission.py', 'control_protocol.py', 'process_binding.py', 'executor_lease.py',
                       'buffer_presentation.py', 'surface_local_protocol.py', 'ipc_handoff.py', 'gpu_websocket.py'):
            run('docker', 'cp', '-q', os.path.join(gfx, module), f'{self.computer}:{d}/libexec/{module}')
        run('docker', 'cp', '-q', os.path.join(o.repo, 'guest/display/target/release/caboose-display'),
            f'{self.computer}:{d}/bin/caboose-display')
        env = '\n'.join([
            f'export PATH=/usr/local/bin:/usr/bin:/bin HOME={d}/home XDG_RUNTIME_DIR={d}/run',
            'export GALLIUM_DRIVER=zink ZINK_DESCRIPTORS=lazy CABOOSE_GPU_ROUTING=1 NODEVICE_SELECT=1', ''])
        self.sh(f"printf '%s' {shlex.quote(env)} > {d}/env && chown -R caboose {d}")
        self.sh(f'. {d}/env; exec python3 -u {d}/libexec/broker.py --dir {d}/run/caboose-gpu --listen 127.0.0.1:{o.port} '
                f'--token-file {d}/token --private-indexed > {d}/broker.log 2>&1', user='caboose', detach=True)
        self.wait(lambda: self.exists(f'{d}/run/caboose-gpu/agent/control.sock'), 15)
        for seat, port, xdisplay in (('owner', o.port + 1, o.xdisplay), ('agent', o.port + 2, o.xdisplay + 1)):
            seat_dir = f'{d}/run/caboose-gpu/{seat}'
            prefix = 'CABOOSE_SEAT=agent ' if seat == 'agent' else ''
            flags = '--no-games ' if seat == 'agent' else ''
            self.sh(f'. {d}/env; {prefix}exec {d}/bin/caboose-display --listen 127.0.0.1:{port} --token-file {d}/token '
                    f'--socket wayland-shared-{seat} --x-display {xdisplay} --no-audio --no-devices {flags}'
                    f'--private-gpu-broker {seat_dir}/control.sock --private-gpu-stream-socket {seat_dir}/gpu.sock '
                    f'--private-gpu-surface-socket {seat_dir}/surface.sock --private-gpu-indexed '
                    f'--env-file {d}/{seat}.env --display 1280x800@60x1 > {d}/{seat}.log 2>&1', user='caboose', detach=True)
        for seat in ('owner', 'agent'):
            self.wait(lambda seat=seat: subprocess.run(['docker', 'exec', self.computer, 'test', '-s', f'{d}/{seat}.env']).returncode == 0, 30)

    def exists(self, path):
        return subprocess.run(['docker', 'exec', self.computer, 'test', '-e', path]).returncode == 0

    def control(self, seat, request):
        """One request on a seat's compositor control socket; the raw reply."""
        # A reply is one JSON line; a picture's (`"png":N`) is followed by its N bytes.
        script = ('import json,socket,sys\n'
                  's=socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.sendall(sys.argv[2].encode()+b"\\n")\n'
                  'd=b""\nwhile b"\\n" not in d:\n b=s.recv(1<<20)\n if not b: break\n d+=b\n'
                  'line,_,rest=d.partition(b"\\n")\n'
                  'n=json.loads(line or b"{}").get("png",0)\n'
                  'while len(rest)<n:\n b=s.recv(1<<20)\n if not b: break\n rest+=b\n'
                  'sys.stdout.buffer.write(rest[:n] if n else line)')
        path = f'{self.dir}/run/caboose-display/wayland-shared-{seat}/control.sock'
        return subprocess.run(['docker', 'exec', '-u', 'caboose', self.computer, 'timeout', '20', 'python3', '-c', script,
                               path, request], capture_output=True).stdout

    def app(self, seat, label, command, phone=False, surface_seat=None):
        """An application on `seat`'s display; with `phone`, on the phone's GPU through that seat's
        sockets (its surfaces through `surface_seat`'s, to try another seat's)."""
        d = self.dir
        # The owner seat's launch environment is the phone's GPU's (the compositor writes it); the
        # agent's is the computer's, so another seat's phone sockets are named over the owner's.
        gpu = (f'. {d}/owner.env; ' if phone else '')
        sockets = (f'export CABOOSE_GFXSTREAM_SOCKET={d}/run/caboose-gpu/{seat}/gpu.sock '
                   f'CABOOSE_GFXSTREAM_SURFACE_SOCKET={d}/run/caboose-gpu/{surface_seat or seat}/surface.sock; ') if phone else ''
        self.sh(f'. {d}/env; set -a; {gpu}. {d}/{seat}.env; set +a; {sockets}exec {command} > {d}/{label}.log 2>&1',
                user='caboose', detach=True)

    def windows(self, seat):
        try: return json.loads(self.control(seat, 'windows') or b'{}').get('windows', [])
        except ValueError: return []

    def picture(self, seat, window):
        """Whether a screenshot of `window` on `seat` has a picture (not one flat colour)."""
        data = self.control(seat, f'screenshot {window}')
        if not data.startswith(b'\x89PNG'): return False
        # Decode the PNG's pixels just enough to tell one flat colour from a picture.
        chunks, pos, width = [], 8, 0
        while pos < len(data):
            length, kind = struct.unpack('>I4s', data[pos:pos + 8])
            body = data[pos + 8:pos + 8 + length]
            if kind == b'IHDR': width = struct.unpack('>I', body[:4])[0]
            if kind == b'IDAT': chunks.append(body)
            pos += 12 + length
        raw = zlib.decompress(b''.join(chunks))
        return len(set(raw[i:i + 4] for i in range(1, min(len(raw), width * 4 * 200), 97))) > 4

    def executor(self):
        o = self.o
        token = self.sh(f'cat {self.dir}/token').strip()
        run('docker', 'run', '-d', '--name', self.executor_name, '--init', '--network', f'container:{self.computer}',
            '--cpus', '4', '--memory', '4g', '-v', f'{o.work}/build:/build:ro', '-v', f'{o.repo}/guest/gpu:/repo/guest/gpu:ro',
            '-v', f'{HERE}:/repo/apps/ios/GPUStream/gfxstream/linux-executor:ro', '--entrypoint', 'sh', 'caboose-linux-executor', '-c',
            f"printf %s '{token}' > /tmp/token; exec python3 -u /repo/apps/ios/GPUStream/gfxstream/linux-executor/executor.py "
            f"--connect 127.0.0.1:{o.port} --token-file /tmp/token --library /build/libcaboose_gpu_executor.so --features {PHONE}")

    def stop(self):
        run('docker', 'rm', '-f', self.executor_name, check=False)
        self.sh(f"pkill -u caboose -f '{self.dir}/' ; sleep 1; pkill -KILL -u caboose -f '{self.dir}/'", check=False)
        if not self.o.keep:
            self.sh(f'rm -rf {self.dir}', check=False)

    def main(self):
        d = self.dir
        try:
            self.start()
            broker = self.log('broker.log')
            self.require('seat=owner' in broker and 'seat=agent' in broker, 'both compositors joined their own seat')
            # No executor: the agent seat draws on the computer.
            self.app('agent', 'agent-gears', 'eglgears_wayland')
            seen = self.wait(lambda: any(self.windows('agent')), 20)
            window = (self.windows('agent') or [{}])[0].get('id')
            self.require(seen and window is not None and self.wait(lambda: self.picture('agent', window), 20),
                         'with no executor the agent seat renders on the computer')
            self.executor()
            self.require(self.wait(lambda: self.exists(f'{d}/run/caboose-gpu/agent/gpu.sock') and
                                   self.exists(f'{d}/run/caboose-gpu/owner/gpu.sock'), 60),
                         "the executor connected to the broker itself and made each seat's sockets")
            # A phone's view of the owner seat, which a window binds for.
            self.sh(f'exec /usr/local/bin/caboose-display-probe --url ws://127.0.0.1:{self.o.port + 1}/ --token-file {d}/token '
                    f'--duration 100000 --display 1280x800@60x1 --children > {d}/viewer.log 2>&1', user='caboose', detach=True)
            time.sleep(3)
            self.app('owner', 'owner-gears', 'glxgears -geometry 320x240', phone=True)
            self.app('agent', 'agent-phone', 'glxgears', phone=True)
            self.require(self.wait(lambda: 'presented=' in self.log('broker.log') and
                                   any(int(x) > 0 for x in __import__('re').findall(r'presented=(\d+)', self.log('broker.log'))), 60),
                         'an owner-seat application presents through the executor')
            self.require(self.wait(lambda: 'refused the agent seat a bind' in self.log('broker.log'), 30),
                         'an agent-seat bind is refused by an executor that does not route by seat')
            # A process whose stream reached the owner's socket offers its surface on the agent's.
            self.app('owner', 'crossing', 'glxgears', phone=True, surface_seat='agent')
            self.require(self.wait(lambda: 'refused a cross-seat surface' in self.log('broker.log'), 30),
                         "a process on the owner's stream socket is refused a surface on the agent's")
        finally:
            for name in ('broker.log', 'owner.log', 'agent.log'):
                text = self.log(name)
                print(f'--- {name} (last lines)\n' + '\n'.join(text.splitlines()[-15:]), flush=True)
            self.stop()
        print('FAIL' if self.failures else 'PASS shared broker', flush=True)
        return 1 if self.failures else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('computer'); parser.add_argument('work'); parser.add_argument('repo')
    parser.add_argument('--port', type=int, default=14781, help='the broker; the compositors take the next two')
    parser.add_argument('--xdisplay', type=int, default=241)
    parser.add_argument('--keep', action='store_true', help='keep the check directory')
    o = parser.parse_args()
    o.work, o.repo = os.path.abspath(o.work), os.path.abspath(o.repo)
    return Check(o).main()


if __name__ == '__main__':
    sys.exit(main())
