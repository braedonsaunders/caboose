"""The executor's connection to the broker: a 503 is tried again for a bounded time."""
import os
import socket
import sys
import threading
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import executor  # noqa: E402


class Clock:
    def __init__(self):
        self.t = 0.0
        self.sleeps = []

    def now(self):
        return self.t

    def sleep(self, seconds):
        self.sleeps.append(seconds)
        self.t += seconds


class ConnectRetrying(unittest.TestCase):
    def attempts(self, outcomes):
        def attempt():
            outcome = outcomes.pop(0)
            if isinstance(outcome, Exception):
                raise outcome
            return outcome
        return attempt

    def test_unavailable_broker_is_tried_again_with_backoff(self):
        clock = Clock()
        attempt = self.attempts([executor.Unavailable('503')] * 4 + ['socket'])
        self.assertEqual(executor.connect_retrying(attempt, 0, 10, clock.sleep, clock.now), 'socket')
        self.assertEqual(clock.sleeps, [0.25, 0.5, 1.0, 2.0])

    def test_unavailable_broker_gives_up_at_its_deadline(self):
        clock = Clock()
        attempt = self.attempts([executor.Unavailable('503')] * 100)
        with self.assertRaises(executor.Unavailable):
            executor.connect_retrying(attempt, 0, 10, clock.sleep, clock.now)
        self.assertGreaterEqual(clock.t, 10)
        self.assertLess(clock.t, 13)

    def test_refused_first_connection_is_not_retried(self):
        clock = Clock()
        attempt = self.attempts([ConnectionRefusedError()])
        with self.assertRaises(ConnectionRefusedError):
            executor.connect_retrying(attempt, 0, 10, clock.sleep, clock.now)
        self.assertEqual(clock.sleeps, [])

    def test_refusal_after_unavailable_keeps_its_own_deadline(self):
        clock = Clock()
        attempt = self.attempts([ConnectionRefusedError()] * 3 + ['socket'])
        self.assertEqual(executor.connect_retrying(attempt, 60, 60, clock.sleep, clock.now), 'socket')
        self.assertEqual(clock.sleeps, [0.5, 0.5, 0.5])


class UpgradeAnswer(unittest.TestCase):
    def test_503_answer_raises_unavailable(self):
        server = socket.socket()
        server.bind(('127.0.0.1', 0))
        server.listen(1)

        def answer():
            peer, _ = server.accept()
            data = b''
            while b'\r\n\r\n' not in data:
                data += peer.recv(4096)
            peer.sendall(b'HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\n\r\n')
            peer.close()
        thread = threading.Thread(target=answer)
        thread.start()
        try:
            with self.assertRaises(executor.Unavailable):
                executor.WebSocket.connect(f'127.0.0.1:{server.getsockname()[1]}', b'token', 'c', 'e', 'f')
        finally:
            thread.join()
            server.close()


if __name__ == '__main__':
    unittest.main()
