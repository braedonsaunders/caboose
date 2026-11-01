# Caboose AI (guest)

`caboose-ai.py` puts the phone's language models at `http://localhost:11434` inside the
computer, with the OpenAI API (`/v1/chat/completions`, `/v1/models`) and the Ollama API
(`/api/chat`, `/api/generate`, `/api/tags`, `/api/show`). Each request goes to the owner's
iPhone through the host, which holds one relay WebSocket to this service on port 14702, and
Apple's on-device model answers. Without the phone a request fails at once with 503, or goes
to the owner's fallback provider. It is Python 3 with `websockets` (Debian's
`python3-websockets`). The contract is [`docs/ai.md`](../../docs/ai.md).

| Variable | Default | Meaning |
| --- | --- | --- |
| `CABOOSE_AI_PORT` | `11434` | The API port, on loopback |
| `CABOOSE_AI_HOST` | `127.0.0.1` | The API address (`127.0.0.1` also listens on `::1`) |
| `CABOOSE_AI_RELAY_PORT` | `14702` | The host's relay port, on every interface |
| `CABOOSE_AI_TOKEN_FILE` | `/run/caboose/display-token` | The relay's bearer token, read on every connection |
| `CABOOSE_AI_CONFIG` | `~/.config/caboose/ai.json` | The owner's fallback provider, read on every request |

```json
{"fallback": {"baseUrl": "https://api.openai.com/v1", "apiKey": "sk-…", "model": "gpt-4.1-mini"}}
```

Only the host reaches port 14702: in the microVM through the vsock relay, in the container
on the computer's bridge address. Never publish it to a network.

## Install and run

Both guest images install it as `/opt/caboose/ai/caboose-ai.py` with `caboose-ai.service`
(enabled) in the microVM; in the container `caboose-components-services` starts it, and a
computer whose service cannot start still wakes. It is part of the guest components bundle
(`guest/components`), so the host installs and updates it at wake.

## Test

`python3 guest/ai/test_caboose_ai.py` (the host's suite runs it as `src/ai-logic.test.ts`).
The service tests need `python3-websockets`; the `openai` client test runs when the package
is installed. To try it in a throwaway container from a built guest image:

```sh
docker run -d --rm --name ai-check --entrypoint sleep <guest image> 600
docker cp guest/ai/caboose-ai.py ai-check:/tmp/
docker exec ai-check sh -c 'echo -n t > /tmp/t; CABOOSE_AI_TOKEN_FILE=/tmp/t python3 /tmp/caboose-ai.py & sleep 1;
  curl -si localhost:11434/v1/chat/completions -d "{\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}"'
docker rm -f ai-check
```

The last command answers `503 phone_unavailable`: no host or phone is connected.
