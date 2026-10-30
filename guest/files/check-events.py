#!/usr/bin/env python3
"""Linux-only isolated HTTP/inotify check and measured idle/latency report (<45s).
Creates a temporary synthetic home and token, starts only its own Files process,
and terminates it in finally. No Docker, owner home, display or input required.
"""
import concurrent.futures
import http.client
import json
import os
import pathlib
import secrets
import socket
import subprocess
import sys
import tempfile
import time

HERE = pathlib.Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix='caboose-event-check-') as temp:
    home = pathlib.Path(temp)/'home'; home.mkdir()
    bridge = home/'.cache/caboose/bridge'; bridge.mkdir(parents=True)
    token = pathlib.Path(temp)/'token'; token.write_text(secrets.token_hex(32))
    with socket.socket() as s: s.bind(('127.0.0.1',0)); port=s.getsockname()[1]
    env = dict(os.environ, CABOOSE_FILES_ROOT=str(home), CABOOSE_FILES_TOKEN_FILE=str(token), CABOOSE_FILES_PORT=str(port))
    process = subprocess.Popen([sys.executable,str(HERE/'caboose-files.py')],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    session = secrets.token_hex(16)
    def call(path, data, auth=True):
        connection = http.client.HTTPConnection('127.0.0.1',port,timeout=25)
        try:
            connection.request('POST',path,json.dumps(data),{'Authorization': 'Bearer '+(token.read_text() if auth else 'invalid'),'Content-Type':'application/json'})
            result=connection.getresponse(); return result.status,json.loads(result.read())
        finally: connection.close()
    def req(cursor='',phone=False,channels=None,**kw):
        return dict({'session':session,'generation':1,'phone':phone,'cursor':cursor,'channels':channels or ['phone'],'tasks':[]},**kw)
    def counters():
        stat=(pathlib.Path('/proc')/str(process.pid)/'stat').read_text().split()
        switches=0
        for task in (pathlib.Path('/proc')/str(process.pid)/'task').iterdir():
            for line in (task/'status').read_text().splitlines():
                if 'ctxt_switches:' in line: switches+=int(line.split(':')[1])
        children=(pathlib.Path('/proc')/str(process.pid)/'task'/str(process.pid)/'children').read_text().strip()
        return {'cpu_ticks':int(stat[13])+int(stat[14]),'context_switches':switches,'live_children':children}
    try:
        for _ in range(100):
            try:
                status, first=call('/events',req()); break
            except OSError: time.sleep(.02)
        else: raise AssertionError('Files failed to start')
        assert status==200,first
        assert call('/events',req(),False)[0]==401
        assert call('/events',req(tasks=[{'id':'../escape','offset':0}]))[0]==400
        cursor=first['cursor']; samples=[]
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            # Long poll sees directory creation, atomic rename, and partial-write close.
            for i in range(8):
                pending=pool.submit(call,'/events',req(cursor))
                time.sleep(.03)
                queue=home/'.cache/caboose/phone/queue'; queue.mkdir(parents=True,exist_ok=True)
                path=queue/('%d.json'%i)
                start=time.monotonic()
                tmp=queue/('.%d'%i); tmp.write_text(json.dumps({'type':'phone.open','url':'https://example.com/%d'%i})); tmp.rename(path)
                status,result=pending.result(); assert status==200,result
                # A structural event can precede publication; subsequent cursor catches it.
                for _ in range(4):
                    if any(r['channel']=='phone' for r in result['records']): break
                    status,result=call('/events',req(result['cursor']))
                rows=[r for r in result['records'] if r['channel']=='phone']; assert rows,result
                samples.append((time.monotonic()-start)*1000)
                assert path.exists(),'queue consumed before ACK'
                status,result=call('/events',req('',acks=[r['receipt'] for r in rows]))
                assert status==200 and not path.exists()
                cursor=result['cursor']
            # Drain racing watch journal before measuring an outstanding idle poll.
            status,result=call('/events',req('')); cursor=result['cursor']
            for phone in (False,True):
                status,result=call('/events',req('',phone=phone)); cursor=result['cursor']
                before=counters(); start=time.monotonic()
                pending=pool.submit(call,'/events',req(cursor,phone=phone))
                for _ in range(5):
                    if phone: assert call('/events/presence',{'session':session,'generation':1,'phone':True})[0]==200
                    time.sleep(1)
                after=counters()
                if phone: assert time.time()-(bridge/'present').stat().st_mtime<3
                # Wake only the synthetic queue, then ACK it.
                queue=home/'.cache/caboose/phone/queue'; path=queue/'wake.json'; path.write_text('{"type":"phone.open","url":"https://example.com"}')
                status,result=pending.result(); assert status==200,result
                print(json.dumps({'phone':phone,'seconds':round(time.monotonic()-start,3),'cpu_ticks':after['cpu_ticks']-before['cpu_ticks'],'context_switches':after['context_switches']-before['context_switches'],'live_children':after['live_children']}))
                status,result=call('/events',req('',acks=[r['receipt'] for r in result['records'] if 'receipt' in r])); cursor=result['cursor']
            assert call('/events/presence',{'session':session,'generation':2,'phone':False})[0]==200
            assert call('/events/presence',{'session':session,'generation':1,'phone':True})[0]==409
            assert not (bridge/'present').exists()
        print(json.dumps({'publish_to_response_ms':samples,'max_ms':max(samples),'checks':'passed'}))
    finally:
        process.terminate()
        try: process.wait(timeout=5)
        except subprocess.TimeoutExpired: process.kill(); process.wait()
