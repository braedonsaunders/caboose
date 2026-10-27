import asyncio, json, os, signal, subprocess, time
records=[]
async def handler(reader,writer):
    server_reader,server_writer=await asyncio.open_connection('127.0.0.1',14500)
    async def pump(src,dst,direction):
        try:
            while data := await src.read(65536):
                records.append({'direction':direction,'hex':data.hex()})
                dst.write(data); await dst.drain()
        finally:
            dst.close()
    await asyncio.gather(pump(reader,server_writer,'client'),pump(server_reader,writer,'server'),return_exceptions=True)

async def main():
    procs=[]
    def start(cmd, env=None):
        p=subprocess.Popen(cmd, env=env, stdout=open("/out/process.log", "ab"), stderr=subprocess.STDOUT, start_new_session=True)
        procs.append(p)
        return p
    try:
        start(['xpra','start',':100','--bind-ws=127.0.0.1:14500','--start=xterm -e sh -c "stty -echo; cat"','--start=xclock','--daemon=no','--speaker=no','--microphone=no','--mdns=no','--printing=no','--ssh-upgrade=no','--xvfb=Xvfb +extension Composite -screen 0 1280x800x24'])
        start(['Xvfb',':99','-screen','0','1280x800x24'])
        await asyncio.sleep(15)
        proxy = await asyncio.start_server(handler,'127.0.0.1',14501)
        async with proxy:
            guestenv=os.environ.copy(); guestenv['DISPLAY']=':100'
            env=os.environ.copy(); env['DISPLAY']=':99'
            client = start(['xpra','attach','ws://127.0.0.1:14501/','--speaker=no','--microphone=no','--clipboard=yes','--compression-level=0','--encoding=h264','--mmap=no','--webcam=no'],env)
            try:
                await asyncio.sleep(12)
                subprocess.run(['xdotool','search','--class','XTerm','windowfocus','type','hello caboose'],env=env,timeout=10)
                subprocess.run(['xclip','-selection','clipboard'],input=b'caboose test clipboard',env=env,timeout=5)
                await asyncio.sleep(3)
                guestenv=os.environ.copy(); guestenv['DISPLAY']=':100'
                clip=await asyncio.create_subprocess_exec('xclip','-o','-selection','clipboard',env=guestenv,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
                try: await asyncio.wait_for(clip.wait(),5)
                except asyncio.TimeoutError: clip.terminate(); await clip.wait()
                await asyncio.sleep(5)
            finally:
                if client.poll() is None: client.terminate()
                await asyncio.sleep(2)
        with open('/out/capture.json','w') as f: json.dump(records,f)
        print('records',len(records), flush=True)
    finally:
        for p in procs:
            try: os.killpg(p.pid,signal.SIGTERM)
            except ProcessLookupError: pass
        for p in procs:
            try: p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(p.pid,signal.SIGKILL); p.wait()
asyncio.run(main())
