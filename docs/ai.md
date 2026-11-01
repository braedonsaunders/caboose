# Caboose AI

The phone's language models are a device of the computer. While Caboose is open on the
owner's iPhone, every program in the computer can use Apple's on-device model at
`http://localhost:11434`, with the OpenAI API (`/v1/chat/completions`) or the Ollama API
(`/api/chat`). Nothing is installed in the computer and nothing leaves the phone and the
computer: the request travels to the phone through the host, and the answer streams back.

```sh
curl -N localhost:11434/v1/chat/completions -d '{"model":"apple-foundation","stream":true,
  "messages":[{"role":"user","content":"Name three Canadian railways."}]}'
```

```python
from openai import OpenAI
client = OpenAI(base_url="http://localhost:11434/v1", api_key="unused")
for chunk in client.chat.completions.create(model="apple-foundation", stream=True,
                                            messages=[{"role": "user", "content": "Hi"}]):
    print(chunk.choices[0].delta.content or "", end="")
```

This document is the contract between the guest (`guest/ai`), the host
(`apps/host/src/ai.ts`) and the app (`apps/ios/Caboose/AI`, CabooseKit's `AI/`). Change it in
the same pull request as any code that changes it.

```
 program in the computer          caboose-ai (guest)            caboose-host               Caboose (iPhone)
 curl, openai, ollama clients ──▶ localhost:11434     ◀──WS──  /relay on :14702  ──WS──▶ /v1/ai  ──▶ Foundation Models
         ◀── SSE / NDJSON ──────  OpenAI + Ollama APIs          checks both ways          LanguageModelSession
```

## The headless rule

A computer works alone. When the phone is not there (Caboose closed or in the background,
On-Device AI off, Apple Intelligence off, or the phone out of reach), a request fails at
once with `503` and `Retry-After: 10`:

```json
{"error": {"type": "service_unavailable", "code": "phone_unavailable", "message": "The phone's models are not available: …"}}
```

A request in progress when the phone goes away ends with the same error (in a stream, as a
final `data: {"error": …}` event before `data: [DONE]`). The phone must say it took a request
within 10 seconds and send something at least every 120 seconds, or the request fails. No
request waits for a phone that is not there.

The owner can name a remote OpenAI-compatible provider used instead while the phone is away,
in `~/.config/caboose/ai.json` (keep it mode 0600; it holds a key):

```json
{"fallback": {"baseUrl": "https://api.openai.com/v1", "apiKey": "sk-…", "model": "gpt-4.1-mini"}}
```

With a fallback, a request for a model the phone does not have also goes to the fallback.

## Guest

`guest/ai/caboose-ai.py` (`/opt/caboose/ai/`, `caboose-ai.service` in the microVM, started by
`caboose-components-services` in the container) runs as `caboose`. It serves the API on
`127.0.0.1:11434` and `[::1]:11434`, and the host's relay WebSocket on port 14702. If another
program holds 11434 (Ollama itself), it tries again every 30 seconds and the relay stays up.
The loopback forwarder never puts 11434 on the computer's network address
([network](network.md)): the phone's models are for the computer's own programs.

Requests are refused (`403`) unless their `Host` is `localhost`, `127.0.0.1`, `[::1]` or
`0.0.0.0`, and a browser `Origin`, when present, is one of those: a web page cannot use the
phone's models through DNS rebinding or from another site. Bodies are at most 32 MiB.

| Method | Path | Answer |
| --- | --- | --- |
| `GET`, `HEAD` | `/` | `Caboose AI is running` |
| `GET` | `/v1/models`, `/v1/models/:id` | OpenAI model list (`context_window`, `capabilities` added); empty while the phone is away |
| `POST` | `/v1/chat/completions` | OpenAI chat completions, whole or streamed (`stream`, `stream_options.include_usage`) |
| `GET` | `/api/tags`, `/api/ps`, `/api/version` | Ollama model list; the Ollama API level answered (`0.12.0`) |
| `POST` | `/api/show` | Ollama model details, with `<id>.context_length` |
| `POST` | `/api/chat`, `/api/generate` | Ollama chat and generate, streamed by default (NDJSON) |
| `GET` | `/caboose/status` | `{ phone: "present" \| "away", models, fallback }` |
| `POST` | `/v1/embeddings`, `/v1/completions`, `/v1/responses`, `/api/embed`, `/api/embeddings` | `501 not_supported` |
| `POST` | `/api/pull`, `/api/push`, `/api/create`, `/api/copy`, `/api/delete` | `501 not_supported`: the phone manages its models |

The model may be named by its id, or as `default`, `caboose`, `phone` or empty for the
phone's first model. Any other name is `404 model_not_found`, listing the phone's models.

What each API's request carries over:

| OpenAI | Ollama | Internal |
| --- | --- | --- |
| `messages` (`system`, `developer`, `user`, `assistant`, `tool`), text and `image_url` parts | `messages` with `images`, or `prompt`, `system`, `images` | `messages` |
| `tools` (`function`), `tool_choice` | `tools` | `tools`, `toolChoice` |
| `temperature`, `top_p`, `seed`, `max_tokens` / `max_completion_tokens`, `stop` | `options.temperature`, `top_p`, `top_k`, `seed`, `num_predict`, `stop` | the same, camelCase |
| `response_format` `json_object`, `json_schema` | `format` `"json"` or a schema | `responseFormat` |

Images must be `data:` URLs (or Ollama's base64); the phone fetches nothing. `n` other than 1
is refused. Unknown fields are ignored.

### Requests

The internal request, which the host checks and the phone runs:

```ts
{
  model: string,                       // /^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$/
  messages: [{                         // 1–1024
    role: "system" | "user" | "assistant" | "tool",
    content: string | [{ type: "text", text } | { type: "image", mediaType, data /* base64 */ }],  // parts: user only, ≤ 64
    toolCalls?: [{ id, name, arguments /* JSON text */ }],   // assistant, ≤ 64
    toolCallId?: string                // tool, required
  }],
  tools?: [{ name /* [A-Za-z0-9_-]{1,64} */, description, parameters /* JSON Schema object */ }],  // ≤ 128
  toolChoice?: "auto" | "none" | "required" | { name },
  temperature?: number /* 0–2 */, topP?: number /* 0–1 */, topK?: integer /* 1–1000 */,
  seed?: integer, maxTokens?: integer /* 1–10⁶ */,
  responseFormat?: { type: "json", name?: string, schema?: object },
  stop?: string[]                      // ≤ 4, each ≤ 64 characters
}
```

Image types are PNG, JPEG, GIF, WebP and HEIC. JSON values (schemas) are at most 32 levels
deep and 64 KiB.

## Relay

caboose-ai and the host, on `ws://<computer>:14702/relay` with
`Authorization: Bearer <display token>` (the per-wake token of `/run/caboose/display-token`).
The host is the client. Messages are JSON text:

| From | Message |
| --- | --- |
| host | `{ type: "phone", models: [Model] }`: the phone's models; `[]` when no phone offers any |
| guest | `{ type: "request", id, request }`: `id` is 32 lowercase hex digits |
| guest | `{ type: "cancel", id }`: the program went away |
| host | `{ type: "started", id }`, `{ type: "delta", id, … }`, `{ type: "done", id, … }`, `{ type: "error", id, … }`: the phone's events, below |

The guest fails every pending request with `phone_unavailable` when the relay closes or the
models become `[]`. At most 16 requests run at once (`429` past that).

## Host

`apps/host/src/ai.ts`. The phone opens `GET /v1/ai` (WebSocket, no query) with its token. The
socket never wakes the computer or holds a lease. While the computer runs and at least one
phone socket has sent models, the host keeps the relay connection open (reconnecting after
0.5, 1, 2, 5 and then every 10 seconds), and tells the guest the models of the phone that
sent `hello` most recently; that phone takes new requests. The host:

- checks each guest request field by field (above) and re-encodes it with only those fields;
  an invalid one is answered `400 invalid_request` and never reaches the phone;
- checks each phone message field by field; a phone that breaks the contract is closed (4400);
- passes only events for requests it gave that phone, and forgets a request at `done` or
  `error`;
- answers `503 phone_unavailable` for each request of a phone whose socket closes;
- sends `cancel` to the phones for the guest's cancellations, and for every request when the
  relay drops.

Phone messages are at most 1 MiB; a request with its images, at most 32 MiB.

## Phone

`apps/ios/Caboose/AI`. The app opens `/v1/ai` when it connects to the computer in the
foreground and closes it in the background, unless **On-Device AI for Apps** is off in
Computer settings (on by default). It sends `hello` first:

```ts
{ type: "hello", models: [Model] }
Model = { id, name /* ≤ 100 */, contextSize, capabilities: ("tools" | "vision" | "json" | "reasoning")[],
          ownedBy?, family?, parameterSize?, quantization? }   // ≤ 16 models
```

The app offers `apple-foundation`, Apple's on-device model (`SystemLanguageModel.default`),
while it is available; `contextSize` is the model's own, and `family` its variant's name
(iOS 27). Without Apple Intelligence it offers no models, and the computer sees the phone as
away.

For each `request` the phone answers `started` at once, then:

```ts
{ type: "delta", id, content?: string, reasoning?: string,
  toolCalls?: [{ index /* 0–63 */, id?, name?, arguments? /* JSON text fragment */ }] }
{ type: "done", id, finishReason: "stop" | "length" | "tool_calls" | "content_filter",
  usage: { promptTokens, completionTokens, cachedTokens?, reasoningTokens? } }
{ type: "error", id, status: 400 | 404 | 413 | 429 | 500 | 503, code, message }
```

and stops working on a request at `cancel`.

How a request runs on Foundation Models:

- **Turns.** System messages become the session's instructions, the conversation before the
  last user message its transcript, and the last user message the prompt. Images in the
  prompt are attachments where the model takes images (iOS 27, `vision`), else `400`.
- **Context.** The prompt and answer share the model's window. Before running, the phone
  counts the transcript's tokens (iOS 26.4) and drops the oldest whole turns until the
  conversation fits with room for the answer (`maxTokens`, else a quarter of the window). A
  last message and instructions that do not fit are `400 context_length_exceeded`.
- **Streaming.** The answer streams as it is generated. Stop sequences are applied on the
  phone; text that could begin one is held back until it cannot. A structured answer
  (`responseFormat` with a schema) is sent whole when complete.
- **Structured answers and tool parameters.** JSON Schema becomes the model's generation
  schema (`AISchema`): objects, strings with `enum`/`const`, integers and numbers with
  `minimum`/`maximum`, booleans, arrays with `minItems`/`maxItems`, `anyOf`/`oneOf`,
  nullable types and `$ref` into `$defs`. `pattern`, `format` and `additionalProperties` are
  not enforced. A schema with nothing to guide by is `400 unsupported_schema`.
  `json_object` without a schema is asked for in the instructions, not guaranteed.
- **Tools.** The program's tools are the session's tools, and the program runs them. When the
  model calls tools, the request ends with the calls (`tool_calls`), ids `call_…`. The
  session waits up to 120 seconds for the program's next request carrying their results
  (`tool` messages with those ids) and then continues the same turn. A result that arrives
  later starts a new session of the turn in which a repeated call with the same arguments
  gets that result at once. `toolChoice` `none` offers no tools, `required` and `{ name }`
  require a call (iOS 27).
- **Refusals.** A guardrail or refusal ends the answer with `content_filter`. Other failures
  are errors: `context_length_exceeded`, `rate_limited` (429), `unsupported_language`,
  `model_unavailable` (503), `model_error` (500).
- **Sampling.** `temperature` 0 is greedy; `topK`, else `topP`, picks the random sampling
  mode, seeded with `seed`.

Only the foreground app serves: iOS suspends Caboose soon after it leaves the screen, and
Apple limits the model's use by apps in the background.

## Measuring

`apps/ios/scripts/check-on-device-ai.sh <device> [probes]` builds and installs
`apps/ios/AIProbe` (its own app, `com.braedonsaunders.caboose.ai-probe`) on a connected
iPhone and prints its measurements of Apple's model as JSON lines: availability and context
size, tokens per character, output speed and time to the first token, input (prefill) speed
at growing prompt sizes, the window's real edge, a session growing until it is full, guided
generation, tool calling with a delayed tool, images, reasoning, concurrent sessions and
Private Cloud Compute.

## Test

- `guest/ai/test_caboose_ai.py`: request translation, rendering, the fallback body, and the
  real service against a fake host and phone (streaming, Ollama, tool calls, errors, a phone
  that leaves or never answers, a program that leaves, the fallback provider, the `openai`
  client when installed). The host's suite runs it (`src/ai-logic.test.ts`).
- `apps/host/src/ai.test.ts`: message checks, and the relay with a fake guest and phone.
- `apps/ios/CabooseKit` `AITests.swift`: JSON, the phone messages, turns and context fitting,
  stop sequences, and JSON Schema conversion (`swift test --filter AI`).
