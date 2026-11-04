"""touch_targets.py's reading of the window controls an application draws itself."""
import importlib.util
import os
import sys
import unittest

here = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "helpers")
sys.path.insert(0, here)
spec = importlib.util.spec_from_file_location("caboose_targets", os.path.join(here, "touch_targets.py"))
targets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(targets)

WINDOW = {"x": 0, "y": 0, "width": 800, "height": 650}


def control(x, name, y=0, width=44, height=30):
    return {"x": x, "y": y, "width": width, "height": height, "name": name}


class CaptionTest(unittest.TestCase):
    def test_names(self):
        for name in ("Minimize", "Maximize", "Restore Down", "Close window", "close", "Minimise"):
            self.assertTrue(targets.is_caption_name(name), name)
        for name in ("Closed tabs", "Settings", "", "Open"):
            self.assertFalse(targets.is_caption_name(name), name)

    def test_obsidian_row_against_the_right_corner(self):
        # Obsidian's vault window, as its accessibility tree lists it.
        row = [control(668, "Minimize"), control(712, "Maximize"), control(756, "Close window")]
        self.assertEqual(targets.caption_row(row, WINDOW), row)

    def test_left_corner_and_offset_window(self):
        window = {"x": 100, "y": 50, "width": 600, "height": 400}
        row = [control(104, "Close", y=52), control(132, "Minimize", y=52)]
        self.assertEqual(targets.caption_row(row, window), row)

    def test_a_row_away_from_the_sides_is_content(self):
        row = [control(300, "Minimize"), control(344, "Close")]
        self.assertEqual(targets.caption_row(row, WINDOW), [])

    def test_a_row_needs_close(self):
        row = [control(712, "Minimize"), control(756, "Maximize")]
        self.assertEqual(targets.caption_row(row, WINDOW), [])

    def test_only_the_row_at_the_corner(self):
        far = control(10, "Close")  # a dialog's close in the page, at the left
        row = [control(712, "Maximize"), control(756, "Close window")]
        self.assertEqual(targets.caption_row([far] + row, WINDOW), [far] + row)
        self.assertEqual(targets.caption_row([control(200, "Close")] + row, WINDOW), row)


if __name__ == "__main__":
    unittest.main()
