import struct
import unittest
import gpu_websocket as ws


def client_frame(opcode, data, fin=True, mask=b'\x01\x02\x03\x04'):
    n=len(data); first=(0x80 if fin else 0)|opcode
    if n<126: head=bytes([first,0x80|n])
    elif n<65536: head=bytes([first,0x80|126])+struct.pack('!H',n)
    else: head=bytes([first,0x80|127])+struct.pack('!Q',n)
    return head+mask+bytes(x^mask[i%4] for i,x in enumerate(data))


class WebSocketTests(unittest.TestCase):
    def test_partial_transport_fragmentation_and_ping(self):
        frames=client_frame(2,b'abc',False)+client_frame(9,b'p')+client_frame(0,b'def')
        d=ws.Decoder(); seen=[]
        for byte in frames: d.feed(bytes([byte]), lambda kind,data: seen.append((kind,data)))
        self.assertEqual(seen,[('ping',b'p'),('binary',b'abcdef')]); d.eof()

    def test_binary_limit_and_nonminimal_lengths(self):
        for value in (bytes([0x82,0x7f]), bytes([0x81,0x80])+bytes(4),
                      bytes([0x82,0xfe,0,1])+bytes(4)+b'a',
                      bytes([0x82,0xff])+struct.pack('!Q',ws.MAX_MESSAGE+1)+bytes(4)):
            d=ws.Decoder()
            with self.subTest(value=value), self.assertRaises(ws.WebSocketError):
                d.feed(value, lambda *_: None)

    def test_aggregate_limit_and_truncated_eof(self):
        d=ws.Decoder(); d.feed(client_frame(2,b'a'*ws.MAX_MESSAGE,False),lambda *_:None)
        with self.assertRaises(ws.WebSocketError): d.feed(client_frame(0,b'b'),lambda *_:None)
        d=ws.Decoder(); d.feed(client_frame(2,b'a',False),lambda *_:None)
        with self.assertRaises(ws.WebSocketError): d.eof()

    def test_close_and_server_frame(self):
        d=ws.Decoder(); events=[]
        d.feed(client_frame(8,struct.pack('!H',1000)),lambda *x: events.append(x))
        self.assertEqual(events,[('close',b'\x03\xe8')])
        with self.assertRaises(ws.WebSocketError): d.feed(b'anything',lambda *_:None)
        self.assertEqual(ws.server_frame(2,b'hi'),b'\x82\x02hi')
        with self.assertRaises(ws.WebSocketError): ws.server_frame(9,b'x'*126)


if __name__ == '__main__': unittest.main()
