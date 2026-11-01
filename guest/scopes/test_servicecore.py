"""servicecore: unit files, dependency order, restarts and listening sockets.

    python3 -m unittest discover -s guest/scopes -p 'test_*.py'
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import servicecore as units  # noqa: E402

POSTGRES = """# A database
[Unit]
Description=PostgreSQL
After=network.service

[Service]
ExecStart=/usr/lib/postgresql/17/bin/postgres -D "/var/lib/postgresql/17/main"
User=postgres
Environment=PGTZ=UTC LANG=C.UTF-8
Environment="PGOPTIONS=-c work_mem=64MB"
Restart=always
RestartSec=500ms
TimeoutStopSec=1min

[Install]
WantedBy=multi-user.target
"""


def unit(requires=(), after=(), restart='on-failure', kind='simple'):
    return {'requires': list(requires), 'after': list(after), 'restart': restart, 'type': kind}


class Units(unittest.TestCase):
    def test_parses_the_systemd_subset(self):
        parsed = units.parse_unit('postgres', POSTGRES, system=True)
        self.assertEqual(parsed['description'], 'PostgreSQL')
        self.assertEqual(parsed['argv'], ['/usr/lib/postgresql/17/bin/postgres', '-D', '/var/lib/postgresql/17/main'])
        self.assertEqual(parsed['user'], 'postgres')
        self.assertEqual(parsed['environment'], {'PGTZ': 'UTC', 'LANG': 'C.UTF-8', 'PGOPTIONS': '-c work_mem=64MB'})
        self.assertEqual((parsed['restart'], parsed['restartSec'], parsed['stopSec']), ('always', 0.5, 60.0))
        self.assertEqual(parsed['after'], ['network'])
        self.assertTrue(parsed['autostart'])

    def test_defaults(self):
        parsed = units.parse_unit('dev', '[Service]\nExecStart=npm run dev\n', system=False)
        self.assertEqual((parsed['type'], parsed['restart'], parsed['restartSec'], parsed['stopSec']), ('simple', 'on-failure', 2.0, 10.0))
        self.assertEqual((parsed['user'], parsed['directory'], parsed['autostart'], parsed['description']), (None, None, False, 'dev'))

    def test_refuses_what_it_cannot_honour(self):
        bad = {
            'no service': '[Unit]\nDescription=x\n',
            'no command': '[Service]\nExecStart=\n',
            'bad type': '[Service]\nExecStart=x\nType=notify\n',
            'bad restart': '[Service]\nExecStart=x\nRestart=sometimes\n',
            'relative directory': '[Service]\nExecStart=x\nWorkingDirectory=src\n',
            'bad env': '[Service]\nExecStart=x\nEnvironment=1X=2\n',
            'bad duration': '[Service]\nExecStart=x\nRestartSec=soon\n',
            'bad dependency': '[Unit]\nRequires=../x\n[Service]\nExecStart=x\n',
            'unbalanced quote': '[Service]\nExecStart=echo "x\n',
        }
        for label, text in bad.items():
            with self.assertRaises(units.UnitError, msg=label):
                units.parse_unit('x', text, system=True)
        with self.assertRaises(units.UnitError):
            units.parse_unit('x', '[Service]\nExecStart=x\nUser=root\n', system=False)
        with self.assertRaises(units.UnitError):
            units.parse_unit('../x', '[Service]\nExecStart=x\n', system=True)

    def test_names(self):
        self.assertTrue(units.valid_name('postgres'))
        self.assertTrue(units.valid_name('my-app@2.dev'))
        for bad in ('', '-x', 'a/b', 'x.service', 'x' * 65, 'a b'):
            self.assertFalse(units.valid_name(bad), bad)

    def test_renders_a_definition_that_parses_back(self):
        text = units.render_unit({'description': 'Dev server', 'command': ['npm', 'run', 'dev', '--', "it's"],
                                  'workingDirectory': '/home/caboose/app', 'environment': {'PORT': '3000', 'NOTE': 'a b'},
                                  'restart': 'always', 'autostart': True, 'requires': ['postgres']})
        parsed = units.parse_unit('dev', text, system=False)
        self.assertEqual(parsed['argv'], ['npm', 'run', 'dev', '--', "it's"])
        self.assertEqual(parsed['environment'], {'PORT': '3000', 'NOTE': 'a b'})
        self.assertEqual((parsed['directory'], parsed['restart'], parsed['autostart'], parsed['requires']),
                         ('/home/caboose/app', 'always', True, ['postgres']))

    def test_refuses_bad_definitions(self):
        for definition in ({}, {'command': []}, {'command': ['a\nb']}, {'command': ['x'], 'extra': 1},
                           {'command': ['x'], 'workingDirectory': 'rel'}, {'command': ['x'], 'restart': 'never'},
                           {'command': ['x'], 'environment': {'A-B': '1'}}, {'command': ['x'], 'autostart': 'yes'},
                           {'command': ['x'], 'requires': ['../x']}, {'command': ['x'], 'description': 'a\nb'}, 'x'):
            with self.assertRaises(units.UnitError, msg=repr(definition)):
                units.render_unit(definition)

    def test_autostart_rewrites_only_the_install_section(self):
        text = '[Service]\nExecStart=x\n'
        enabled = units.set_autostart(text, True)
        self.assertTrue(units.parse_unit('x', enabled, system=False)['autostart'])
        self.assertIn('ExecStart=x', enabled)
        disabled = units.set_autostart(POSTGRES, False)
        self.assertFalse(units.parse_unit('p', disabled, system=True)['autostart'])
        self.assertIn('# A database', disabled)
        self.assertEqual(units.set_autostart(units.set_autostart(text, True), True).count('WantedBy'), 1)


class Order(unittest.TestCase):
    def test_dependencies_first(self):
        services = {'web': unit(['db']), 'db': unit(), 'worker': unit(after=['web']), 'lone': unit()}
        self.assertEqual(units.start_order(services, ['worker', 'web']), (['db', 'web', 'worker'], []))
        self.assertEqual(units.start_order(services, ['worker']), (['worker'], []))

    def test_cycles_and_missing_dependencies_fail_alone(self):
        services = {'a': unit(['b']), 'b': unit(['a']), 'c': unit(), 'd': unit(['gone'])}
        self.assertEqual(units.start_order(services, ['a', 'c', 'd']), (['c'], ['a', 'b', 'd', 'gone']))

    def test_dependents_stop_first(self):
        services = {'web': unit(['db']), 'db': unit(), 'worker': unit(['web']), 'lone': unit()}
        self.assertEqual(units.dependents(services, 'db'), ['web', 'worker'])


class Restarts(unittest.TestCase):
    def test_policies(self):
        self.assertEqual(units.restart_decision(unit(restart='on-failure'), 1, False, [0], 100), 'restart')
        self.assertEqual(units.restart_decision(unit(restart='on-failure'), 0, False, [0], 100), 'stop')
        self.assertEqual(units.restart_decision(unit(restart='on-failure'), None, False, [0], 100), 'restart')
        self.assertEqual(units.restart_decision(unit(restart='always'), 0, False, [0], 100), 'restart')
        self.assertEqual(units.restart_decision(unit(restart='no'), 1, False, [0], 100), 'fail')
        self.assertEqual(units.restart_decision(unit(restart='no'), 0, False, [0], 100), 'stop')
        self.assertEqual(units.restart_decision(unit(restart='always'), -9, True, [0], 100), 'stop')
        self.assertEqual(units.restart_decision(unit(restart='always', kind='oneshot'), 0, False, [0], 100), 'stop')

    def test_a_crash_loop_stops_restarting(self):
        starts = [100, 110, 120, 130, 140]
        self.assertEqual(units.restart_decision(unit(), 1, False, starts, 150), 'fail')
        self.assertEqual(units.restart_decision(unit(), 1, False, starts, 165), 'restart')


class Sockets(unittest.TestCase):
    TCP = """  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 00000000:1538 00000000:0000 0A 00000000:00000000 00:00000000 00000000   999        0 4242 1
   1: 0100007F:0BB8 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 4343 1
   2: 0200A8C0:1538 0A00A8C0:D431 01 00000000:00000000 00:00000000 00000000   999        0 4444 1
   3: 0100007F:1538 0100007F:D432 01 00000000:00000000 00:00000000 00000000   999        0 4545 1
"""
    TCP6 = """  sl  local_address                         remote_address                        st
   0: 00000000000000000000000000000000:0050 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000 0 77 1
   1: 0000000000000000FFFF00000100007F:1F90 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  1000 0 78 1
   2: 00000000000000000000000001000000:0016 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000  0 0 79 1
"""
    UDP = """  sl  local_address rem_address   st
   0: 00000000:14E9 00000000:0000 07 00000000:00000000 00:00000000 00000000  1000 0 90 2
   1: 0200A8C0:14EA 0100000A:0035 01 00000000:00000000 00:00000000 00000000  1000 0 91 2
"""

    def test_listeners(self):
        self.assertEqual(units.listening(self.TCP, 'tcp', 4), [('tcp', '0.0.0.0', 5432, 4242), ('tcp', '127.0.0.1', 3000, 4343)])
        self.assertEqual(units.listening(self.TCP6, 'tcp', 6), [('tcp', '::', 80, 77), ('tcp', '127.0.0.1', 8080, 78), ('tcp', '::1', 22, 79)])
        self.assertEqual(units.listening(self.UDP, 'udp', 4), [('udp', '0.0.0.0', 5353, 90)])

    def test_connections_and_loopback(self):
        self.assertEqual(units.established(self.TCP, 4), [(5432, '192.168.0.10'), (5432, '127.0.0.1')])
        self.assertTrue(units.loopback('127.0.0.1'))
        self.assertTrue(units.loopback('::1'))
        self.assertFalse(units.loopback('192.168.0.10'))

    def test_socket_inodes(self):
        self.assertEqual(units.socket_inodes(['socket:[12]', '/dev/null', 'pipe:[3]', 'socket:[9]']), {12, 9})


if __name__ == '__main__':
    unittest.main()
