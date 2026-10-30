#!/usr/bin/env python3
"""Run only after coordinating the isolated software-reference slot."""
import argparse,hashlib,json,os,pathlib,subprocess,time
p=argparse.ArgumentParser();p.add_argument('--task',required=True);p.add_argument('--compositor-dir',required=True);args=p.parse_args()
root=pathlib.Path(args.task).resolve();artifact=pathlib.Path(args.compositor_dir).resolve();fixture=pathlib.Path(__file__).resolve().parent
assert (root/'bundle/vkquake').is_file()
assert hashlib.file_digest((root/'bundle/vkquake').open('rb'),'sha256').hexdigest()=='8785da3046d4a03d69d014baf17e258de5180698bc303389784ef138a9066fe9'
assert hashlib.file_digest((artifact/'caboose-display').open('rb'),'sha256').hexdigest()=='a96c3e9e28afab81f68d377ed9c0da288a3d4afed5aba5118f86238e58066753'
image='sha256:9533a07319ad0d36f47b72d85658495693d54999ffca13187ff9abefa5820361'
assert subprocess.check_output(['docker','image','inspect',image,'--format','{{.Id}}'],text=True,timeout=3).strip()==image
out=root/'software-evidence';out.mkdir(mode=0o700);os.chown(out,1000,1000)
name='caboose-game-reference-'+str(os.getpid())
try:
 cmd=['docker','run','--name',name,'--network','none','--cpus','2','--memory','3g','--memory-swap','3g','--pids-limit','256','--user','1000:1000','--read-only','--tmpfs','/tmp:rw,mode=1777,size=256m','--tmpfs','/run:rw,mode=1777,size=32m']
 for src,dst,ro in [(root/'bundle','/bundle',True),(artifact,'/artifact',True),(fixture,'/fixture',True),(out,'/evidence',False)]:
  cmd+=['--mount',f'type=bind,src={src},dst={dst}'+(',readonly' if ro else '')]
 cmd+=['--entrypoint','timeout',image,'-k','2','55','python3','/fixture/software-reference.py']
 result=subprocess.run(cmd,capture_output=True,text=True,timeout=60)
 (root/'software-reference.log').write_text(result.stdout+'\n'+result.stderr)
 print(result.stdout);print(result.stderr)
 state=json.loads(subprocess.check_output(['docker','inspect',name],timeout=2))[0]['State']
 (root/'software-container-state.json').write_text(json.dumps(state,indent=2)+'\n')
 assert result.returncode==0 and not state['OOMKilled'],state
finally:
 subprocess.run(['docker','rm','-f',name],check=True,timeout=3)
 assert not subprocess.check_output(['docker','ps','-aq','--filter','name=^/'+name+'$'],timeout=2).strip()
 print('EXACT_CONTAINER_ABSENT',name)
