#!/usr/bin/env python3
"""MLX LoRA entrypoint with the same non-thinking template as evaluation."""
from functools import partial
import mlx.core as mx
from mlx_lm import lora

mx.set_memory_limit(5 * 1024**3)
mx.set_cache_limit(512 * 1024**2)
original_load = lora.load

def load_nonthinking(*args, **kwargs):
    model, tokenizer = original_load(*args, **kwargs)
    tokenizer.apply_chat_template = partial(tokenizer.apply_chat_template, enable_thinking=False)
    # Masked training must use the exact inference prefix, including empty think tags.
    messages = [{'role': 'user', 'content': 'fixture'}, {'role': 'assistant', 'content': '{"action":"escalate"}'}]
    prefix = tokenizer.apply_chat_template(messages[:-1], add_generation_prompt=True)
    full = tokenizer.apply_chat_template(messages)
    if full[:len(prefix)] != prefix:
        raise ValueError('training template differs from inference prefix')
    return model, tokenizer

lora.load = load_nonthinking
lora.main()
