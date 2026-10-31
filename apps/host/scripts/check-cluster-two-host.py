#!/usr/bin/env python3
"""Destructive acceptance for TWO DISPOSABLE Azure hosts only. Never run on real owner computers."""
import argparse, json, pathlib, re, subprocess, time, urllib.request, urllib.parse
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--disposable-azure-hosts', action='store_true', required=True)
for name in ['source-url','target-url','source-token-file','target-token-file','source-ssh','computer','marker-path']:
    p.add_argument('--'+name, required=True)
a = p.parse_args()
if not re.fullmatch(r'[A-Za-z0-9_.-]+',a.source_ssh) or not re.fullmatch(r'(owner|c-[a-f0-9]{10})',a.computer):
    p.error('Invalid SSH alias or computer id')
for value in [a.source_url,a.target_url]:
    if urllib.parse.urlsplit(value).scheme != 'https': p.error('HTTPS host URLs required')
tokens = {a.source_url:pathlib.Path(a.source_token_file).read_text().strip(),a.target_url:pathlib.Path(a.target_token_file).read_text().strip()}
def request(base,path,method='GET'):
    req=urllib.request.Request(base.rstrip('/')+path,method=method,headers={'Authorization':'Bearer '+tokens[base]})
    with urllib.request.urlopen(req,timeout=600) as response: return response.read()
route='/v1/computers/'+a.computer
marker=route+'/fs/content?'+urllib.parse.urlencode({'path':a.marker_path})
expected=request(a.source_url,marker)
if not expected: raise RuntimeError('Marker must be nonempty')
before=json.loads(request(a.source_url,route+'/location'))
request(a.source_url,route+'/cluster/checkpoint','POST')
# This intentionally stops the source service; B's recovery subsequently deallocates its Azure VM.
subprocess.run(['ssh','--',a.source_ssh,'sudo','systemctl','stop','caboose-host'],check=True,timeout=90)
deadline=time.monotonic()+600
while time.monotonic()<deadline:
    try:
        after=json.loads(request(a.target_url,route+'/location'))
        if after['available'] and int(after['generation'])>int(before['generation']):
            if request(a.target_url,marker)!=expected: raise RuntimeError('Recovered marker mismatch')
            print('PASS: recovered marker via new generation. Inspect Azure receipt and source deallocated state before reusing these disposable hosts.')
            break
    except urllib.error.HTTPError: pass
    time.sleep(3)
else: raise RuntimeError('No verified recovery within ten minutes')
