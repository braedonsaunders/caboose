#!/usr/bin/python3
"""Acceptance-only Apps launcher. Does not start a compositor or a phone executor."""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import socket
import stat
import struct
import subprocess
import sys

RUNTIME = Path('/run/user/1000')
GPU = RUNTIME / 'caboose-gpu-acceptance'
BUNDLE = Path('/fixture/bundle')
ICD = Path('/fixture/icd.json')
COMPOSITOR = Path('/opt/caboose-private-gpu-v4/bin/caboose-display')
CONFIG = Path('/opt/caboose-gpu-acceptance/runtime.json')
GAME_SHA = '8785da3046d4a03d69d014baf17e258de5180698bc303389784ef138a9066fe9'
LAUNCH_SHA = '90a644c02fd85874169d9ec215000f7de6ec186db68184d3fb53b63989a5f838'
DRIVER_SHA = '17f439c618e65cda6a0e6f88cc3581b6543403a1693db5c699c7479e63e9e998'


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def digest(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()


def game_environment(inherited, library_directory):
    environment = dict(inherited)
    require(library_directory is None or (isinstance(library_directory, str)
            and library_directory.startswith('/') and ':' not in library_directory
            and '\0' not in library_directory), 'Invalid configured game library directory.')
    selected = environment.get('CABOOSE_GAME_LIBRARY_DIR') or library_directory
    require(not environment.get('CABOOSE_GAME_LIBRARY_DIR') or
            environment['CABOOSE_GAME_LIBRARY_DIR'] == library_directory,
            'Inherited game library directory differs from runtime.json.')
    if selected:
        environment['CABOOSE_GAME_LIBRARY_DIR'] = selected
    environment.update(VK_DRIVER_FILES=str(ICD), VK_ICD_FILENAMES=str(ICD),
                       CABOOSE_GAME_BUNDLE=str(BUNDLE),
                       CABOOSE_GFXSTREAM_SOCKET=str(GPU / 'gpu.sock'),
                       CABOOSE_GFXSTREAM_SURFACE_SOCKET=str(GPU / 'surface.sock'),
                       SDL_VIDEODRIVER='wayland', SDL_AUDIODRIVER='dummy', NO_AT_BRIDGE='1')
    return environment


def loader_environment(environment):
    """Mirror verified launch.sh solely for the dependency check, without executing it."""
    result = dict(environment)
    library = result.get('CABOOSE_GAME_LIBRARY_DIR')
    if library:
        suffix = ':' + result['LD_LIBRARY_PATH'] if result.get('LD_LIBRARY_PATH') else ''
        result['LD_LIBRARY_PATH'] = library + ':' + library + '/pulseaudio' + suffix
    return result


def preflight(environment):
    require(os.getuid() == 1000, 'Launch as the computer owner.')
    require(os.environ.get('CABOOSE_SEAT') != 'agent', 'Use the owner Apps list.')
    require(os.environ.get('XDG_RUNTIME_DIR') == str(RUNTIME), 'Owner display is not ready.')
    require(os.environ.get('WAYLAND_DISPLAY') == 'wayland-caboose-0', 'Unexpected owner Wayland display.')
    directory = GPU.lstat()
    require(stat.S_ISDIR(directory.st_mode) and directory.st_uid == 1000
            and stat.S_IMODE(directory.st_mode) == 0o700, 'Private GPU directory is not owner-only.')
    for path in (GPU / 'gpu.sock', GPU / 'surface.sock', RUNTIME / 'wayland-caboose-0'):
        info = path.lstat()
        require(stat.S_ISSOCK(info.st_mode) and info.st_uid == 1000,
                'Private GPU session is not ready: ' + path.name)
    # Query the existing owner control socket; never consume a GPU stream connection.
    control = RUNTIME / 'caboose-display/wayland-caboose-0/control.sock'
    with socket.socket(socket.AF_UNIX) as connection:
        connection.settimeout(3)
        connection.connect(str(control))
        pid, uid, _ = struct.unpack('3i', connection.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
        require(uid == 1000, 'Unexpected compositor owner.')
        proc = Path('/proc') / str(pid)
        require((proc / 'exe').resolve() == COMPOSITOR, 'Owner display is not the private GPU compositor.')
        args = (proc / 'cmdline').read_bytes().split(b'\0')
        for flag, value in ((b'--private-gpu-stream-socket', GPU / 'gpu.sock'),
                            (b'--private-gpu-surface-socket', GPU / 'surface.sock')):
            require(flag in args and args.index(flag) + 1 < len(args)
                    and args[args.index(flag) + 1] == os.fsencode(value), 'Owner GPU socket configuration differs.')
        require(b'--private-gpu-indexed' in args, 'Owner GPU transport is not indexed v4.')
        connection.sendall(b'windows\n')
        response = b''
        while b'\n' not in response:
            chunk = connection.recv(4096)
            require(bool(chunk) and len(response) + len(chunk) <= 1024 * 1024, 'Invalid owner control response.')
            response += chunk
        require(json.loads(response.split(b'\n', 1)[0]).get('ok') is True, 'Owner control is not ready.')
    require(digest(BUNDLE / 'vkquake') == GAME_SHA, 'vkQuake executable differs from the verified fixture.')
    require(digest(BUNDLE / 'launch.sh') == LAUNCH_SHA, 'Bundle launcher differs from the verified manifest.')
    driver = Path(json.loads(ICD.read_text())['ICD']['library_path'])
    require(driver.is_absolute() and digest(driver) == DRIVER_SHA, 'Private Vulkan driver differs from the verified fixture.')
    require((BUNDLE / 'id1/pak0.pak').is_file() and (BUNDLE / 'id1/pak1.pak').is_file(), 'LibreQuake data is missing.')
    library = environment.get('CABOOSE_GAME_LIBRARY_DIR')
    if library:
        require(Path(library).is_dir() and (Path(library) / 'pulseaudio').is_dir(),
                'Configured private runtime library directory is incomplete.')
    # Ask the actual Linux loader to resolve the retained ELF's transitive dependencies.
    # --list does not enter vkQuake or initialize Vulkan/SDL.
    dependencies = subprocess.run(['/lib64/ld-linux-x86-64.so.2', '--list', str(BUNDLE / 'vkquake')],
                                  env=loader_environment(environment), capture_output=True,
                                  text=True, timeout=10)
    require(dependencies.returncode == 0, 'Runtime dependency resolution failed: ' + dependencies.stderr.strip())


def main():
    require(sys.argv[1:] in ([], ['--check']), 'Usage: launch.py [--check]')
    configuration = json.loads(CONFIG.read_text())
    environment = game_environment(os.environ, configuration['library_directory'])
    preflight(environment)
    if sys.argv[1:] == ['--check']:
        print('Guest launch prerequisites passed; phone GPU readiness and pixels are not verified.')
        return
    lock = os.open(GPU / 'quake.lock', os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise RuntimeError('Quake is already running.') from None
    os.set_inheritable(lock, True)
    # Retain the fixture's private SDL/Pulse dependency setup and native Wayland launch.
    os.execve('/usr/bin/stdbuf', ['stdbuf', '-oL', '-eL', str(BUNDLE / 'launch.sh'),
                                '-nosound', '+map', 'start'], environment)


if __name__ == '__main__':
    log = None
    try:
        if sys.argv[1:] != ['--check']:
            log_dir = Path.home() / '.cache/caboose'
            log_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
            log = os.open(log_dir / 'quake-gpu-acceptance.log', os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600)
            os.dup2(log, 1)
            os.dup2(log, 2)
        main()
    except (OSError, RuntimeError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired) as error:
        message = 'Quake GPU Acceptance: ' + str(error)
        print(message, file=sys.stderr, flush=True)
        if sys.argv[1:] != ['--check']:
            try:
                subprocess.run(['notify-send', 'Quake could not start', message], timeout=3, check=False)
            except (OSError, subprocess.TimeoutExpired):
                pass
        sys.exit(1)
