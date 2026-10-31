#!/usr/bin/env python3
"""One private native-Wayland software run. Container supervisor caps all at 60s."""
import hashlib,json,os,pathlib,secrets,shlex,signal,socket,struct,subprocess,time
from websockets.sync.client import connect
from fixture_codec import encode,decode
out=pathlib.Path('/evidence');run=out/'runtime';run.mkdir(mode=0o700)
home=out/'home';home.mkdir()
compositor=pathlib.Path('/artifact/caboose-display')
assert hashlib.sha256(compositor.read_bytes()).hexdigest()=='a96c3e9e28afab81f68d377ed9c0da288a3d4afed5aba5118f86238e58066753'
bundle=out/'bundle'
# Private writable copy, no writes to retained source bundle or owner's config.
import shutil
shutil.copytree('/bundle',bundle)
for row in json.loads((bundle/'manifest.json').read_text()):
 p=bundle/row['path'];assert p.stat().st_size==row['size'] and hashlib.file_digest(p.open('rb'),'sha256').hexdigest()==row['sha256']
env=dict(PATH=os.environ['PATH'],HOME=str(home),XDG_RUNTIME_DIR=str(run),NO_AT_BRIDGE='1',CABOOSE_DISPLAY_LOG='info',VK_ICD_FILENAMES='/usr/share/vulkan/icd.d/lvp_icd.json',SDL_VIDEODRIVER='wayland',SDL_AUDIODRIVER='dummy',LP_NUM_THREADS='2')
token=run/'token';token.write_text(secrets.token_hex(24));token.chmod(0o600)
children=[];logs=[];frames=[];windows={};deadline=time.monotonic()+40

def spawn(argv,log):
 f=(out/log).open('w');logs.append(f)
 p=subprocess.Popen(argv,env=env,stdout=f,stderr=subprocess.STDOUT,start_new_session=True);children.append(p);return p

def peer(path):
 with socket.socket(socket.AF_UNIX) as s:
  s.settimeout(1);s.connect(str(path));return struct.unpack('3i',s.getsockopt(socket.SOL_SOCKET,socket.SO_PEERCRED,12))[0]

def seat(control):
 with socket.socket(socket.AF_UNIX) as s:
  s.settimeout(1);s.connect(str(control));s.sendall(b'windows\n');raw=b''
  while b'\n' not in raw:
   chunk=s.recv(65536);assert chunk;raw+=chunk;assert len(raw)<1024**2
  return json.loads(raw)['windows']
try:
 display=spawn([str(compositor),'--listen','127.0.0.1:15499','--token-file',str(token),'--socket','wayland-game-check','--x-display','99','--no-audio','--no-games','--env-file',str(run/'launch.env')],'display.log')
 ready=time.monotonic()+5
 while not (run/'launch.env').exists():
  assert display.poll() is None and time.monotonic()<ready;time.sleep(.05)
 for line in (run/'launch.env').read_text().splitlines():
  k,v=line.split('=',1);env[k]=shlex.split(v)[0]
 assert env['WAYLAND_DISPLAY']=='wayland-game-check'
 control=pathlib.Path(env['CABOOSE_DISPLAY_CONTROL']);assert control.is_relative_to(run)
 assert peer(control)==display.pid and peer(run/env['WAYLAND_DISPLAY'])==display.pid
 assert not seat(control),'private seat must start empty'
 with connect('ws://127.0.0.1:15499',open_timeout=2,close_timeout=1,max_size=16*1024**2) as ws:
  def send(kind,fields):
   body=encode(fields);ws.send(bytes([kind])+struct.pack('<I',len(body))+body)
  send(0x81,dict(version=0,token=token.read_text(),decoders=['h264'],displays=[dict(id=0,width=640,height=480,scale=1.0,refresh_hz=30.0,hdr=False)]))
  game=spawn([str(bundle/'vkquake'),'-basedir',str(bundle),'-window','-width','640','-height','480','-nosound','+map','start'],'game.log')
  while time.monotonic()<deadline:
   assert display.poll() is None and game.poll() is None,'game/compositor exited before frame observation'
   send(0x82,dict(display=0,t_us=int(time.monotonic()*1e6)))
   try:packet=ws.recv(timeout=.05)
   except TimeoutError:continue
   assert isinstance(packet,bytes)
   while packet:
    kind=packet[0];size=int.from_bytes(packet[1:5],'little');assert len(packet)>=size+5
    fields,end=decode(packet[5:5+size]);assert end==size;packet=packet[5+size:]
    assert kind!=0x7f,'session rejected'
    if kind==0x10:
     assert fields['codec']=='h264';frames.append(fields)
     send(0x83,dict(id=fields['id'],pts_us=fields['pts_us'],decoded_us=0))
   if len(frames)>=30:break
  assert len(frames)>=2,'no repeated encoded game frames'
  assert frames[0]['keyframe'],'stream must start with a keyframe'
  (out/'frames.json').write_text(json.dumps([{k:v for k,v in f.items() if k!='data'} for f in frames],indent=2)+'\n')
  windows=seat(control);assert len(windows)==1 and not windows[0]['x11']
 stream=out/'game.h264';stream.write_bytes(b''.join(f['data'] for f in frames))
 subprocess.run(['ffmpeg','-v','error','-threads','2','-i',str(stream),'-vf',f'select=eq(n\\,{len(frames)-1})','-frames:v','1','-y',str(out/'game.png')],check=True,timeout=5,env=env)
 assert (out/'game.png').stat().st_size>1000
 result=dict(software_reference=True,phone_gpu_proven=False,encoded_frames=len(frames),windows=windows,icd=env['VK_ICD_FILENAMES'],binary_sha256=hashlib.file_digest((bundle/'vkquake').open('rb'),'sha256').hexdigest(),png_sha256=hashlib.file_digest((out/'game.png').open('rb'),'sha256').hexdigest())
 (out/'result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result),flush=True)
finally:
 for p in reversed(children):
  if p.poll() is None:
   p.terminate()
   try:p.wait(timeout=1)
   except subprocess.TimeoutExpired:p.kill();p.wait(timeout=1)
  try:os.killpg(p.pid,signal.SIGTERM)
  except ProcessLookupError:pass
 for f in logs:f.close()
 print('OWNED_CHILDREN_REAPED',[(p.pid,p.returncode) for p in children],flush=True)
