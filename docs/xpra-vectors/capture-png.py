import asyncio,os,signal,struct,subprocess,json
from websockets.asyncio.client import connect
from xpra.net.rencodeplus.rencodeplus import dumps,loads

async def main():
 p=subprocess.Popen(['xpra','start',':100','--bind-ws=127.0.0.1:14500','--start=xterm -e sleep 60','--daemon=no','--speaker=no','--microphone=no','--mdns=no','--printing=no','--ssh-upgrade=no','--xvfb=Xvfb +extension Composite -screen 0 1280x800x24'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True,env=os.environ | {'XPRA_BACKWARDS_COMPATIBLE':'0'})
 try:
  await asyncio.sleep(15)
  async with connect('ws://127.0.0.1:14500/',subprotocols=['binary'],compression=None,max_size=None) as ws:
   caps={'version':'6.5.5','protocol-version':[7,0],'encoders':['rencodeplus'],'compressors':[],'rencodeplus':True,'compression_level':0,'windows':True,'window':{'enabled':True},'encoding':{'options':['png','rgb'],'core':['png','rgb24','rgb32'],'rgb_formats':['RGB','RGBX'],'video_b_frames':[]},'encodings':{'':['png','rgb'],'core':['png','rgb24','rgb32']},'desktop_size':[1280,800],'dpi':{'x':96,'y':96},'keyboard':False,'wants':['packet-types']}
   payload=bytes(dumps(['hello',caps])); await ws.send(struct.pack('!cBBBI',b'P',16,0,0,len(payload))+payload)
   buf=b''
   for _ in range(15):
    buf+=await asyncio.wait_for(ws.recv(),10)
    while len(buf)>=8:
     magic,flags,level,index,n=struct.unpack('!cBBBI',buf[:8])
     if len(buf)<8+n: break
     data=buf[8:8+n];buf=buf[8+n:]
     print('header',magic,flags,level,index,n,flush=True)
     if index==0 and level==0:
      packet=loads(data); print('packet',packet[0],flush=True)
      if packet[0]=='window-create':
       wid,x,y,w,h=packet[1:6]
       payload=bytes(dumps(['window-map',wid,x,y,w,h,{},{}])); await ws.send(struct.pack('!cBBBI',b'P',16,0,0,len(payload))+payload)
      if packet[0]=='window-draw':
       def convert(v):
        if isinstance(v,(bytes,memoryview)): return {'bytes_hex':bytes(v).hex()}
        if isinstance(v,(list,tuple)): return [convert(x) for x in v]
        if isinstance(v,dict): return {str(k):convert(val) for k,val in v.items()}
        return v
       payload=bytes(dumps(packet)); frame=struct.pack('!cBBBI',b'P',16,0,0,len(payload))+payload
       json.dump({'source':'Xpra 6.5.5 captured WebSocket session','note':'Decoded and re-encoded; not the original wire frame.','packets':[{'direction':'server','packet':convert(packet),'sanitized_frame_hex':frame.hex()}]},open('/out/png.json','w'),indent=2)
       print('draw encoding',packet[6],flush=True); return
 finally:
  os.killpg(p.pid,signal.SIGTERM)
  try:p.wait(timeout=5)
  except subprocess.TimeoutExpired:os.killpg(p.pid,signal.SIGKILL);p.wait()
asyncio.run(main())
