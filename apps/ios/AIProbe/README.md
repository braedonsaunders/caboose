# AI probe

A small iOS app that measures Apple's on-device language model on the phone it runs on, for
[Caboose AI](../../../docs/ai.md#measuring). It has its own bundle id
(`com.braedonsaunders.caboose.ai-probe`), so installing it never replaces Caboose.

```sh
scripts/check-on-device-ai.sh <device id> [probe,probe…] > results.jsonl
```

The script generates the project (`xcodegen`), builds, installs and launches the probe with
`devicectl --console`, and prints each measurement as one JSON line. The phone must be
unlocked with Developer Mode on; the probe comes to the foreground. Results are also kept in
the probe's `Documents/probe.jsonl`.

Probes: `info` (availability, context size, variant, capabilities), `tokens` (characters
per token), `throughput` (time to first token and output tokens per second, cold, warm and
prewarmed), `prefill` (time to first token for prompts up to the window), `context` (prompts
just inside and outside the window), `session` (one session until its transcript is full),
`guided` (a run-time schema), `tools` (a run-time tool schema, a tool answering after 3 s,
required tool calls), `vision`, `reasoning`, `concurrency` (two sessions at once, and a second
request to a busy session) and `pcc` (Private Cloud Compute).
