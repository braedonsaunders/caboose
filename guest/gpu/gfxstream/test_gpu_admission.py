import unittest
from unittest import mock
import gpu_admission as admission


def request(*, token=b'secret', computer=b'computer-1', executor=b'00112233-4455-6677-8899-aabbccddeeff', extra=b'', key=b'dGhlIHNhbXBsZSBub25jZQ==', protocol=b'caboose.gpu.live.v1'):
    return (b'GET /gpu HTTP/1.1\r\nHost: guest\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n'
            b'Authorization: Bearer '+token+b'\r\nX-Caboose-GPU-Computer: '+computer+b'\r\n'
            b'X-Caboose-GPU-Executor: '+executor+b'\r\nSec-WebSocket-Version: 13\r\n'
            b'Sec-WebSocket-Key: '+key+b'\r\nSec-WebSocket-Protocol: '+protocol+b'\r\n'+extra+b'\r\n')


class AdmissionTests(unittest.TestCase):
    def test_authenticated_upgrade(self):
        computer, executor, response = admission.admit(request(), b'secret')
        self.assertEqual(computer, 'computer-1')
        self.assertEqual(executor.hex, '00112233445566778899aabbccddeeff')
        self.assertIn(b'Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=', response)
        self.assertIn(b'Sec-WebSocket-Protocol: caboose.gpu.live.v1', response)

    def test_unauthenticated_identity_not_interpreted(self):
        with mock.patch.object(admission.uuid, 'UUID', side_effect=AssertionError('identity consulted')):
            with self.assertRaisesRegex(admission.AdmissionError, 'authentication failed'):
                admission.admit(request(token=b'wrong', executor=b'invalid'), b'secret')
            with self.assertRaisesRegex(admission.AdmissionError, 'authentication failed'):
                admission.admit(request(), b'')

    def test_oversized_matching_token_is_rejected(self):
        token = b'a' * (admission.MAX_TOKEN + 1)
        with self.assertRaises(admission.AdmissionError):
            admission.admit(request(token=token), token)

    def test_fail_closed_bad_upgrade(self):
        cases = [request(protocol=b'binary'), request(key=b'bad'),
                 request(executor=b'00000000-0000-0000-0000-000000000000'),
                 request(extra=b'Sec-WebSocket-Extensions: permessage-deflate\r\n'),
                 request(extra=b'Authorization: Bearer secret\r\n'),
                 request().replace(b'GET /gpu ', b'GET /display '),
                 request()[:-2], b'A' * (admission.MAX_REQUEST + 1),
                 request(token=b'a' * (admission.MAX_TOKEN + 1))]
        for value in cases:
            with self.subTest(value=value[:50]), self.assertRaises(admission.AdmissionError):
                admission.admit(value, b'secret')


if __name__ == '__main__': unittest.main()
