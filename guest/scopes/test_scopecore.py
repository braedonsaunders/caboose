"""scopecore: scope names, kernel file parsing, classification and the snapshot.

    python3 -m unittest discover -s guest/scopes -p 'test_*.py'
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import scopecore as core  # noqa: E402
from scopecore import NewScope, Proc, SESSION  # noqa: E402

STEAM = 'app-steam-1.scope'
TERMINAL = 'app-xfce4\\x2dterminal-2.scope'


class Names(unittest.TestCase):
    def test_escapes_like_systemd(self):
        self.assertEqual(core.escape('xfce4-terminal'), 'xfce4\\x2dterminal')
        self.assertEqual(core.escape('org.gnome.TextEditor'), 'org.gnome.TextEditor')
        self.assertEqual(core.escape('.hidden'), '\\x2ehidden')
        self.assertEqual(core.escape('Portal 2'), 'Portal\\x202')
        self.assertEqual(core.escape('café'), 'caf\\xc3\\xa9')

    def test_names_round_trip(self):
        for key in ('xfce4-terminal', 'org.gnome.TextEditor', 'Portal 2', 'café', 'a\\b', '.x'):
            name = core.scope_name(key, 7)
            self.assertEqual(core.parse_scope_name(name), (key, 7))
            self.assertTrue(core.valid_scope_id(name))

    def test_scope_ids(self):
        self.assertTrue(core.valid_scope_id(SESSION))
        for bad in ('init.scope', 'app-x.scope', 'app--1.scope', 'app-x-1.scope/..', '../app-x-1.scope', 'app-x-a.scope', ''):
            self.assertFalse(core.valid_scope_id(bad), bad)

    def test_keys_drop_the_desktop_suffix(self):
        self.assertEqual(core.scope_key('steam.desktop'), 'steam')
        self.assertEqual(core.scope_key('org.gimp.GIMP'), 'org.gimp.GIMP')

    def test_desktop_ids(self):
        self.assertTrue(core.valid_desktop_id('org.example.App.desktop'))
        self.assertFalse(core.valid_desktop_id('Portal 2.desktop'))
        self.assertFalse(core.valid_desktop_id('.desktop'))
        self.assertTrue(core.valid_entry_id('Portal 2.desktop'))
        self.assertFalse(core.valid_entry_id('a/b.desktop'))
        self.assertFalse(core.valid_entry_id('a\nb.desktop'))
        self.assertFalse(core.valid_entry_id('steam'))


class Files(unittest.TestCase):
    def test_stat_with_spaces_and_parentheses_in_comm(self):
        fields = ' '.join(['S', '41', '0', '0', '34817'] + ['0'] * 6 + ['120', '30'] + ['0'] * 6 + ['98765'] + ['0'] * 20)
        self.assertEqual(core.parse_stat(f'1234 (Web Content (x)) {fields}'), ('Web Content (x)', 'S', 41, 34817, 150, 98765))
        with self.assertRaises(ValueError):
            core.parse_stat('1234 (x) S 1')
        with self.assertRaises(ValueError):
            core.parse_stat('garbage')

    def test_uid(self):
        self.assertEqual(core.parse_uid('Name:\tx\nUid:\t1000\t1000\t1000\t1000\n'), 1000)
        with self.assertRaises(ValueError):
            core.parse_uid('Name:\tx\n')

    def test_keyed_io_and_memory(self):
        self.assertEqual(core.parse_keyed('usage_usec 500\nuser_usec 300\nbad line here\n'), {'usage_usec': 500, 'user_usec': 300})
        io = '8:0 rbytes=100 wbytes=20 rios=1 wios=2 dbytes=0 dios=0\n8:16 rbytes=5 wbytes=7 rios=1 wios=1 dbytes=0 dios=0\n'
        self.assertEqual(core.parse_io_stat(io), (105, 27))
        self.assertEqual(core.memory_in_use(1000, {'inactive_file': 300}), 700)
        self.assertEqual(core.memory_in_use(100, {'inactive_file': 300}), 0)

    def test_launch_marks(self):
        caboose = b'A=1\0CABOOSE_DESKTOP_ID=steam.desktop\0GIO_LAUNCHED_DESKTOP_FILE_PID=77\0'
        self.assertEqual(core.launch_marks(caboose), ('steam.desktop', 77))
        gio = b'GIO_LAUNCHED_DESKTOP_FILE=/usr/share/applications/org.gnome.Calculator.desktop\0'
        self.assertEqual(core.launch_marks(gio), ('org.gnome.Calculator.desktop', None))
        self.assertIsNone(core.launch_marks(b'PATH=/bin\0'))
        self.assertIsNone(core.launch_marks(b'CABOOSE_DESKTOP_ID=../x\0'))

    def test_terminal_service(self):
        self.assertTrue(core.terminal_service(['/usr/bin/python3', '/opt/caboose/terminal/caboose-terminal.py']))
        self.assertFalse(core.terminal_service(['/usr/bin/python3', '/opt/caboose/files/caboose-files.py']))
        self.assertFalse(core.terminal_service(['bash']))

    def test_a_process_that_ended_before_it_was_read_is_a_value_error(self):
        # read() gives None for a /proc file that went away; a tick must skip the process,
        # not end on an AttributeError while a game starts and ends processes by the dozen.
        for parse in (core.parse_stat, core.parse_uid):
            with self.assertRaises(ValueError):
                parse(None)
            with self.assertRaises(ValueError):
                parse('')

class Classify(unittest.TestCase):
    def setUp(self):
        self.now = 1000.0
        self.scopes = {STEAM: {'origin': 'launch', 'desktopId': 'steam.desktop', 'createdAt': 0},
                       TERMINAL: {'origin': 'launch', 'desktopId': 'xfce4-terminal.desktop', 'createdAt': 0}}

    def classify(self, procs, membership, windows=()):
        return core.classify({p.pid: p for p in procs}, membership, self.scopes, list(windows), self.now)

    def test_stragglers_follow_a_recent_split(self):
        split = 'app-org.example.Game-3.scope'
        self.scopes[split] = {'origin': 'window', 'source': STEAM, 'createdAt': self.now - 1}
        procs = [Proc(20, 10, comm='game'), Proc(21, 20), Proc(22, 21)]
        self.assertEqual(self.classify(procs, {20: split, 21: STEAM, 22: STEAM}), [([21, 22], split)])
        self.scopes[split]['createdAt'] = self.now - 60
        self.assertEqual(self.classify(procs, {20: split, 21: STEAM, 22: STEAM}), [])

    def test_phone_terminal_sessions_get_scopes(self):
        procs = [Proc(5, 1, argv=['/usr/bin/python3', '/opt/caboose/terminal/caboose-terminal.py']),
                 Proc(6, 5, comm='bash'), Proc(7, 6, comm='htop'), Proc(8, 5, comm='bash')]
        moves = self.classify(procs, {5: SESSION, 6: SESSION, 7: SESSION, 8: SESSION})
        self.assertEqual(moves, [([6, 7], NewScope('caboose-terminal', 'terminal', source=SESSION)),
                                 ([8], NewScope('caboose-terminal', 'terminal', source=SESSION))])

    def test_agent_tasks_get_scopes_with_what_they_start(self):
        procs = [Proc(9, 1, argv=['node', '/opt/caboose/agentd/caboose-agentd.mjs', 'run', 'task']), Proc(10, 9, comm='claude'),
                 Proc(11, 10, comm='npm'), Proc(12, 1, argv=['node', '/opt/caboose/agentd/caboose-agentd.mjs', 'serve'])]
        moves = self.classify(procs, {9: SESSION, 10: SESSION, 11: SESSION, 12: SESSION})
        self.assertEqual(moves, [([9, 10, 11], NewScope('caboose-agent', 'agent', source=SESSION))])

    def test_flatpak_sandboxes_are_adopted_with_their_launchers(self):
        # Steam as a Flatpak started without launch marks: flatpak run became bwrap, its
        # sandbox runs Steam; the portal spawned a second sandbox for the same application.
        procs = [Proc(2754, 0, argv=['/usr/bin/bwrap.distrib', '--ro-bind-fd', '25', '/usr']),
                 Proc(2797, 2754, argv=['/usr/bin/bwrap.distrib'], flatpak='com.valvesoftware.Steam'),
                 Proc(2798, 2797, argv=['bash', 'steam.sh'], flatpak='com.valvesoftware.Steam'),
                 Proc(2837, 1, argv=['/usr/libexec/flatpak-portal']),
                 Proc(2980, 2837, argv=['/usr/bin/bwrap.distrib'], flatpak='com.valvesoftware.Steam'),
                 Proc(3008, 2980, argv=['pv-adverb'], flatpak='com.valvesoftware.Steam'),
                 Proc(4000, 1, argv=['/usr/bin/bwrap'], flatpak='org.gimp.GIMP')]
        membership = {p.pid: SESSION for p in procs}
        moves = self.classify(procs, membership)
        self.assertEqual(moves, [
            ([2754, 2797, 2798, 2980, 3008], NewScope('com.valvesoftware.Steam', 'launch', desktop_id='com.valvesoftware.Steam.desktop',
                                                       source=SESSION, flatpak='com.valvesoftware.Steam')),
            ([4000], NewScope('org.gimp.GIMP', 'launch', desktop_id='org.gimp.GIMP.desktop', source=SESSION, flatpak='org.gimp.GIMP'))])

    def test_a_flatpak_sandbox_joins_its_dock_launched_scope(self):
        self.scopes['app-com.valvesoftware.Steam-2.scope'] = {'origin': 'launch', 'desktopId': 'com.valvesoftware.Steam.desktop', 'createdAt': 0}
        procs = [Proc(2837, 1, argv=['/usr/libexec/flatpak-portal']),
                 Proc(2980, 2837, argv=['/usr/bin/bwrap'], flatpak='com.valvesoftware.Steam')]
        moves = self.classify(procs, {2837: SESSION, 2980: SESSION})
        self.assertEqual(moves, [([2980], 'app-com.valvesoftware.Steam-2.scope')])

    def test_flatpak_info(self):
        self.assertEqual(core.flatpak_app('[Application]\nname=com.valvesoftware.Steam\nruntime=x\n'), 'com.valvesoftware.Steam')
        self.assertIsNone(core.flatpak_app('[Runtime]\nname=org.freedesktop.Platform\n'))
        self.assertIsNone(core.flatpak_app('[Application]\nname=../x\n'))

    def test_marked_launches_in_the_session_are_adopted_per_launch(self):
        procs = [Proc(30, 1, marks=('steam.desktop', 30)), Proc(31, 30), Proc(32, 1, marks=('steam.desktop', 30)),
                 Proc(40, 1, marks=('org.gnome.Calculator.desktop', None)), Proc(50, 1)]
        membership = {pid: SESSION for pid in (30, 31, 32, 40, 50)}
        moves = self.classify(procs, membership)
        self.assertEqual(moves, [
            ([30, 31, 32], NewScope('steam', 'launch', desktop_id='steam.desktop', source=SESSION)),
            ([40], NewScope('org.gnome.Calculator', 'launch', desktop_id='org.gnome.Calculator.desktop', source=SESSION))])

    def test_marks_inside_an_app_scope_are_left_alone(self):
        procs = [Proc(30, 1, marks=('steam.desktop', 30))]
        self.assertEqual(self.classify(procs, {30: STEAM}), [])

    def test_a_window_in_the_session_gets_its_own_scope(self):
        procs = [Proc(60, 1, comm='bash'), Proc(61, 60, comm='gedit'), Proc(62, 61, comm='helper')]
        windows = [{'id': 4, 'pid': 61, 'kind': 'toplevel', 'parent': None, 'app_id': 'org.gnome.gedit', 'desktop_id': None},
                   {'id': 5, 'pid': 61, 'kind': 'popup', 'parent': 4, 'app_id': 'org.gnome.gedit', 'desktop_id': None}]
        moves = self.classify(procs, {60: SESSION, 61: SESSION, 62: SESSION}, windows)
        self.assertEqual(moves, [([61, 62], NewScope('org.gnome.gedit', 'window', app_id='org.gnome.gedit', source=SESSION))])

    def test_a_program_run_from_a_terminal_app_is_split_off(self):
        procs = [Proc(70, 1, comm='xfce4-terminal'), Proc(71, 70, comm='bash', tty=34816), Proc(72, 71, comm='gimp', tty=34816)]
        windows = [{'id': 1, 'pid': 70, 'kind': 'toplevel', 'parent': None, 'app_id': 'xfce4-terminal', 'desktop_id': 'xfce4-terminal.desktop'},
                   {'id': 2, 'pid': 72, 'kind': 'toplevel', 'parent': None, 'app_id': 'gimp', 'desktop_id': None}]
        moves = self.classify(procs, {70: TERMINAL, 71: TERMINAL, 72: TERMINAL}, windows)
        self.assertEqual(moves, [([72], NewScope('gimp', 'window', app_id='gimp', source=TERMINAL))])

    def test_a_window_from_a_phone_terminal_session_is_split_off(self):
        session = 'app-caboose\\x2dterminal-5.scope'
        self.scopes[session] = {'origin': 'terminal', 'source': SESSION, 'createdAt': 0}
        procs = [Proc(6, 5, comm='bash', tty=3), Proc(7, 6, comm='mousepad', tty=3)]
        windows = [{'id': 8, 'pid': 7, 'kind': 'toplevel', 'parent': None, 'app_id': 'org.xfce.mousepad', 'desktop_id': None}]
        moves = self.classify(procs, {6: session, 7: session}, windows)
        self.assertEqual(moves, [([7], NewScope('org.xfce.mousepad', 'window', app_id='org.xfce.mousepad', source=session))])

    def test_a_helper_drawing_the_apps_windows_stays(self):
        # A helper process that draws the app's windows under its windowed parent: one app_id.
        procs = [Proc(10, 1, comm='steam'), Proc(11, 10, comm='steamwebhelper')]
        windows = [{'id': 1, 'pid': 10, 'kind': 'toplevel', 'parent': None, 'app_id': 'steam'},
                   {'id': 2, 'pid': 11, 'kind': 'toplevel', 'parent': None, 'app_id': 'steam'}]
        self.assertEqual(self.classify(procs, {10: STEAM, 11: STEAM}, windows), [])

    def test_an_app_another_windowed_app_launched_is_split_off(self):
        # A store client launches a game through a wrapper: the game's window has an app_id
        # of its own, so the game's tree leaves the client's scope; the client stays.
        procs = [Proc(10, 1, comm='steam'), Proc(11, 10, comm='steamwebhelper'),
                 Proc(20, 10, comm='reaper'), Proc(21, 20, comm='game'), Proc(22, 21, comm='game-helper')]
        windows = [{'id': 1, 'pid': 11, 'kind': 'toplevel', 'parent': None, 'app_id': 'steam'},
                   {'id': 2, 'pid': 21, 'kind': 'toplevel', 'parent': None, 'app_id': 'steam_app_620'},
                   {'id': 3, 'pid': 21, 'kind': 'dialog', 'parent': 2, 'app_id': 'steam_app_620'}]
        membership = {pid: STEAM for pid in (10, 11, 20, 21, 22)}
        self.assertEqual(self.classify(procs, membership, windows),
                         [([21, 22], NewScope('steam_app_620', 'window', app_id='steam_app_620', source=STEAM))])
        # Once split, nothing moves: each scope holds one application.
        split = 'app-steam_app_620-3.scope'
        self.scopes[split] = {'origin': 'window', 'appId': 'steam_app_620', 'source': STEAM, 'createdAt': 0}
        self.assertEqual(self.classify(procs, {**membership, 21: split, 22: split}, windows), [])

    def test_the_topmost_process_of_a_split_application_takes_the_rest(self):
        procs = [Proc(10, 1, comm='launcher'), Proc(20, 10, comm='game'), Proc(21, 20, comm='game')]
        windows = [{'id': 1, 'pid': 10, 'kind': 'toplevel', 'parent': None, 'app_id': 'org.example.Launcher'},
                   {'id': 2, 'pid': 21, 'kind': 'toplevel', 'parent': None, 'app_id': 'org.example.Game'},
                   {'id': 3, 'pid': 20, 'kind': 'toplevel', 'parent': None, 'app_id': 'org.example.Game'}]
        self.assertEqual(self.classify(procs, {10: STEAM, 20: STEAM, 21: STEAM}, windows),
                         [([20, 21], NewScope('org.example.Game', 'window', app_id='org.example.Game', source=STEAM))])

    def test_one_process_with_several_app_ids_stays(self):
        # LibreOffice: one soffice process whose windows are Writer, Calc and the Start Center.
        scope = 'app-libreoffice-6.scope'
        self.scopes[scope] = {'origin': 'launch', 'createdAt': 0}
        procs = [Proc(30, 1, comm='oosplash'), Proc(31, 30, comm='soffice.bin')]
        windows = [{'id': 1, 'pid': 31, 'kind': 'toplevel', 'parent': None, 'app_id': 'libreoffice-writer'},
                   {'id': 2, 'pid': 31, 'kind': 'toplevel', 'parent': None, 'app_id': 'libreoffice-calc'},
                   {'id': 3, 'pid': 31, 'kind': 'toplevel', 'parent': None, 'app_id': 'libreoffice-startcenter'}]
        self.assertEqual(self.classify(procs, {30: scope, 31: scope}, windows), [])
        # Nor does it leave when a helper of its own draws a window with another app_id.
        procs.append(Proc(32, 31, comm='helper'))
        windows.append({'id': 4, 'pid': 32, 'kind': 'toplevel', 'parent': None, 'app_id': 'libreoffice-writer'})
        self.assertEqual(self.classify(procs, {30: scope, 31: scope, 32: scope}, windows), [])

    def test_a_launcher_whose_children_own_the_other_windows_stays(self):
        # The launcher's root has a window of its own; its children's windows have other
        # app_ids. The children leave; the root never splits away from them.
        scope = 'app-org.example.Launcher-7.scope'
        self.scopes[scope] = {'origin': 'launch', 'createdAt': 0}
        procs = [Proc(40, 1, comm='launcher'), Proc(41, 40, comm='app')]
        windows = [{'id': 1, 'pid': 40, 'kind': 'toplevel', 'parent': None, 'app_id': 'org.example.Launcher'},
                   {'id': 2, 'pid': 41, 'kind': 'toplevel', 'parent': None, 'app_id': 'org.example.App'}]
        moves = self.classify(procs, {40: scope, 41: scope}, windows)
        self.assertEqual(moves, [([41], NewScope('org.example.App', 'window', app_id='org.example.App', source=scope))])

    def test_a_lone_application_or_a_window_without_an_app_id_stays(self):
        scope = 'app-org.example.App-8.scope'
        self.scopes[scope] = {'origin': 'launch', 'createdAt': 0}
        procs = [Proc(50, 1, comm='app'), Proc(51, 50, comm='child')]
        lone = [{'id': 1, 'pid': 51, 'kind': 'toplevel', 'parent': None, 'app_id': 'org.example.Other'}]
        self.assertEqual(self.classify(procs, {50: scope, 51: scope}, lone), [])
        unnamed = [{'id': 1, 'pid': 50, 'kind': 'toplevel', 'parent': None, 'app_id': 'org.example.App'},
                   {'id': 2, 'pid': 51, 'kind': 'toplevel', 'parent': None, 'app_id': None}]
        self.assertEqual(self.classify(procs, {50: scope, 51: scope}, unnamed), [])

    def test_session_windows_split_whatever_their_app_ids(self):
        # The session scope keeps its rule: every toplevel's process tree gets a scope, a
        # process with several app_ids once, under its first window.
        procs = [Proc(60, 1, comm='soffice.bin'), Proc(61, 60, comm='helper'), Proc(70, 1, comm='gedit')]
        windows = [{'id': 1, 'pid': 60, 'kind': 'toplevel', 'parent': None, 'app_id': 'libreoffice-writer'},
                   {'id': 2, 'pid': 60, 'kind': 'toplevel', 'parent': None, 'app_id': 'libreoffice-calc'},
                   {'id': 3, 'pid': 70, 'kind': 'toplevel', 'parent': None, 'app_id': 'org.gnome.gedit'}]
        moves = self.classify(procs, {60: SESSION, 61: SESSION, 70: SESSION}, windows)
        self.assertEqual(moves, [
            ([60, 61], NewScope('libreoffice-writer', 'window', app_id='libreoffice-writer', source=SESSION)),
            ([70], NewScope('org.gnome.gedit', 'window', app_id='org.gnome.gedit', source=SESSION))])

    def test_an_apps_own_windows_stay(self):
        # Chromium: every window belongs to the browser process, even when it was started from
        # a terminal app's shell (the browser is then that scope's only windowed process).
        procs = [Proc(80, 1, comm='chromium', tty=5), Proc(81, 80, comm='chromium', tty=5), Proc(82, 81, comm='bwrap', tty=5)]
        windows = [{'id': 1, 'pid': 80, 'kind': 'toplevel', 'parent': None, 'app_id': 'chromium'},
                   {'id': 2, 'pid': 80, 'kind': 'toplevel', 'parent': None, 'app_id': 'chromium'},
                   {'id': 3, 'pid': 82, 'kind': 'toplevel', 'parent': None, 'app_id': 'chromium'}]
        scope = 'app-chromium-4.scope'
        self.scopes[scope] = {'origin': 'launch', 'createdAt': 0}
        # A window of 82 under the windowed 80 on the same terminal is the app's own.
        self.assertEqual(self.classify(procs, {80: scope, 81: scope, 82: scope}, windows), [])

    def test_a_subtree_stops_at_other_scopes(self):
        children = {1: [2], 2: [3, 4]}
        self.assertEqual(sorted(core.subtree(1, children, {1: SESSION, 2: SESSION, 3: STEAM, 4: SESSION})), [1, 2, 4])

    def test_each_process_moves_once(self):
        procs = [Proc(20, 1, marks=('org.example.App.desktop', 20)), Proc(21, 20)]
        windows = [{'id': 9, 'pid': 21, 'kind': 'toplevel', 'parent': None, 'app_id': 'org.example.Other'}]
        moves = self.classify(procs, {20: SESSION, 21: SESSION}, windows)
        self.assertEqual(len(moves), 1)
        self.assertEqual(moves[0][1].origin, 'launch')


class Snapshot(unittest.TestCase):
    def test_rates_over_the_interval(self):
        meta = {'origin': 'launch', 'desktopId': 'steam.desktop', 'name': 'Steam', 'createdAt': 12.5}
        now = {'cpu_usec': 3_000_000, 'read': 4096, 'written': 0, 'memory': 1 << 30}
        before = {'cpu_usec': 1_000_000, 'read': 0, 'written': 0, 'memory': 0}
        procs = [core.process_entry(10, 1, 'steam', ['steam', '-silent'], 'S', 1.0, 100),
                 core.process_entry(11, 10, 'steamwebhelper', None, 'R', 50.0, 200)]
        app = core.app_entry(STEAM, meta, now, before, 2.0, procs, [7, 3], None)
        self.assertEqual(app['cpuPercent'], 100.0)
        self.assertEqual(app['io'], {'readBytesPerSecond': 2048, 'writeBytesPerSecond': 0})
        self.assertEqual(app['windows'], [3, 7])
        self.assertEqual(app['startedAt'], 12500)
        self.assertEqual(app['kind'], 'app')
        self.assertEqual([p['pid'] for p in app['processes']], [11, 10])
        self.assertEqual(app['processes'][1]['command'], 'steam -silent')
        self.assertEqual(app['processes'][0]['state'], 'running')

    def test_first_sample_has_no_rates(self):
        app = core.app_entry(SESSION, {'name': 'System', 'origin': 'session'},
                             {'cpu_usec': 5, 'read': 5, 'written': 5, 'memory': 5}, None, 0, [], [], None)
        self.assertEqual((app['kind'], app['cpuPercent'], app['io']['readBytesPerSecond']), ('session', 0.0, 0))

    def test_an_unknown_origin_is_reported_as_a_window(self):
        app = core.app_entry(STEAM, {'origin': 'retired', 'name': 'X'},
                             {'cpu_usec': 0, 'read': 0, 'written': 0, 'memory': 0}, None, 0, [], [], None)
        self.assertEqual(app['origin'], 'window')

    def test_processes_are_bounded(self):
        procs = [core.process_entry(i, 1, 'x' * 100, ['y' * 1000], 'S', 0.0, 0) for i in range(300)]
        app = core.app_entry(STEAM, {}, {'cpu_usec': 0, 'read': 0, 'written': 0, 'memory': 0}, None, 1, procs, [], None)
        self.assertEqual((app['processCount'], len(app['processes'])), (300, core.MAX_PROCESSES))
        self.assertEqual(len(app['processes'][0]['name']), core.MAX_COMM)
        self.assertEqual(len(app['processes'][0]['command']), core.MAX_COMMAND)

    def test_gpu_use(self):
        previous = {(5, 9): {'toPhoneBytes': 100, 'fromPhoneBytes': 10}}
        entries = [{'pid': 5, 'start': 9, 'streams': 2, 'surfaces': 1, 'toPhoneBytes': 2100, 'fromPhoneBytes': 30},
                   {'pid': 6, 'start': 9, 'streams': 1, 'surfaces': 0, 'toPhoneBytes': 999, 'fromPhoneBytes': 0}]
        self.assertEqual(core.gpu_usage(entries, previous, 2.0),
                         {'streams': 3, 'surfaces': 1, 'toPhoneBytesPerSecond': 1000, 'fromPhoneBytesPerSecond': 10})
        self.assertIsNone(core.gpu_usage([], previous, 2.0))

    def test_gpu_placements(self):
        starts = {100: 5000, 200: 6000, 300: 7000}
        files = {'100': 'cpu-until-relaunch 5000\n', '2': 'cpu-until-relaunch 6000',  # 2: a sandbox's own pid
                 '300': 'cpu-until-relaunch 1', '400': 'phone 8000', 'x': 'phone 5000', '101': 'warm 5000'}
        self.assertEqual(core.gpu_placements(files, starts), {100: 'cpu-until-relaunch', 200: 'cpu-until-relaunch'})
        self.assertEqual(core.app_placement(['phone', 'cpu-until-relaunch']), 'cpu-until-relaunch')
        self.assertEqual(core.app_placement(['phone']), 'phone')
        self.assertIsNone(core.app_placement([]))

    def test_gpu_usage_file_is_checked(self):
        good = {'pid': 5, 'start': 9, 'streams': 1, 'surfaces': 0, 'toPhoneBytes': 1, 'fromPhoneBytes': 2}
        data = {'version': 1, 'processes': [good, {**good, 'pid': 0}, {**good, 'streams': -1}, {**good, 'surfaces': True}, 'x']}
        self.assertEqual(core.parse_gpu_usage(data), [good])
        self.assertEqual(core.parse_gpu_usage({'version': 2, 'processes': [good]}), [])
        self.assertEqual(core.parse_gpu_usage(None), [])


if __name__ == '__main__':
    unittest.main()
