import os
import sys
import types
import unittest
from unittest.mock import Mock, patch
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'helpers'))
import a11y
from a11y import Tree, dispatch_accessibility_events


class ValueTests(unittest.TestCase):
    def setUp(self):
        self.tree = Tree.__new__(Tree)
        roles = types.SimpleNamespace(**{name: name for name in ('PASSWORD_TEXT', 'ENTRY', 'AUTOCOMPLETE', 'EDITBAR', 'SPIN_BUTTON', 'SLIDER', 'COMBO_BOX')})
        self.tree.Atspi = types.SimpleNamespace(Role=roles, Value=types.SimpleNamespace(get_current_value=lambda node: 0))
        self.tree.has = lambda states, name: name in states
        self.tree.text = Mock(return_value='hello')
        self.node = Mock()
        self.node.get_attributes.return_value = []

    def test_editable_value_is_separate_from_fingerprint(self):
        self.assertEqual(self.tree.value(self.node, 'ENTRY', {'EDITABLE'}), 'hello')
        self.tree.text.assert_called_once_with(self.node, 200)

    def test_password_and_sensitive_values_are_never_read(self):
        self.assertIsNone(self.tree.value(self.node, 'PASSWORD_TEXT', {'EDITABLE'}))
        self.node.get_attributes.return_value = {'text-input-type': 'password'}
        self.assertIsNone(self.tree.value(self.node, 'ENTRY', {'EDITABLE'}))
        self.tree.text.assert_not_called()

    def test_numeric_zero_is_preserved(self):
        self.tree.text.return_value = ''
        self.assertEqual(self.tree.value(self.node, 'SLIDER', set()), '0')


class EventDispatchTests(unittest.TestCase):
    def test_processes_pending_updates_without_waiting(self):
        context = Mock()
        context.pending.side_effect = [True, True, False]
        dispatch_accessibility_events(context)
        self.assertEqual(context.iteration.call_count, 2)
        context.iteration.assert_called_with(False)

    def test_event_storm_cannot_starve_requests(self):
        context = Mock()
        context.pending.return_value = True
        dispatch_accessibility_events(context)
        self.assertEqual(context.iteration.call_count, 256)
        self.assertTrue(all(call.args == (False,) for call in context.iteration.call_args_list))


if __name__ == '__main__':
    unittest.main()


class PressTests(unittest.TestCase):
    def setUp(self):
        self.tree = Tree.__new__(Tree)
        self.tree.Atspi = types.SimpleNamespace(Role=types.SimpleNamespace(MENU='MENU', PUSH_BUTTON='PUSH_BUTTON'), Action=Mock())
        self.tree.has = lambda states, name: name in states
        self.tree.press_actions = ('click', 'press')
        self.tree.actions = lambda node: ('iface', ['click'])
        self.tree.bounds = lambda node, origin: {'x': 34, 'y': 0, 'width': 36, 'height': 26}
        self.node, self.screen = Mock(), Mock()

    def press(self, role, states=frozenset({'ENABLED', 'SHOWING'})):
        self.node.get_role.return_value = role
        with patch.object(a11y, 'resolve', return_value=(self.screen, 1, self.tree, self.node, set(states), None)):
            a11y.act(':101', 'id', 'press', None)

    def test_a_menu_on_screen_is_clicked_at_its_own_coordinates(self):
        # A menu's own action can open another menu of its bar.
        self.press('MENU')
        self.screen.click.assert_called_once_with(1, 52, 13)
        self.tree.Atspi.Action.do_action.assert_not_called()

    def test_other_controls_and_off_screen_menus_use_their_own_action(self):
        self.tree.Atspi.Action.do_action.return_value = True
        self.press('PUSH_BUTTON')
        self.press('MENU', {'ENABLED'})
        self.assertEqual(self.tree.Atspi.Action.do_action.call_count, 2)
        self.screen.click.assert_not_called()


class StaleCacheTests(unittest.TestCase):
    def test_a_missed_window_or_element_is_read_again(self):
        self.assertTrue(a11y.stale('elements', {'elements': [], 'note': "The focused window was not found in its application's accessibility tree; use a screenshot."}))
        self.assertTrue(a11y.stale('act', {'ok': False, 'error': 'element not found'}))
        self.assertFalse(a11y.stale('elements', {'elements': [], 'note': 'No window is open on this display.'}))
        self.assertFalse(a11y.stale('act', {'ok': False, 'error': 'element is disabled'}))

    def test_a_stale_answer_is_read_again_by_the_same_helper(self):
        # A new AT-SPI client costs every GTK 3 application descriptors it never gives back,
        # so the helper reads the registry afresh in place rather than becoming a new process.
        import io, json
        stale = {'elements': [], 'note': "The focused window was not found in its application's accessibility tree; use a screenshot."}
        fresh = {'elements': [{'id': 'x'}]}
        out = io.StringIO()
        with patch.object(a11y, 'execute', side_effect=[(stale, 0), (fresh, 0)]) as execute, \
                patch.object(a11y, 'refresh') as refresh, \
                patch.object(a11y.os, 'execve', side_effect=AssertionError('re-executed')), \
                patch.object(a11y.sys, 'stdin', io.StringIO(json.dumps({'op': 'elements'}) + '\n')), \
                patch.object(a11y.sys, 'stdout', out):
            a11y.serve(':999')
        self.assertEqual(json.loads(out.getvalue()), fresh)
        self.assertEqual(execute.call_count, 2)
        refresh.assert_called_once_with()

    def test_another_bus_is_asked_through_one_long_lived_helper(self):
        env = dict(os.environ, CABOOSE_A11Y_BUS_STATE='{"next": 9, "tried": []}')
        try:
            first = a11y.BusWorker.ask('test', env, ':999', {'op': 'bogus'})
            pid = a11y.BusWorker.workers['test'].pid
            second = a11y.BusWorker.ask('test', env, ':999', {'op': 'bogus'})
            self.assertEqual(a11y.BusWorker.workers['test'].pid, pid)
            self.assertEqual([first, second], [{'error': 'invalid worker request'}] * 2)
        finally:
            worker = a11y.BusWorker.workers.pop('test', None)
            if worker:
                worker.kill()
                worker.wait()


class FrameOriginTests(unittest.TestCase):
    surface = {"x": -61, "y": -55, "width": 722, "height": 602}
    rect = {"x": 0, "y": 0, "width": 600, "height": 480}

    def test_a_frame_the_size_of_the_window_geometry_measures_from_its_corner(self):
        self.assertEqual(a11y.frame_origin((600, 480), self.rect, self.surface, (-61, -55)), (0, 0))

    def test_a_frame_the_size_of_the_surface_measures_from_the_surface(self):
        self.assertEqual(a11y.frame_origin((722, 602), self.rect, self.surface, (-61, -55)), (-61, -55))

    def test_a_window_without_a_shadow_keeps_its_origin(self):
        rect = {"x": 10, "y": 20, "width": 600, "height": 480}
        self.assertEqual(a11y.frame_origin((600, 480), rect, dict(rect), (10, 20)), (10, 20))
        self.assertEqual(a11y.frame_origin(None, rect, dict(rect), (10, 20)), (10, 20))


class UnreadTests(unittest.TestCase):
    pane = {"x": 0, "y": 100, "width": 600, "height": 380}

    def test_a_scrolled_area_with_only_its_column_headers_exposed_is_unread(self):
        headers = [{"x": 0, "y": 100, "width": 600, "height": 31}]
        self.assertEqual(a11y.unread_regions([self.pane], headers), [[0, 100, 600, 380]])

    def test_a_scrolled_area_whose_items_are_exposed_is_read(self):
        rows = [{"x": 0, "y": 100 + 30 * i, "width": 600, "height": 30} for i in range(6)]
        self.assertEqual(a11y.unread_regions([self.pane], rows), [])

    def test_small_areas_and_outer_panes_of_an_unread_one_are_left_out(self):
        small = {"x": 0, "y": 0, "width": 100, "height": 100}
        outer = {"x": 0, "y": 0, "width": 800, "height": 600}
        self.assertEqual(a11y.unread_regions([outer, small, self.pane], []), [[0, 100, 600, 380]])


class CoverTests(unittest.TestCase):
    def screen(self, *windows):
        screen = a11y.SeatScreen.__new__(a11y.SeatScreen)
        screen.records = {w["id"]: w for w in windows}
        screen.clients = [w["id"] for w in windows]
        return screen

    def test_a_point_under_another_application_is_covered(self):
        screen = self.screen({"id": 1, "pid": 10, "rect": [0, 0, 400, 400], "kind": "toplevel", "title": "Editor"},
                             {"id": 2, "pid": 20, "rect": [100, 100, 100, 100], "kind": "toplevel", "title": "Popup ad"})
        self.assertEqual(screen.covering(1, 150, 150)["id"], 2)
        self.assertIsNone(screen.covering(1, 50, 50))
        self.assertEqual(screen.covering(1, 500, 500)["kind"], "nothing")

    def test_its_own_dialogs_and_menus_do_not_cover_it(self):
        screen = self.screen({"id": 1, "pid": 10, "rect": [0, 0, 400, 400], "kind": "toplevel", "title": "Editor"},
                             {"id": 3, "pid": 10, "rect": [100, 100, 100, 100], "kind": "popup", "title": ""})
        self.assertIsNone(screen.covering(1, 150, 150))

    def test_a_click_on_a_covered_control_is_refused(self):
        screen = self.screen({"id": 1, "pid": 10, "rect": [0, 0, 400, 400], "kind": "toplevel", "title": "Editor"},
                             {"id": 2, "pid": 20, "rect": [100, 100, 100, 100], "kind": "dialog", "title": "Update"})
        screen.seat = Mock()
        with self.assertRaisesRegex(a11y.Failure, 'covered by dialog 2 "Update"'):
            screen.click(1, 150, 150)
        screen.seat.click.assert_not_called()
