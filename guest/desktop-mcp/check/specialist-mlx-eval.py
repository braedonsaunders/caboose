#!/usr/bin/env python3
"""Replay held-out fixture observations; this is action prediction, not GUI success."""
import argparse
import json
import time
from pathlib import Path
import mlx.core as mx
from mlx_lm import load, stream_generate
from mlx_lm.sample_utils import make_sampler
p = argparse.ArgumentParser()
p.add_argument('--model', required=True)
p.add_argument('--adapter')
p.add_argument('--data', required=True)
p.add_argument('--output', required=True)
p.add_argument('--limit', type=int, default=80)
a = p.parse_args()
mx.set_memory_limit(5 * 1024**3)
mx.set_cache_limit(512 * 1024**2)
model, tokenizer = load(a.model, adapter_path=a.adapter)
rows = [json.loads(line) for line in Path(a.data).read_text().splitlines()][:a.limit]
with open(a.output, 'x') as out:
    for index, row in enumerate(rows):
        prompt = tokenizer.apply_chat_template(row['messages'][:-1], tokenize=False, add_generation_prompt=True, enable_thinking=False)
        started = time.perf_counter()
        text = ''
        for response in stream_generate(model, tokenizer, prompt=prompt, max_tokens=128, sampler=make_sampler(temp=0)):
            text += response.text
        elapsed = (time.perf_counter() - started) * 1000
        expected = json.loads(row['messages'][-1]['content'])
        try:
            choice = json.loads(text)
        except (ValueError, TypeError):
            choice = None
        result = dict(index=index, exact=choice == expected, choice=choice, expected=expected, raw=text,
                      elapsedMs=elapsed, promptTokens=response.prompt_tokens, generationTokens=response.generation_tokens,
                      peakMemoryBytes=mx.get_peak_memory())
        out.write(json.dumps(result) + '\n'); out.flush()
        print(json.dumps({k: result[k] for k in ['index', 'exact', 'elapsedMs', 'promptTokens', 'peakMemoryBytes']}), flush=True)
