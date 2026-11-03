#!/usr/bin/env python3
"""Start an application on the agent seat with its runtime's accessibility switched on.

usage: launcher.py COMMAND

COMMAND is one shell command line, as desktop MCP's launch takes it. A plain command (no
pipes, lists or redirections) runs directly; anything else runs under /bin/sh unchanged.
Chromium and Electron build their whole accessibility tree only when started with
--force-renderer-accessibility, so a program on that runtime gets the switch: recognised by
the runtime's own files beside its executable (resources.pak, v8_context_snapshot.bin),
following wrapper scripts (the programs and directories they name), or for `flatpak run` by
an Electron base application. Java programs get the ATK wrapper, where it is installed. Every
other program starts as asked."""
import os
import re
import shlex
import shutil
import subprocess
import sys

SWITCH = '--force-renderer-accessibility'
MARKERS = ('resources.pak', 'v8_context_snapshot.bin', 'chrome_100_percent.pak')


def chromium_runtime(path, depth=0):
    """Whether `path` (an executable, or a script that runs one) is a Chromium build."""
    real = os.path.realpath(path)
    if not os.path.isfile(real) or depth > 3:
        return False
    if any(os.path.exists(os.path.join(os.path.dirname(real), m)) for m in MARKERS):
        return True
    try:
        with open(real, 'rb') as f:
            head = f.read(65536)
    except OSError:
        return False
    if not head.startswith(b'#!'):
        return False
    # A wrapper script: the programs it names by absolute path, and variables it builds them from.
    text = head.decode('utf-8', 'replace')
    for candidate in re.findall(r'(/[\w.+@-]+(?:/[\w.+@-]+)+)', text):
        if os.path.isdir(candidate) and any(os.path.exists(os.path.join(candidate, m)) for m in MARKERS):
            return True  # the directory it runs its program from (LIBDIR=/usr/lib/chromium)
        if candidate != real and os.access(candidate, os.X_OK) and chromium_runtime(candidate, depth + 1):
            return True
    return False


def flatpak_electron(app):
    try:
        info = subprocess.run(['flatpak', 'info', '--show-metadata', app], capture_output=True, text=True, timeout=10).stdout
    except (OSError, subprocess.TimeoutExpired):
        return False
    return 'org.electronjs.Electron2.BaseApp' in info or 'org.chromium.Chromium.BaseApp' in info


def plan(command):
    """The argv to run, or None for /bin/sh -c COMMAND."""
    if re.search(r'[|&;<>()`$]', command):
        return None
    try:
        argv = shlex.split(command)
    except ValueError:
        return None
    if not argv:
        return None
    if SWITCH in argv:
        return argv
    if os.path.basename(argv[0]) == 'flatpak' and 'run' in argv:
        at = argv.index('run') + 1
        while at < len(argv) and argv[at].startswith('-'):
            at += 1
        if at < len(argv) and flatpak_electron(argv[at]):
            return argv[:at + 1] + [SWITCH] + argv[at + 1:]
        return argv
    program = shutil.which(argv[0])
    if program and chromium_runtime(program):
        return [argv[0], SWITCH] + argv[1:]
    return argv


ATK_WRAPPER = '/usr/share/java/java-atk-wrapper.jar'


def java_accessibility(environ):
    """Java Swing and AWT reach AT-SPI through the ATK wrapper, which a JRE loads only when told
    to and finds only on its boot class path: added for every program started, where installed."""
    if not os.path.exists(ATK_WRAPPER):
        return environ
    options = environ.get('JAVA_TOOL_OPTIONS', '')
    if 'AtkWrapper' in options:
        return environ
    return {**environ, 'JAVA_TOOL_OPTIONS': f'{options} -Djavax.accessibility.assistive_technologies=org.GNOME.Accessibility.AtkWrapper '
            f'-Xbootclasspath/a:{ATK_WRAPPER}'.strip()}


if __name__ == '__main__':
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    os.environ.update(java_accessibility(dict(os.environ)))
    argv = plan(sys.argv[1])
    if argv is None:
        os.execv('/bin/sh', ['/bin/sh', '-c', sys.argv[1]])
    try:
        os.execvp(argv[0], argv)
    except OSError as error:
        sys.exit(f'{argv[0]}: {error.strerror}')
