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

from event_stream import Watch

HERE = pathlib.Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix='caboose-event-check-') as temp:
    home = pathlib.Path(temp)/'home'; home.mkdir()
    bridge = home/'.cache/caboose/bridge'; bridge.mkdir(parents=True)
    token = pathlib.Path(temp)/'token'; token.write_text(secrets.token_hex(32))
    with socket.socket() as s: s.bind(('127.0.0.1',0)); port=s.getsockname()[1]
    env = dict(os.environ, CABOOSE_FILES_ROOT=str(home), CABOOSE_FILES_TOKEN_FILE=str(token), CABOOSE_FILES_PORT=str(port))
    session = secrets.token_hex(16)
    def directory(parts):
        fd = os.open(home, os.O_RDONLY | os.O_DIRECTORY)
        try:
            for part in parts:
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                os.close(fd); fd=child
            return fd
        except BaseException: os.close(fd); raise
    task_id='12345678-1234-1234-1234-123456789abc'
    (home/'Agents'/task_id/'approvals').mkdir(parents=True)
    baseline_fds=len(list(pathlib.Path('/proc/self/fd').iterdir()))
    for _ in range(32):
        watch=Watch(directory,[{'id':task_id,'offset':0}]); watch.close()
        watch=Watch(directory,[]); watch.close()
    assert len(list(pathlib.Path('/proc/self/fd').iterdir()))==baseline_fds, 'watch descriptor leak'

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
        # Main thread exists for the entire sample. Summing transient request
        # threads produces negative deltas when a completed handler disappears.
        for line in (pathlib.Path('/proc')/str(process.pid)/'status').read_text().splitlines():
            if 'ctxt_switches:' in line: switches+=int(line.split(':')[1])
        children=(pathlib.Path('/proc')/str(process.pid)/'task'/str(process.pid)/'children').read_text().strip()
        return {'cpu_ticks':int(stat[13])+int(stat[14]),'context_switches':switches,'live_children':children,'python_process_creation_events':len(audit.read_text().splitlines()),'wait_completions':waits.stat().st_size}
    audit = pathlib.Path(temp)/'process-events'
    audit.write_text('')
    waits = pathlib.Path(temp)/'wait-events'; waits.write_bytes(b'')
    # CPython audit events count fork/spawn/exec attempts, including short-lived children
    # that a /proc children snapshot misses. Native extension syscalls are outside this metric.
    wrapper = """import os,runpy,sys
import select,selectors
waitfd=os.open(sys.argv[3],os.O_WRONLY|os.O_APPEND)
original_select=select.select
original_poll_select=selectors.PollSelector.select
def observed_select(*args,**kwargs):
    result=original_select(*args,**kwargs)
    os.write(waitfd,b'x')
    return result
def observed_poll_select(*args,**kwargs):
    result=original_poll_select(*args,**kwargs)
    os.write(waitfd,b'x')
    return result
select.select=observed_select
selectors.PollSelector.select=observed_poll_select
from http.server import ThreadingHTTPServer
original_bind=ThreadingHTTPServer.server_bind
def loopback_bind(server):
    server.server_address=('127.0.0.1',server.server_address[1])
    original_bind(server)
ThreadingHTTPServer.server_bind=loopback_bind
fd=os.open(sys.argv[2],os.O_WRONLY|os.O_APPEND)
def audit(event,args):
    if event in ('os.fork','os.forkpty','os.posix_spawn','os.exec','subprocess.Popen'):
        os.write(fd,(event+'\\n').encode())
sys.addaudithook(audit)
sys.path.insert(0,os.path.dirname(sys.argv[1]))
runpy.run_path(sys.argv[1],run_name='__main__')
"""
    process = subprocess.Popen([sys.executable,'-c',wrapper,str(HERE/'caboose-files.py'),str(audit),str(waits)],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
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
                print(json.dumps({'phone':phone,'seconds':round(time.monotonic()-start,3),'cpu_ticks':after['cpu_ticks']-before['cpu_ticks'],'main_thread_context_switches':after['context_switches']-before['context_switches'],'live_children':after['live_children'],'python_process_creation_events':after['python_process_creation_events']-before['python_process_creation_events'],'wait_completions':after['wait_completions']-before['wait_completions']}))
                status,result=call('/events',req('',acks=[r['receipt'] for r in result['records'] if 'receipt' in r])); cursor=result['cursor']
            assert call('/events/presence',{'session':session,'generation':2,'phone':False})[0]==200
            assert call('/events/presence',{'session':session,'generation':1,'phone':True})[0]==409
            assert not (bridge/'present').exists()
        assert not audit.read_text(), 'event path forked or executed a Python subprocess'
        print(json.dumps({'publish_to_response_ms':samples,'max_ms':max(samples),'checks':'passed'}))
    finally:
        process.terminate()
        try: process.wait(timeout=5)
        except subprocess.TimeoutExpired: process.kill(); process.wait()
