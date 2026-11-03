#!/usr/bin/env python3
"""Local MLX decision service: one constrained token per decision, KV cache kept across steps.

Requests carry choices.mjs's rendered `prompt` and the number of `choices`.

Serves the choice backend's `/v1/decision` contract on loopback, or scores replay rows with
`--data ROWS --output RESULTS` (repeatable). It has no UI or execution access.
"""
import argparse
import json
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
import mlx.core as mx
from mlx_lm import load
from mlx_lm.models.cache import make_prompt_cache, trim_prompt_cache
LETTERS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef'  # choices.mjs decisionPrompt

p = argparse.ArgumentParser()
p.add_argument('--model', required=True)
p.add_argument('--data', action='append', default=[])
p.add_argument('--output', action='append', default=[])
p.add_argument('--port', type=int, default=11435)
p.add_argument('--no-cache-reuse', action='store_true', help='prefill every request from empty (for measurement)')
a = p.parse_args()
model, tokenizer = load(a.model)
letter_ids = [tokenizer.encode(' ' + letter, add_special_tokens=False) for letter in LETTERS]
assert all(len(ids) == 1 for ids in letter_ids), 'choice letters must be single tokens'
letter_ids = [ids[0] for ids in letter_ids]


class Decider:
    def __init__(self):
        self.cache, self.tokens = make_prompt_cache(model), []

    def __call__(self, request):
        prompt, choices = request['prompt'], request['choices']
        if isinstance(choices, list): choices = len(choices)
        if not isinstance(prompt, str) or len(prompt) > 16000 or not isinstance(choices, int) or not 2 <= choices <= len(LETTERS):
            raise ValueError('invalid bounded decision')
        started = time.perf_counter()
        ids = tokenizer.encode(prompt, add_special_tokens=False)
        if len(ids) > 2048: raise ValueError('decision prompt exceeds 2048 tokens; narrow the task')
        common = 0
        if not a.no_cache_reuse:
            for old, new in zip(self.tokens, ids):
                if old != new: break
                common += 1
            common = min(common, len(ids) - 1)
        trim_prompt_cache(self.cache, len(self.tokens) - common) if self.tokens else None
        if a.no_cache_reuse: self.cache = make_prompt_cache(model)
        logits = model(mx.array(ids[common:])[None], cache=self.cache)[0, -1]
        allowed = logits[mx.array(letter_ids[:choices])]
        probabilities = mx.softmax(allowed.astype(mx.float32))
        mx.eval(probabilities)
        self.tokens = ids
        ranked = sorted(probabilities.tolist(), reverse=True)
        choice = int(mx.argmax(probabilities).item())
        # `margin`: the chosen letter's probability less the runner-up's, the fast path's confidence.
        return {'revision': request.get('revision'), 'choice': choice, 'confidence': round(ranked[0], 4), 'margin': round(ranked[0] - ranked[1], 4),
                'elapsedMs': (time.perf_counter() - started) * 1000, 'promptTokens': len(ids), 'cachedTokens': common}


decide = Decider()
decide({'prompt': 'Task: warm up\nA BLOCKED\nB PRESS OK (button)\nNext:', 'choices': 2})
if a.data:
    if len(a.output) != len(a.data): raise ValueError('one --output required for each --data')
    for data, output in zip(a.data, a.output):
        with open(output, 'x') as out:
            for index, line in enumerate(Path(data).read_text().splitlines()):
                row = json.loads(line)
                try:
                    result = decide(row)
                    result['acceptable'] = result['choice'] in row.get('acceptable', [row['expected']])
                except Exception as error:
                    result = {'acceptable': False, 'error': str(error)}
                out.write(json.dumps({'index': index, **result}) + '\n'); out.flush()
else:
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_): pass

        def do_POST(self):
            try:
                length = int(self.headers.get('Content-Length', '0'))
                if self.path != '/v1/decision' or not 0 < length <= 32768: raise ValueError('invalid request')
                result, code = decide(json.loads(self.rfile.read(length))), 200
            except Exception as error:
                result, code = {'error': str(error)}, 400
            body = json.dumps(result).encode()
            self.send_response(code); self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body))); self.end_headers(); self.wfile.write(body)
    HTTPServer(('127.0.0.1', a.port), Handler).serve_forever()
