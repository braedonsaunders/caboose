"""Executable rejection cases, NOT evidence that the driver is coherent."""
import unittest


class RejectedCandidates(unittest.TestCase):
    def test_whole_page_readback_clobbers_disjoint_cpu_store(self):
        guest, remote = bytearray(4096), bytearray(4096)
        guest[0] = 17  # ordinary store while GPU waits on host event
        remote[4] = 23  # GPU executes after host sets event
        guest[:] = remote  # proposed blanket readback at successful fence
        self.assertNotEqual(guest[0], 17)

    def test_page_ownership_wait_deadlocks_event_setter(self):
        # GPU owns page until completion; CPU byte 0 fault waits for GPU;
        # the same CPU thread must execute vkSetEvent after its ordinary store.
        waits_for = {'cpu_store': 'gpu_completion',
                     'gpu_completion': 'host_event', 'host_event': 'cpu_store'}
        cursor = 'cpu_store'
        for _ in range(3):
            cursor = waits_for[cursor]
        self.assertEqual(cursor, 'cpu_store')

    def test_snapshot_diff_cannot_certify_exact_store_coverage(self):
        before = bytes(8)
        after_no_store = before
        after_store_zero_at_dynamic_address = before
        self.assertEqual(after_no_store, after_store_zero_at_dynamic_address)
        # Identical observations, different footprints. This disproves using
        # differences as an exact store journal, not every possible diff design.
        self.assertNotEqual(set(), {4})

    def test_unprotected_cpu_snapshot_then_copy_loses_store(self):
        guest = bytearray(8)
        snapshot = bytes(guest)
        guest[0] = 17  # legal disjoint CPU update after snapshot
        merged = bytearray(snapshot)
        merged[4] = 23
        guest[:] = merged
        self.assertNotEqual(guest[0], 17)


if __name__ == '__main__':
    unittest.main()
