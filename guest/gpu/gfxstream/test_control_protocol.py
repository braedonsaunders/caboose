import unittest
import control_protocol as p


class ControlProtocolTests(unittest.TestCase):
    def test_exact_record_sizes_and_roundtrip(self):
        values = [(p.Bind(1,2,1000,42,1234,17), p.encode_bind, 56, 1),
                  (p.BindResult(1,0,b'a'*16,b'b'*16,2,3), p.encode_result, 80, 0),
                  (p.BindResult(1,1,bytes(16),bytes(16),0,0), p.encode_result, 80, 0),
                  (p.RevokeGrant(b'a'*16,b'b'*16,3), p.encode_revoke, 64, 0),
                  (p.GrantRetired(b'a'*16,b'b'*16,3), p.encode_grant_retired, 64, 0),
                  (p.RevokeRequest(b'a'*16,b'b'*16,3), p.encode_revoke_request, 64, 0),
                  (p.ExecutorLifecycle(4, b'e'*16, 1), p.encode_lifecycle, 48, 0),
                  (p.ExecutorLifecycle(5, b'e'*16, 1), p.encode_lifecycle, 48, 0),
                  (p.ExecutorLifecycle(6, b'e'*16, 1), p.encode_lifecycle, 48, 0)]
        for value, encoder, length, fds in values:
            with self.subTest(value=value):
                raw=encoder(value); self.assertEqual(len(raw), length)
                self.assertEqual(p.decode(raw, fds), value)
                with self.assertRaises(p.ControlError): p.decode(raw, fds+1)
                with self.assertRaises(p.ControlError): p.decode(raw[:-1], fds)

    def test_handoff_and_denial_constraints(self):
        self.assertEqual(p.decode(b'G',1), 'handoff')
        for fds in (0,2):
            with self.assertRaises(p.ControlError): p.decode(b'G',fds)
        with self.assertRaises(p.ControlError): p.encode_result(p.BindResult(1,1,b'a'*16,bytes(16),0,0))
        with self.assertRaises(p.ControlError): p.encode_result(p.BindResult(1,0,bytes(16),b'b'*16,2,3))

    def test_reserved_and_unknown_are_terminal(self):
        raw=bytearray(p.encode_bind(p.Bind(1,2,1000,42,1234,17)))
        raw[12]=1
        with self.assertRaises(p.ControlError): p.decode(raw,1)
        raw[12]=0; raw[6]=99
        with self.assertRaises(p.ControlError): p.decode(raw,1)


if __name__ == '__main__': unittest.main()
