import unittest
from fixture_codec import encode,decode

class FrameCodecTests(unittest.TestCase):
    def test_frame_payload_survives_decoding(self):
        # A byte string containing a start code must not be discarded as metadata.
        packet=b'\xa3'+encode('id')+encode(7)+encode('pts_us')+encode(12345)+encode('data')+b'\x44\x00\x00\x00\x01'
        fields,end=decode(packet)
        self.assertEqual(end,len(packet))
        self.assertEqual(fields,{'id':7,'pts_us':12345,'data':b'\0\0\0\1'})

    def test_hello_roundtrip(self):
        hello={'version':0,'decoders':['h264'],'displays':[{'id':0,'scale':1.0,'hdr':False}]}
        raw=encode(hello)
        self.assertEqual(decode(raw),(hello,len(raw)))

if __name__=='__main__':unittest.main()
