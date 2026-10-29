#!/usr/bin/python3
"""Prepare a disposable template guest and reset a fenced restored child."""
import fcntl
import os
import pathlib
import re
import select
import socket
import subprocess
import sys
import time

READY = pathlib.Path('/run/caboose-template-ready')
INITIALIZED = pathlib.Path('/run/caboose-template-initialized')
RNDRESEEDCRNG = 0x5207


def run(*args):
    subprocess.run(args, check=True, timeout=60)


def template_boot():
    # This switch is supplied only to an isolated, disposable template builder.
    # It prevents this destructive preparation on ordinary Caboose computers.
    command_line = pathlib.Path('/proc/cmdline').read_text().split()
    if 'caboose.template=1' not in command_line or 'systemd.unit=caboose-template.target' not in command_line:
        raise RuntimeError('Not a disposable template guest booted directly into isolation')


def user_processes():
    result = []
    for status in pathlib.Path('/proc').glob('[0-9]*/status'):
        try:
            match = re.search(r'^Uid:\s+(\d+)\s+(\d+)', status.read_text(), re.MULTILINE)
            if match and int(match.group(2)) >= 1000:
                result.append(status.parent.name)
        except FileNotFoundError:
            pass
    return result


def prepare():
    template_boot()
    # Isolate a target that retains only the private host agent and its bridge.
    # If any non-root process survives, refuse to snapshot.
    run('systemctl', 'isolate', 'caboose-template.target')
    processes = user_processes()
    if processes:
        raise RuntimeError('User processes remain after template isolation')
    READY.write_text('prepared\n')
    os.sync()


def hardware_random(size):
    fd = os.open('/dev/hwrng', os.O_RDONLY | os.O_NONBLOCK | os.O_CLOEXEC)
    try:
        result = bytearray()
        deadline = time.monotonic() + 10
        while len(result) < size:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RuntimeError('Hardware entropy unavailable')
            readable, _, _ = select.select([fd], [], [], remaining)
            if not readable:
                raise RuntimeError('Hardware entropy unavailable')
            try:
                part = os.read(fd, size - len(result))
            except BlockingIOError:
                continue
            if not part:
                raise RuntimeError('Hardware entropy ended')
            result.extend(part)
        return bytes(result)
    finally:
        os.close(fd)


def check_vsock(cid):
    if not 3 <= cid <= 0xfffffffe:
        raise RuntimeError('Invalid child vsock CID')
    with open('/dev/vsock', 'rb', buffering=0) as vsock:
        actual = bytearray(4)
        fcntl.ioctl(vsock.fileno(), 0x7b9, actual, True)
        if int.from_bytes(actual, sys.byteorder) != cid:
            raise RuntimeError('Guest vsock identity does not match the child')


def refresh_vsock():
    template_boot()
    if READY.read_text() != 'prepared\n':
        raise RuntimeError('Guest was not prepared for template restore')
    # Rebinding disconnects the host's current channel. Schedule it separately
    # so the request can return before that channel is interrupted.
    run('systemd-run', '--unit=caboose-template-vsock-refresh', '--on-active=5s',
        '/usr/bin/python3', '/usr/local/libexec/caboose-template', 'refresh-vsock-worker')


def rebind_driver(name, driver_root=pathlib.Path('/sys/bus/virtio/drivers')):
    driver = driver_root / name
    devices = [p.name for p in driver.glob('virtio[0-9]*')]
    if len(devices) != 1:
        raise RuntimeError(f'Expected exactly one {name} device')
    (driver / 'unbind').write_text(devices[0])
    (driver / 'bind').write_text(devices[0])


def refresh_vsock_worker():
    template_boot()
    if READY.read_text() != 'prepared\n':
        raise RuntimeError('Guest was not prepared for template restore')
    rebind_driver('vmw_vsock_virtio_transport')
    run('systemctl', 'restart', 'desk-vsock-bridge.service')


def reinitialize(mac, cid):
    template_boot()
    if READY.read_text() != 'prepared\n':
        raise RuntimeError('Guest was not prepared for template restore')
    if user_processes():
        raise RuntimeError('User process running during identity reset')
    if not re.fullmatch(r'(?:[0-9a-f]{2}:){5}[0-9a-f]{2}', mac) or int(mac[:2], 16) & 1:
        raise RuntimeError('Invalid child MAC')
    check_vsock(cid)
    # The restored virtio-rng driver may contain bytes cached before the
    # snapshot. Reprobe it to discard those bytes and request fresh host data.
    rebind_driver('virtio_rng')
    rng_current = pathlib.Path('/sys/class/misc/hw_random/rng_current')
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        try:
            if rng_current.read_text().strip().startswith('virtio_rng.'):
                break
        except FileNotFoundError:
            pass
        time.sleep(0.1)
    else:
        raise RuntimeError('Fresh virtio entropy source is unavailable')
    entropy = hardware_random(80)
    fd = os.open('/dev/urandom', os.O_WRONLY | os.O_CLOEXEC)
    try:
        seed = memoryview(entropy[:64])
        while seed:
            written = os.write(fd, seed)
            if not written:
                raise RuntimeError('Could not mix hardware entropy')
            seed = seed[written:]
        fcntl.ioctl(fd, RNDRESEEDCRNG)
    finally:
        os.close(fd)
    machine_id = entropy[64:].hex()
    machine_file = pathlib.Path('/etc/machine-id')
    if machine_file.read_text().strip() == machine_id:
        raise RuntimeError('Fresh machine identity matches the template')
    temp = machine_file.with_name('.machine-id.caboose-template')
    temp.write_text(machine_id + '\n')
    os.chmod(temp, 0o444)
    os.replace(temp, machine_file)
    dbus_machine_file = pathlib.Path('/var/lib/dbus/machine-id')
    if dbus_machine_file.exists() and not dbus_machine_file.is_symlink():
        dbus_temp = dbus_machine_file.with_name('.machine-id.caboose-template')
        dbus_temp.write_text(machine_id + '\n')
        os.chmod(dbus_temp, 0o444)
        os.replace(dbus_temp, dbus_machine_file)
    hostname = 'caboose-' + machine_id[:12]
    pathlib.Path('/etc/hostname').write_text(hostname + '\n')
    run('hostname', hostname)
    # Remove the old saved seed: it must never seed a later boot of the child.
    pathlib.Path('/var/lib/systemd/random-seed').unlink(missing_ok=True)
    interfaces = [path.name for path in pathlib.Path('/sys/class/net').iterdir() if path.name.startswith(('en', 'eth'))]
    if len(interfaces) != 1:
        raise RuntimeError('Expected exactly one guest network interface')
    run('ip', 'link', 'set', 'dev', interfaces[0], 'down')
    run('ip', 'link', 'set', 'dev', interfaces[0], 'address', mac)
    run('ip', 'link', 'set', 'dev', interfaces[0], 'up')
    if (pathlib.Path('/sys/class/net') / interfaces[0] / 'address').read_text().strip().lower() != mac:
        raise RuntimeError('Guest MAC did not change')
    # An SSH server must not retain the source's host private keys.
    ssh = pathlib.Path('/etc/ssh')
    for key in ssh.glob('ssh_host_*_key*'):
        key.unlink()
    if pathlib.Path('/usr/bin/ssh-keygen').exists():
        run('/usr/bin/ssh-keygen', '-A')
    if machine_file.read_text().strip() != machine_id:
        raise RuntimeError('Guest machine identity did not persist')
    if dbus_machine_file.exists() and dbus_machine_file.read_text().strip() != machine_id:
        raise RuntimeError('D-Bus machine identity did not change')
    check_vsock(cid)
    # A bus that was already started by system management may have cached the
    # source machine ID. Restart it before user services can connect.
    bus = subprocess.run(['systemctl', 'is-active', '--quiet', 'dbus.service'], timeout=5)
    if bus.returncode == 0:
        run('systemctl', 'restart', 'dbus.service')
        probe = subprocess.run(['busctl', '--system', 'call', 'org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus.Peer', 'GetMachineId'], timeout=10, check=True, capture_output=True, text=True)
        if machine_id not in probe.stdout:
            raise RuntimeError('D-Bus retained the template machine identity')
    INITIALIZED.write_text('initialized\n')
    READY.unlink()
    os.sync()


def agent_identity():
    result = subprocess.run(['systemctl', 'show', '--property=MainPID', '--value', 'desk-guest-agent.service'], timeout=5, check=True, capture_output=True, text=True)
    pid = int(result.stdout.strip())
    if pid < 2:
        raise RuntimeError('Private guest agent is not running')
    fields = pathlib.Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
    return f'{pid}:{fields[19]}'


def restart_agent():
    template_boot()
    if INITIALIZED.read_text() != 'initialized\n':
        raise RuntimeError('Guest identity has not been reinitialized')
    previous = agent_identity()
    # Restart asynchronously so the request returns before its channel closes.
    run('systemd-run', '--unit=caboose-template-agent-restart', '--on-active=5s',
        '/usr/bin/python3', '/usr/local/libexec/caboose-template', 'restart-agent-worker')
    print(previous)


def restart_agent_worker():
    template_boot()
    if INITIALIZED.read_text() != 'initialized\n':
        raise RuntimeError('Guest identity has not been reinitialized')
    run('systemctl', 'restart', 'desk-guest-agent.service', 'desk-vsock-bridge.service')


def check_agent(previous):
    if not re.fullmatch(r'[0-9]+:[0-9]+', previous):
        raise RuntimeError('Invalid prior agent identity')
    if agent_identity() == previous:
        raise RuntimeError('Private guest agent has not restarted')


def activate():
    template_boot()
    if INITIALIZED.read_text() != 'initialized\n':
        raise RuntimeError('Guest identity has not been reinitialized')
    # Start the normal target without isolating away the private control
    # channel. The host remains fenced until systemd reports it active.
    # The host configures the TAP directly; networkd does not manage it.
    # Its wait-online service would otherwise block network-online forever.
    run('systemctl', 'mask', '--runtime', 'systemd-networkd-wait-online.service')
    run('systemctl', 'start', '--no-block', 'multi-user.target', 'caboose-vsock-services.service', 'caboose-files.service', 'caboose-terminal.service')
    deadline = time.monotonic() + 60
    units = ['desk-guest-agent.service', 'desk-vsock-bridge.service', 'caboose-vsock-services.service', 'caboose-files.service', 'caboose-terminal.service']
    missing = []
    while time.monotonic() < deadline:
        missing = []
        for unit in units:
            state = subprocess.run(['systemctl', 'is-active', unit], timeout=5, capture_output=True, text=True)
            if state.returncode != 0:
                missing.append(f'{unit}={state.stdout.strip() or "unknown"}')
        for port in (14700, 14701):
            try:
                with socket.create_connection(('127.0.0.1', port), timeout=2):
                    pass
            except OSError:
                missing.append(f'127.0.0.1:{port}=unavailable')
        if not missing:
            INITIALIZED.unlink()
            return
        time.sleep(0.5)
    jobs = subprocess.run(['systemctl', 'list-jobs', '--no-legend', '--no-pager'], timeout=5, capture_output=True, text=True).stdout.strip()
    raise RuntimeError('Normal guest services did not become ready: ' + ', '.join(missing) + '; jobs: ' + (jobs or 'none'))


if __name__ == '__main__':
    try:
        if sys.argv[1:] == ['prepare']:
            prepare()
        elif sys.argv[1:] == ['activate']:
            activate()
        elif sys.argv[1:] == ['restart-agent']:
            restart_agent()
        elif sys.argv[1:] == ['restart-agent-worker']:
            restart_agent_worker()
        elif len(sys.argv) == 3 and sys.argv[1] == 'check-agent':
            check_agent(sys.argv[2])
        elif sys.argv[1:] == ['refresh-vsock']:
            refresh_vsock()
        elif sys.argv[1:] == ['refresh-vsock-worker']:
            refresh_vsock_worker()
        elif len(sys.argv) == 3 and sys.argv[1] == 'check-vsock':
            check_vsock(int(sys.argv[2]))
        elif len(sys.argv) == 4 and sys.argv[1] == 'reinitialize':
            reinitialize(sys.argv[2].lower(), int(sys.argv[3]))
        else:
            raise RuntimeError('Usage: caboose-template prepare | reinitialize MAC CID | activate')
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        print(f'Template preparation failed: {error}', file=sys.stderr)
        sys.exit(1)
