"""Exercise the real installer's dependency phase with isolated shell commands."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


INSTALLER = Path(__file__).with_name('install.sh')
COMMAND = '''#!/bin/bash
set -eu
command=${0##*/}
printf '%s' "$command" >> "$FIXTURE/calls"
printf ' %s' "$@" >> "$FIXTURE/calls"
printf '\\n' >> "$FIXTURE/calls"
case "$command" in
  node) [ -f "$FIXTURE/node-ok" ] ;;
  npm) [ -f "$FIXTURE/node-ok" ] && [ -f "$FIXTURE/npm-ok" ] ;;
  dpkg-query)
    for pkg; do :; done
    [ "$pkg" != "${MISSING_PACKAGE:-}" ] || exit 1
    # NodeSource has nodejs installed, but no separate npm package.
    [ "$pkg" != npm ] || exit 1
    printf installed ;;
  dpkg) exit 0 ;;
  apt-get)
    [ "${FAIL_APT:-}" != "$1" ] || { echo 'fixture apt failure' >&2; exit 1; }
    [ "$1" = install ] || exit 0
    for pkg; do
      case "$pkg" in
        nodejs)
          [ "${BROKEN_INSTALL:-}" != nodejs ] || continue
          : > "$FIXTURE/node-ok"
          [ -e "$FIXTURE/bin/node" ] || /bin/ln -s ../command "$FIXTURE/bin/node"
          if [ "${BUNDLED_NPM:-}" = yes ]; then
            : > "$FIXTURE/npm-ok"
            [ -e "$FIXTURE/bin/npm" ] || /bin/ln -s ../command "$FIXTURE/bin/npm"
          fi ;;
        npm)
          [ "${BROKEN_INSTALL:-}" != npm ] || continue
          : > "$FIXTURE/npm-ok"
          [ -e "$FIXTURE/bin/npm" ] || /bin/ln -s ../command "$FIXTURE/bin/npm" ;;
      esac
    done ;;
  # Stop at the first system-file write. No privileged operations can run.
  install) exit 73 ;;
  *) exit 99 ;;
esac
'''


class Dependencies(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        (self.root / 'command').write_text(COMMAND)
        (self.root / 'command').chmod(0o755)
        for name in ('node', 'npm', 'dpkg-query', 'dpkg', 'apt-get', 'install'):
            (self.bin / name).symlink_to('../command')
        for name in ('dirname', 'mktemp', 'rm', 'tail'):
            (self.bin / name).symlink_to(shutil.which(name))
        self.env = {**os.environ, 'PATH': str(self.bin), 'FIXTURE': str(self.root)}
        for name in ('BASH_ENV', 'MISSING_PACKAGE', 'FAIL_APT', 'BROKEN_INSTALL', 'BUNDLED_NPM'):
            self.env.pop(name, None)

    def runtime(self, node=True, npm=True):
        for name, usable in (('node', node), ('npm', npm)):
            if usable:
                (self.root / f'{name}-ok').touch()

    def run_installer(self, expected=73, mode='image-container', **env):
        (self.root / 'calls').write_text('')
        result = subprocess.run(['/bin/bash', str(INSTALLER), mode],
                                env={**self.env, **env}, capture_output=True, text=True)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        calls = (self.root / 'calls').read_text().splitlines()
        if expected != 73:
            self.assertFalse(any(line.startswith('install ') for line in calls), calls)
        return calls, result.stderr

    def apt_installs(self, calls):
        return [line.split()[4:] for line in calls if line.startswith('apt-get install ')]

    def test_bundled_npm_is_preserved_in_every_mode(self):
        self.runtime()
        for mode in ('image-vm', 'image-container', 'vm', 'container'):
            with self.subTest(mode=mode):
                calls, _ = self.run_installer(mode=mode)
                self.assertFalse(any(line.startswith(('apt-get ', 'dpkg ')) for line in calls), calls)

    def test_other_missing_packages_do_not_replace_working_runtime(self):
        self.runtime()
        calls, _ = self.run_installer(MISSING_PACKAGE='cups')
        self.assertEqual(self.apt_installs(calls), [['cups']])

    def test_missing_runtime_installs_node_then_separate_npm(self):
        self.runtime(False, False)
        for name in ('node', 'npm'):
            (self.bin / name).unlink()
        calls, _ = self.run_installer()
        self.assertEqual(self.apt_installs(calls), [['nodejs'], ['npm']])
        calls, _ = self.run_installer()
        self.assertEqual(self.apt_installs(calls), [])

    def test_new_node_package_can_supply_bundled_npm(self):
        self.runtime(False, False)
        calls, _ = self.run_installer(BUNDLED_NPM='yes')
        self.assertEqual(self.apt_installs(calls), [['nodejs']])

    def test_existing_npm_becomes_usable_when_node_is_installed(self):
        self.runtime(False, True)
        calls, _ = self.run_installer()
        self.assertEqual(self.apt_installs(calls), [['nodejs']])

    def test_broken_npm_is_installed_without_replacing_working_node(self):
        self.runtime(True, False)
        calls, _ = self.run_installer()
        self.assertEqual(self.apt_installs(calls), [['npm']])

    def test_missing_npm_is_installed_without_replacing_working_node(self):
        self.runtime(True, False)
        (self.bin / 'npm').unlink()
        calls, _ = self.run_installer()
        self.assertEqual(self.apt_installs(calls), [['npm']])

    def test_apt_failure_stops_before_system_files(self):
        self.runtime(False, False)
        for stage in ('update', 'install'):
            with self.subTest(stage=stage):
                _, error = self.run_installer(expected=1, FAIL_APT=stage)
                self.assertIn('fixture apt failure', error)

    def test_unusable_commands_after_install_stop_before_system_files(self):
        self.runtime(False, False)
        _, error = self.run_installer(expected=1, BROKEN_INSTALL='nodejs')
        self.assertIn('require working node and npm', error)

    def test_unusable_npm_after_install_stops_before_system_files(self):
        self.runtime(True, False)
        _, error = self.run_installer(expected=1, BROKEN_INSTALL='npm')
        self.assertIn('require working node and npm', error)


if __name__ == '__main__':
    unittest.main()
