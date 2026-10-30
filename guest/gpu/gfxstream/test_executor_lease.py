import unittest
import executor_lease as lease


class LeaseTests(unittest.TestCase):
    def test_disconnect_does_not_release_generation(self):
        gate=lease.ExecutorLease(); first=b'a'*16; second=b'b'*16
        generation=gate.admit(first)
        with self.assertRaises(RuntimeError): gate.admit(second)
        gate.ready(first,generation); gate.revoke(first,generation)
        with self.assertRaises(RuntimeError): gate.admit(second)
        with self.assertRaises(RuntimeError): gate.finished(second,generation)
        gate.finished(first,generation)
        self.assertGreater(gate.admit(second),generation)

    def test_early_finish_and_stale_receipts_fail(self):
        gate=lease.ExecutorLease(); ident=b'a'*16; generation=gate.admit(ident)
        with self.assertRaises(RuntimeError): gate.finished(ident,generation)
        with self.assertRaises(RuntimeError): gate.ready(ident,generation+1)
        gate.revoke(ident,generation); gate.finished(ident,generation)
        with self.assertRaises(RuntimeError): gate.finished(ident,generation)

    def test_direction_queue_limits_and_recovery(self):
        q=lease.BoundedQueue()
        for _ in range(64): q.put(b'x')
        with self.assertRaises(BufferError): q.put(b'x')
        for _ in range(64): self.assertEqual(q.pop(),b'x')
        q.put(b'x'*lease.MAX_QUEUED_BYTES)
        with self.assertRaises(BufferError): q.put(b'x')
        self.assertEqual(len(q.pop()),lease.MAX_QUEUED_BYTES)
        self.assertIsNone(q.pop())


if __name__ == '__main__': unittest.main()
