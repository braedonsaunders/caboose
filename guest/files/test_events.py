"""Portable queue/protocol tests; Linux inotify/HTTP checks are in check-events.py."""
import json
import os
import pathlib
import tempfile
import unittest
from event_stream import Events, Store, Watch, request

TASK = '12345678-1234-1234-1234-123456789abc'
ID = 'a' * 32

def body(**kw):
    return dict({'channels': ['phone'], 'tasks': [], 'phone': False, 'session': ID, 'generation': 0, 'cursor': ''}, **kw)

class Tests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temp.name)
        def directory(parts):
            fd = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY)
            try:
                for part in parts:
                    new = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                    os.close(fd); fd = new
                return fd
            except BaseException: os.close(fd); raise
        self.directory = directory
        self.store = Store(directory)
    def tearDown(self): self.temp.cleanup()
    def put(self, path, value):
        p = self.root / path; p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(value if isinstance(value, bytes) else json.dumps(value).encode())
        return p
    def snapshot(self, **kw): return self.store.snapshot(body(**kw), 'anchor')[0]
    def test_invalid_requests(self):
        for update in ({'channels':['evil']}, {'phone':1}, {'session':'../x'}, {'generation':True}, {'tasks':[{'id':'../x','offset':0}]}, {'tasks':[{'id':TASK,'offset':-1}]}, {'tasks':[{'id':TASK,'offset':True}]}, {'tasks':[{'id':TASK,'offset':2**54}]}, {'acks':['x'*1025]}):
            with self.assertRaises(ValueError): request(body(**update))
        request(body(tasks=[{'id':TASK,'offset':0,'turn':1}]))
    def test_replay_until_ack(self):
        p = self.put('.cache/caboose/phone/queue/a.json', {'type':'phone.open','url':'https://example.com'})
        a = self.snapshot()[0]
        self.assertEqual(a, self.snapshot()[0]); self.assertTrue(p.exists())
        self.store.ack(a['receipt']); self.assertFalse(p.exists())
        self.store.ack(a['receipt'])
    def test_replaced_record_survives_old_ack(self):
        p = self.put('.cache/caboose/phone/queue/a.json', {'value':1})
        a = self.snapshot()[0]; p.unlink(); p.write_text('{"value":2}')
        self.store.ack(a['receipt']); self.assertTrue(p.exists())
    def test_receipt_forgery(self):
        self.store.ack('e30=.00')
        p = self.put('.cache/caboose/phone/queue/a.json', {})
        receipt = self.snapshot()[0]['receipt']
        Store(self.directory).ack(receipt)
        self.assertTrue(p.exists())
    def test_partial_write_and_rename(self):
        p = self.put('.cache/caboose/phone/queue/a.json', b'{')
        self.assertEqual(self.snapshot(), [])
        p.write_text('{"value":1}'); self.assertEqual(len(self.snapshot()),1)
        p.rename(p.with_name('b.json')); self.assertEqual(len(self.snapshot()),1)
    def test_late_directory(self):
        self.assertEqual(self.snapshot(), [])
        self.put('.cache/caboose/phone/queue/a.json', {})
        self.assertEqual(len(self.snapshot()),1)
    def test_limits_and_symlinks(self):
        self.put('.cache/caboose/phone/queue/a.json', b' '*16385)
        (self.root/'.cache/caboose/phone/queue/b.json').symlink_to('/etc/passwd')
        self.assertEqual(self.snapshot(), [])
    def test_bridge_claim_replay_and_ack_retains(self):
        p = self.put('.cache/caboose/bridge/requests/'+ID+'.json', {'id':ID})
        a = self.snapshot(channels=['bridge.request'])[0]
        claimed = p.parent.parent/'claimed'/p.name
        self.assertFalse(p.exists()); self.assertTrue(claimed.exists())
        self.assertEqual(a,self.snapshot(channels=['bridge.request'])[0])
        self.store.ack(a['receipt']); self.assertEqual(self.snapshot(channels=['bridge.request']),[])
        self.assertTrue(claimed.exists())
        self.store.accepted_bridge.clear(); self.assertEqual(len(self.snapshot(channels=['bridge.request'])),1)
    def test_offsets_truncation_and_scope(self):
        self.put('Agents/'+TASK+'/transcript.jsonl', b'abcd')
        row = self.snapshot(channels=['agent.tick'],tasks=[{'id':TASK,'offset':2}])[0]['record']
        self.assertEqual(row['nextOffset'],4); self.assertFalse(row['reset'])
        row = self.snapshot(channels=['agent.tick'],tasks=[{'id':TASK,'offset':9}])[0]['record']
        self.assertEqual(row['offset'],0); self.assertTrue(row['reset']); self.assertEqual(row['nextOffset'],4)
        self.assertEqual(self.snapshot(channels=['agent.tick'],tasks=[]),[])
    def test_chunked_transcript(self):
        self.put('Agents/'+TASK+'/transcript.jsonl', b'a'*100000)
        rows,more = self.store.snapshot(body(channels=['agent.tick'],tasks=[{'id':TASK,'offset':0}]),'')
        self.assertTrue(more); self.assertEqual(rows[0]['record']['nextOffset'],65536)
    def test_mailbox_filename_turn_binding(self):
        p = self.put('Agents/'+TASK+'/tool-mailbox/'+TASK+'.request', {'id':TASK,'turn':1,'tool':'x','arguments':{}})
        self.assertEqual(len(self.snapshot(channels=['agent.mailbox'],tasks=[{'id':TASK,'offset':0,'turn':1}])),1)
        self.assertEqual(self.snapshot(channels=['agent.mailbox'],tasks=[{'id':TASK,'offset':0,'turn':2}]),[])
        p.write_text(json.dumps({'id':'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','turn':1,'tool':'x','arguments':{}}))
        self.assertEqual(self.snapshot(channels=['agent.mailbox'],tasks=[{'id':TASK,'offset':0,'turn':1}]),[])
    def test_overflow_rename_and_presence_filter(self):
        import struct
        self.assertTrue(Watch.changed(struct.pack('iIII',-1,0x4000,0,0)))
        self.assertTrue(Watch.changed(struct.pack('iIII',1,0x80,7,4)+b'x\0\0\0'))
        self.assertFalse(Watch.changed(struct.pack('iIII',1,0x8,0,8)+b'present\0'))
    def test_presence_mtime(self):
        self.put('.cache/caboose/bridge/a', b'')
        events = Events(self.directory); events.presence(True)
        present = self.root/'.cache/caboose/bridge/present'
        import time
        self.assertLess(time.time()-present.stat().st_mtime,3)
        events.presence(False); self.assertFalse(present.exists())
    def test_bounded_batch(self):
        for i in range(140): self.put('.cache/caboose/phone/queue/%d.json'%i, {'v':i})
        rows,more = self.store.snapshot(body(),'')
        self.assertEqual(len(rows),128); self.assertTrue(more)

    def test_transcript_replacement_and_regrow(self):
        p = self.put('Agents/'+TASK+'/transcript.jsonl', b'abcd')
        kw = {'channels':['agent.tick'],'tasks':[{'id':TASK,'offset':0}]}
        self.snapshot(**kw)
        p.unlink(); p.write_bytes(b'new-content')
        kw['tasks'][0]['offset']=4
        row = self.snapshot(**kw)[0]['record']
        self.assertTrue(row['reset']); self.assertEqual(row['offset'],0)
        p.write_bytes(b'changed-again-longer')
        kw['tasks'][0]['offset']=11
        row = self.snapshot(**kw)[0]['record']
        self.assertTrue(row['reset']); self.assertEqual(row['offset'],0)
    def test_truncation_after_lost_chunk_response(self):
        p=self.put('Agents/'+TASK+'/transcript.jsonl',b'a'*65536)
        self.snapshot(channels=['agent.tick'],tasks=[{'id':TASK,'offset':0}])
        with p.open('ab') as f: f.write(b'b'*65536)
        self.snapshot(channels=['agent.tick'],tasks=[{'id':TASK,'offset':65536}])  # response lost
        p.write_bytes(b'c'*140000)
        row=self.snapshot(channels=['agent.tick'],tasks=[{'id':TASK,'offset':65536}])[0]['record']
        self.assertTrue(row['reset']); self.assertEqual(row['offset'],0)
    def test_many_tasks_reach_idle(self):
        tasks=[{'id':'%08x-1234-1234-1234-123456789abc'%i,'offset':0} for i in range(256)]
        seen=set()
        for _ in range(5):
            rows,more=self.store.snapshot(body(channels=['agent.tick'],tasks=tasks),'')
            seen.update(r['record']['id'] for r in rows)
            if not more: break
        self.assertFalse(more); self.assertEqual(len(seen),256)
    def test_task_retirement_during_pagination(self):
        tasks=[{'id':'%08x-1234-1234-1234-123456789abc'%i,'offset':0} for i in range(256)]
        rows,more=self.store.snapshot(body(channels=['agent.tick'],tasks=tasks),'')
        retired={r['record']['id'] for r in rows}
        remaining=[t for t in tasks if t['id'] not in retired]
        rows,more=self.store.snapshot(body(channels=['agent.tick'],tasks=remaining),'')
        self.assertEqual(rows[0]['record']['id'],remaining[0]['id'])
    def test_presence_stale_generation_and_session(self):
        self.put('.cache/caboose/bridge/a',b'')
        events=Events(self.directory); events.session=ID; events.generation=1
        self.assertTrue(events.lease({'session':ID,'generation':2,'phone':True}))
        p=self.root/'.cache/caboose/bridge/present'; stamp=p.stat().st_mtime_ns
        self.assertFalse(events.lease({'session':ID,'generation':1,'phone':False}))
        self.assertFalse(events.lease({'session':'b'*32,'generation':3,'phone':False}))
        self.assertEqual(p.stat().st_mtime_ns,stamp)
        self.assertTrue(events.lease({'session':ID,'generation':3,'phone':False}))
        self.assertFalse(p.exists())

if __name__ == '__main__': unittest.main()
