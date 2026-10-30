import socket
import threading
import time
import unittest

from duplex import DuplexRelay


def read_all(sock):
    chunks = []
    while data := sock.recv(16384):
        chunks.append(data)
    return b"".join(chunks)


class RelayTests(unittest.TestCase):
    def start_relay(self, capacity=4096, timeout=3):
        app, left = socket.socketpair()
        right, gpu = socket.socketpair()
        app.settimeout(2)
        gpu.settimeout(2)
        relay = DuplexRelay(left, right, capacity=capacity, timeout=timeout)
        results = []
        thread = threading.Thread(target=lambda: results.append(relay.run()))
        thread.start()
        def cleanup():
            relay.cancel()
            app.close()
            gpu.close()
            thread.join(4)
            self.assertFalse(thread.is_alive(), "relay leaked its worker")
        self.addCleanup(cleanup)
        return app, gpu, relay, thread, results, left, right

    def test_real_duplex_round_trip_and_half_close(self):
        app, gpu, relay, thread, results, left, right = self.start_relay()
        request = bytes(range(256)) * 4096
        response = b"actual-return-path\x00\xff" * 10000
        received = []
        errors = []
        def executor():
            try:
                received.append(read_all(gpu))
                gpu.sendall(response)
                gpu.shutdown(socket.SHUT_WR)
            except BaseException as exc:
                errors.append(exc)
        worker = threading.Thread(target=executor)
        worker.start()
        try:
            app.sendall(request)
            app.shutdown(socket.SHUT_WR)
            self.assertEqual(read_all(app), response)
        finally:
            worker.join(3)
        self.assertFalse(worker.is_alive())
        self.assertEqual(errors, [])
        self.assertEqual(received, [request])
        thread.join(3)
        self.assertFalse(thread.is_alive())
        self.assertEqual(results[0].reason, "eof")
        self.assertEqual(results[0].forwarded, (len(request), len(response)))
        self.assertTrue(all(n <= 4096 for n in results[0].peak_pending))
        self.assertEqual((left.fileno(), right.fileno()), (-1, -1))

    def test_reply_progresses_while_request_is_backpressured(self):
        app, gpu, relay, thread, results, *_ = self.start_relay(capacity=512)
        # Fill the request direction without draining it at the executor.
        app.setblocking(False)
        for _ in range(10000):
            try:
                app.send(b"r" * 4096)
            except BlockingIOError:
                break
        app.settimeout(2)
        gpu.sendall(b"reply-before-request-drain")
        self.assertEqual(app.recv(100), b"reply-before-request-drain")
        relay.cancel()
        thread.join(2)
        self.assertFalse(thread.is_alive())
        self.assertEqual(results[0].reason, "cancelled")
        self.assertLessEqual(results[0].peak_pending[0], 512)

    def test_idle_cancel_wakes_and_closes_owned_descriptors(self):
        app, gpu, relay, thread, results, left, right = self.start_relay(timeout=90)
        start = time.monotonic()
        relay.cancel()
        relay.cancel()
        thread.join(1)
        self.assertFalse(thread.is_alive())
        self.assertLess(time.monotonic()-start, 1)
        self.assertEqual(results[0].reason, "cancelled")
        self.assertEqual((left.fileno(), right.fileno()), (-1, -1))
        relay.cancel()
        with self.assertRaises(RuntimeError):
            relay.run()

    def test_absolute_deadline_does_not_fabricate_completion(self):
        app, gpu, relay, thread, results, *_ = self.start_relay(timeout=.03)
        thread.join(1)
        self.assertFalse(thread.is_alive())
        self.assertEqual(results[0].reason, "timeout")
        self.assertEqual(results[0].forwarded, (0, 0))

    def test_connections_have_independent_cancellation_and_bytes(self):
        a, g, first, t, results, *_ = self.start_relay()
        other, endpoint, second, _, _, *_ = self.start_relay()
        first.cancel()
        t.join(1)
        other.sendall(b"other-session")
        self.assertEqual(endpoint.recv(100), b"other-session")
        self.assertEqual(results[0].reason, "cancelled")


if __name__ == "__main__":
    unittest.main()
