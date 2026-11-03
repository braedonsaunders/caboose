#!/usr/bin/env python3
"""Optional local Laya scorer: Apache-2.0 upstream runtime, no UI or execution access."""
import argparse
import json
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
import torch
import laya
from laya.common import build_sequence

INSTRUCTIONS = json.loads(Path(__file__).with_name('specialist-decision-schema.json').read_text())['instructions']
p = argparse.ArgumentParser()
p.add_argument('--model', required=True)
p.add_argument('--device', choices=['cpu', 'mps', 'cuda'], default='cpu')
p.add_argument('--data')
p.add_argument('--output')
p.add_argument('--port', type=int, default=11435)
a = p.parse_args()
torch.set_num_threads(4)
if a.device == 'mps': torch.mps.set_per_process_memory_fraction(0.2)
agent = laya.load(a.model, device=a.device)

def score(request):
    choices = request['choices']
    state = request['state']
    if not isinstance(state, str) or len(state) > 16000 or not isinstance(choices, list) or not 2 <= len(choices) <= 32 or any(not isinstance(c, str) or len(c) > 600 for c in choices):
        raise ValueError('invalid bounded decision')
    criteria = {str(i): text for i, text in enumerate(choices)}
    question = {'type': 'choice', 'instructions': INSTRUCTIONS, 'criteria': criteria}
    internal = {'t': 'choice', 'ins': INSTRUCTIONS, 'crit': criteria}
    started = time.perf_counter()
    _, _, options, truncation = build_sequence(agent.tok, state, internal, max_len=1024, head_max_len=768, return_stats=True, return_truncation_stats=True)
    if truncation['truncated'] or options['tokens_per_option'] is not None or options['options_distinct'] != len(choices):
        raise ValueError('observation or choices exceed token budget; narrow the task')
    result = agent.predict(state, {'next': question}, max_len=1024, head_max_len=768)
    answer = result['answers']['next']
    return {'revision': request.get('revision'), 'choice': int(answer['choice']), 'probabilities': answer['probabilities'],
            'elapsedMs': (time.perf_counter() - started) * 1000, 'inputTokens': result['usage']['input_tokens']}

if a.data:
    if not a.output: raise ValueError('--output required for evaluation')
    with open(a.output, 'x') as out:
        for index, line in enumerate(Path(a.data).read_text().splitlines()):
            row = json.loads(line)
            try:
                result = score(row)
                result['exact'] = result['choice'] == row['expected']
                result['acceptable'] = result['choice'] in row.get('acceptable', [row['expected']])
            except Exception as error:
                result = {'exact': False, 'error': str(error)}
            out.write(json.dumps({'index': index, **result}) + '\n'); out.flush()
else:
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_): pass
        def do_POST(self):
            try:
                length = int(self.headers.get('Content-Length', '0'))
                if self.path != '/v1/decision' or not 0 < length <= 32768: raise ValueError('invalid request')
                request = json.loads(self.rfile.read(length))
                result = score(request)
                code = 200
            except Exception as error:
                result = {'error': str(error)}; code = 400
            body = json.dumps(result).encode()
            self.send_response(code); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
    HTTPServer(('127.0.0.1', a.port), Handler).serve_forever()
