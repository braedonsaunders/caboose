#!/usr/bin/env python3
"""The phone's language models as a local model server inside the computer.

Programs in the computer talk to `http://localhost:11434` with the OpenAI API
(`/v1/chat/completions`, `/v1/models`) or the Ollama API (`/api/chat`, `/api/generate`,
`/api/tags`, `/api/show`). Each request travels to the owner's iPhone through the host, which
holds one relay WebSocket to this service on port 14702, and the phone answers with Apple's
on-device model. When the phone is not there, a request fails at once with 503 and says so,
or goes to the remote OpenAI-compatible provider the owner configured. The contract is in
docs/ai.md.
"""
import asyncio
import base64
import binascii
import hashlib
import hmac
import json
import os
import re
import secrets
import signal
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from http import HTTPStatus
from urllib.parse import urlsplit

TOKEN = os.environ.get('CABOOSE_AI_TOKEN_FILE', '/run/caboose/display-token')
RELAY_PORT = int(os.environ.get('CABOOSE_AI_RELAY_PORT', '14702'))
API_HOST = os.environ.get('CABOOSE_AI_HOST', '127.0.0.1')
API_PORT = int(os.environ.get('CABOOSE_AI_PORT', '11434'))
CONFIG = os.environ.get('CABOOSE_AI_CONFIG', os.path.expanduser('~/.config/caboose/ai.json'))

MAX_BODY = 32 * 1024 * 1024
MAX_HEADERS = 64 * 1024
MAX_MESSAGES = 1024
MAX_TOOLS = 128
MAX_IMAGES = 16
MAX_PENDING = 16
# The phone says it took a request (`started`) within this long, or the request fails.
ACCEPT_SECONDS = 10
# A request the phone has taken fails when nothing arrives for this long.
IDLE_SECONDS = 120
REQUEST_ID = re.compile(r'[0-9a-f]{32}')
MODEL_ID = re.compile(r'[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}')
TOOL_NAME = re.compile(r'[A-Za-z0-9_-]{1,64}')
ROLES = {'system', 'developer', 'user', 'assistant', 'tool'}
IMAGE_TYPES = {'image/png', 'image/jpeg', 'image/gif', 'image/webp', 'image/heic'}
# Names a program may use for "whatever the phone runs": they select the phone's first model.
DEFAULT_MODELS = {'', 'default', 'caboose', 'phone'}
LOCAL_HOSTS = {'localhost', '127.0.0.1', '[::1]', '0.0.0.0'}
OLLAMA_VERSION = '0.12.0'


class ApiError(Exception):
    def __init__(self, status, code, message, kind='invalid_request_error'):
        super().__init__(message)
        self.status, self.code, self.message, self.kind = status, code, message, kind

    def body(self):
        return {'error': {'message': self.message, 'type': self.kind, 'code': self.code, 'param': None}}


def bad(message, code='invalid_request'):
    return ApiError(HTTPStatus.BAD_REQUEST, code, message)


def unavailable(message):
    return ApiError(HTTPStatus.SERVICE_UNAVAILABLE, 'phone_unavailable', message, 'service_unavailable')


PHONE_AWAY = ('The phone\'s models are not available: Caboose is not open on the owner\'s iPhone, '
              'On-Device AI is off in its settings, or Apple Intelligence is off. Open Caboose on the '
              'iPhone and try again, or set a fallback provider in ~/.config/caboose/ai.json.')


# ---------------------------------------------------------------------------------------------
# Requests. Both APIs become one internal request (docs/ai.md § Requests), which is what the
# host checks and the phone runs.


def number(value, name, low, high):
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not low <= value <= high:
        raise bad(f'{name} must be a number from {low} to {high}')
    return value


def integer(value, name, low, high):
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, int) or not low <= value <= high:
        raise bad(f'{name} must be an integer from {low} to {high}')
    return value


def data_image(url):
    """A `data:image/...;base64,` URL → {type: image, mediaType, data}. Other URLs are refused."""
    match = re.fullmatch(r'data:([a-z]+/[a-z0-9.+-]+);base64,(.*)', url, re.S)
    if not match:
        raise bad('images must be data: URLs (data:image/png;base64,...); the phone does not fetch URLs')
    return raw_image(match.group(2), match.group(1))


def raw_image(data, media_type=None):
    try:
        raw = base64.b64decode(data, validate=True)
    except (binascii.Error, ValueError):
        raise bad('an image is not valid base64') from None
    if media_type is None:
        media_type = sniff(raw)
    if media_type not in IMAGE_TYPES:
        raise bad(f'unsupported image type {media_type}; use PNG, JPEG, GIF, WebP or HEIC')
    return {'type': 'image', 'mediaType': media_type, 'data': base64.b64encode(raw).decode()}


def sniff(raw):
    if raw.startswith(b'\x89PNG'):
        return 'image/png'
    if raw.startswith(b'\xff\xd8'):
        return 'image/jpeg'
    if raw.startswith(b'GIF8'):
        return 'image/gif'
    if raw[:4] == b'RIFF' and raw[8:12] == b'WEBP':
        return 'image/webp'
    if raw[4:12] in (b'ftypheic', b'ftypheix', b'ftypmif1'):
        return 'image/heic'
    return 'application/octet-stream'


def openai_content(content, role):
    """A message's content: a string, or a list of text and image parts."""
    if content is None:
        return ''
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        raise bad('content must be a string or a list of parts')
    parts = []
    for part in content:
        kind = part.get('type') if isinstance(part, dict) else None
        if kind in ('text', 'input_text') and isinstance(part.get('text'), str):
            parts.append({'type': 'text', 'text': part['text']})
        elif kind == 'image_url' and role == 'user':
            image = part.get('image_url')
            url = image.get('url') if isinstance(image, dict) else image
            if not isinstance(url, str):
                raise bad('image_url needs a url')
            parts.append(data_image(url))
        else:
            raise bad(f'unsupported content part {kind!r} in a {role} message')
    if all(part['type'] == 'text' for part in parts):
        return ''.join(part['text'] for part in parts)
    return parts


def tool_arguments(value):
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        return json.dumps(value)
    raise bad('tool call arguments must be a JSON string')


def openai_messages(messages):
    if not isinstance(messages, list) or not messages:
        raise bad('messages must be a non-empty list')
    if len(messages) > MAX_MESSAGES:
        raise bad(f'at most {MAX_MESSAGES} messages')
    result = []
    for message in messages:
        if not isinstance(message, dict) or message.get('role') not in ROLES:
            raise bad('each message needs a role: system, developer, user, assistant or tool')
        role = 'system' if message['role'] == 'developer' else message['role']
        out = {'role': role, 'content': openai_content(message.get('content'), role)}
        if role == 'assistant' and message.get('tool_calls'):
            calls = message['tool_calls']
            if not isinstance(calls, list):
                raise bad('tool_calls must be a list')
            out['toolCalls'] = []
            for call in calls:
                function = call.get('function') if isinstance(call, dict) else None
                if not isinstance(function, dict) or not isinstance(call.get('id'), str) or not isinstance(function.get('name'), str):
                    raise bad('each tool call needs an id and a function name')
                out['toolCalls'].append({'id': call['id'][:128], 'name': function['name'], 'arguments': tool_arguments(function.get('arguments', '{}'))})
        if role == 'tool':
            if not isinstance(message.get('tool_call_id'), str):
                raise bad('a tool message needs tool_call_id')
            out['toolCallId'] = message['tool_call_id'][:128]
        result.append(out)
    if sum(isinstance(m['content'], list) and sum(p['type'] == 'image' for p in m['content']) for m in result) > MAX_IMAGES:
        raise bad(f'at most {MAX_IMAGES} images in a request')
    return result


def openai_tools(tools):
    if tools is None:
        return None
    if not isinstance(tools, list) or len(tools) > MAX_TOOLS:
        raise bad(f'tools must be a list of at most {MAX_TOOLS}')
    result = []
    for tool in tools:
        function = tool.get('function') if isinstance(tool, dict) and tool.get('type', 'function') == 'function' else None
        if not isinstance(function, dict) or not isinstance(function.get('name'), str) or not TOOL_NAME.fullmatch(function['name']):
            raise bad('each tool must be {type: "function", function: {name, description, parameters}} with a name of letters, digits, _ and -')
        parameters = function.get('parameters', {'type': 'object', 'properties': {}})
        if not isinstance(parameters, dict):
            raise bad('tool parameters must be a JSON Schema object')
        result.append({'name': function['name'], 'description': str(function.get('description', ''))[:4000], 'parameters': parameters})
    return result or None


def openai_tool_choice(choice):
    if choice is None or choice in ('auto', 'none', 'required'):
        return choice
    if isinstance(choice, dict) and isinstance(choice.get('function'), dict) and isinstance(choice['function'].get('name'), str):
        return {'name': choice['function']['name']}
    raise bad('tool_choice must be auto, none, required or {type: "function", function: {name}}')


def openai_format(value):
    if value is None:
        return None
    if not isinstance(value, dict):
        raise bad('response_format must be an object')
    if value.get('type') == 'text':
        return None
    if value.get('type') == 'json_object':
        return {'type': 'json'}
    if value.get('type') == 'json_schema' and isinstance(value.get('json_schema'), dict) and isinstance(value['json_schema'].get('schema'), dict):
        spec = value['json_schema']
        return {'type': 'json', 'name': str(spec.get('name', 'response'))[:64], 'schema': spec['schema']}
    raise bad('response_format must be text, json_object or json_schema with a schema')


def stops(value):
    if value is None:
        return None
    value = [value] if isinstance(value, str) else value
    if not isinstance(value, list) or len(value) > 4 or not all(isinstance(s, str) and 0 < len(s) <= 64 for s in value):
        raise bad('stop must be a string or up to 4 strings')
    return value


def clean(request):
    return {key: value for key, value in request.items() if value is not None}


def parse_openai_chat(body):
    """An OpenAI chat completions body → (request, stream, include usage in the stream)."""
    if not isinstance(body, dict):
        raise bad('the body must be a JSON object')
    model = body.get('model', '')
    if not isinstance(model, str):
        raise bad('model must be a string')
    max_tokens = body.get('max_completion_tokens', body.get('max_tokens'))
    if body.get('n', 1) != 1:
        raise bad('n must be 1')
    request = clean({
        'model': model,
        'messages': openai_messages(body.get('messages')),
        'tools': openai_tools(body.get('tools')),
        'toolChoice': openai_tool_choice(body.get('tool_choice')),
        'temperature': number(body.get('temperature'), 'temperature', 0, 2),
        'topP': number(body.get('top_p'), 'top_p', 0, 1),
        'seed': integer(body.get('seed'), 'seed', 0, 2 ** 63 - 1),
        'maxTokens': integer(max_tokens, 'max_tokens', 1, 1_000_000),
        'responseFormat': openai_format(body.get('response_format')),
        'stop': stops(body.get('stop')),
    })
    stream = body.get('stream', False) is True
    options = body.get('stream_options') if isinstance(body.get('stream_options'), dict) else {}
    return request, stream, options.get('include_usage') is True


def ollama_options(body, request):
    options = body.get('options') if isinstance(body.get('options'), dict) else {}
    request['temperature'] = number(options.get('temperature'), 'temperature', 0, 2)
    request['topP'] = number(options.get('top_p'), 'top_p', 0, 1)
    request['topK'] = integer(options.get('top_k'), 'top_k', 1, 1000)
    request['seed'] = integer(options.get('seed'), 'seed', 0, 2 ** 63 - 1)
    predict = options.get('num_predict')
    request['maxTokens'] = integer(predict, 'num_predict', 1, 1_000_000) if predict not in (None, -1, -2) else None
    request['stop'] = stops(options.get('stop'))
    fmt = body.get('format')
    if fmt == 'json':
        request['responseFormat'] = {'type': 'json'}
    elif isinstance(fmt, dict):
        request['responseFormat'] = {'type': 'json', 'name': 'response', 'schema': fmt}
    elif fmt not in (None, ''):
        raise bad('format must be "json" or a JSON Schema')
    return clean(request)


def ollama_message(message):
    if not isinstance(message, dict) or message.get('role') not in ROLES:
        raise bad('each message needs a role')
    role = 'system' if message['role'] == 'developer' else message['role']
    content = message.get('content', '')
    if not isinstance(content, str):
        raise bad('content must be a string')
    images = message.get('images') or []
    if not isinstance(images, list):
        raise bad('images must be a list of base64 strings')
    out = {'role': role, 'content': ([{'type': 'text', 'text': content}] if content else []) + [raw_image(i) for i in images] if images else content}
    if role == 'assistant' and message.get('tool_calls'):
        out['toolCalls'] = []
        for index, call in enumerate(message['tool_calls']):
            function = call.get('function') if isinstance(call, dict) else None
            if not isinstance(function, dict) or not isinstance(function.get('name'), str):
                raise bad('each tool call needs a function name')
            out['toolCalls'].append({'id': call.get('id') or f'call_{index}', 'name': function['name'], 'arguments': tool_arguments(function.get('arguments', {}))})
    if role == 'tool':
        out['toolCallId'] = str(message.get('tool_call_id') or message.get('tool_name') or '')
    return out


def parse_ollama_chat(body):
    if not isinstance(body, dict) or not isinstance(body.get('model', ''), str):
        raise bad('the body must be a JSON object with a model')
    messages = body.get('messages')
    if not isinstance(messages, list) or not messages or len(messages) > MAX_MESSAGES:
        raise bad('messages must be a non-empty list')
    request = {'model': body.get('model', ''), 'messages': [ollama_message(m) for m in messages], 'tools': openai_tools(body.get('tools'))}
    return ollama_options(body, request), body.get('stream', True) is not False


def parse_ollama_generate(body):
    if not isinstance(body, dict) or not isinstance(body.get('model', ''), str):
        raise bad('the body must be a JSON object with a model')
    prompt, system = body.get('prompt', ''), body.get('system')
    if not isinstance(prompt, str) or (system is not None and not isinstance(system, str)):
        raise bad('prompt and system must be strings')
    messages = ([{'role': 'system', 'content': system}] if system else [])
    messages.append(ollama_message({'role': 'user', 'content': prompt, 'images': body.get('images')}))
    request = {'model': body.get('model', ''), 'messages': messages}
    return ollama_options(body, request), body.get('stream', True) is not False


MAX_INPUTS = 256
MAX_INPUT = 32_000


def embedding_inputs(value):
    """`input` of an embeddings request: a string or a list of strings."""
    inputs = [value] if isinstance(value, str) else value
    if not isinstance(inputs, list) or not inputs or len(inputs) > MAX_INPUTS or not all(isinstance(i, str) for i in inputs):
        raise bad(f'input must be a string or a list of 1 to {MAX_INPUTS} strings (token arrays are not supported)')
    if any(len(i) > MAX_INPUT for i in inputs):
        raise bad(f'each input is at most {MAX_INPUT} characters')
    return inputs


def parse_openai_embeddings(body):
    if not isinstance(body, dict) or not isinstance(body.get('model', ''), str):
        raise bad('the body must be a JSON object with a model')
    encoding = body.get('encoding_format', 'float')
    if encoding not in ('float', 'base64'):
        raise bad('encoding_format must be float or base64')
    dimensions = integer(body.get('dimensions'), 'dimensions', 1, 8192)
    return {'model': body.get('model', ''), 'input': embedding_inputs(body.get('input'))}, encoding, dimensions


def shorten(vector, dimensions):
    """A vector cut to `dimensions` and normalized again, as OpenAI's `dimensions` does."""
    if dimensions is None or dimensions >= len(vector):
        return vector
    cut = vector[:dimensions]
    norm = sum(v * v for v in cut) ** 0.5 or 1.0
    return [v / norm for v in cut]


def base64_vector(vector):
    import struct
    return base64.b64encode(struct.pack(f'<{len(vector)}f', *vector)).decode()


# ---------------------------------------------------------------------------------------------
# The phone, through the host's relay connection.


def valid_model(model):
    return (isinstance(model, dict) and isinstance(model.get('id'), str) and MODEL_ID.fullmatch(model['id'])
            and isinstance(model.get('name'), str) and isinstance(model.get('contextSize'), int)
            and isinstance(model.get('capabilities'), list))


class Phone:
    """The phone as the host presents it: its models while it is there, and the requests it runs."""

    def __init__(self):
        self.connection = None
        self.models = []
        self.pending = {}

    @property
    def present(self):
        return self.connection is not None and bool(self.models)

    def model(self, name, kind='chat'):
        """The phone's model of this kind (`chat` or `embedding`) by name; a default name picks its first."""
        models = [m for m in self.models if m.get('type', 'chat') == kind]
        if not models:
            return None
        if name in DEFAULT_MODELS:
            return models[0]
        return next((m for m in models if m['id'] == name), None)

    def find(self, name):
        return self.model(name, 'chat') or self.model(name, 'embedding') if name not in DEFAULT_MODELS else self.model(name)

    async def send(self, message):
        connection = self.connection
        if connection is None:
            raise unavailable(PHONE_AWAY)
        try:
            await connection.send(json.dumps(message))
        except Exception:
            raise unavailable(PHONE_AWAY) from None

    async def generate(self, request, kind='request'):
        """Runs a request (`request`, or `embed`) on the phone, yielding its events until `done`; raises ApiError."""
        if not self.present:
            raise unavailable(PHONE_AWAY)
        if len(self.pending) >= MAX_PENDING:
            raise ApiError(HTTPStatus.TOO_MANY_REQUESTS, 'too_many_requests', f'at most {MAX_PENDING} requests at once', 'rate_limit_error')
        rid = secrets.token_hex(16)
        queue = asyncio.Queue()
        self.pending[rid] = queue
        try:
            await self.send({'type': kind, 'id': rid, 'request': request})
            started = False
            while True:
                try:
                    event = await asyncio.wait_for(queue.get(), IDLE_SECONDS if started else ACCEPT_SECONDS)
                except asyncio.TimeoutError:
                    raise unavailable('The phone did not answer in time.' if not started else
                                      f'The phone sent nothing for {IDLE_SECONDS} seconds.') from None
                if event['type'] == 'started':
                    started = True
                    continue
                if event['type'] == 'error':
                    raise event['error']
                yield event
                if event['type'] == 'done':
                    return
        finally:
            if self.pending.pop(rid, None) is not None and not getattr(queue, 'finished', False):
                # The program went away (or the phone failed): the phone stops working on it.
                try:
                    await self.send({'type': 'cancel', 'id': rid})
                except ApiError:
                    pass

    def deliver(self, message):
        """One message from the host: the phone's models, or an event for a pending request."""
        kind = message.get('type') if isinstance(message, dict) else None
        if kind == 'phone':
            models = message.get('models')
            self.models = [m for m in models if valid_model(m)] if isinstance(models, list) else []
            if not self.models:
                self.fail_all(PHONE_AWAY)
            return
        rid = message.get('id') if isinstance(message, dict) else None
        queue = self.pending.get(rid) if isinstance(rid, str) else None
        if queue is None:
            return
        if kind == 'started':
            queue.put_nowait({'type': 'started'})
        elif kind == 'delta':
            event = {'type': 'delta'}
            if isinstance(message.get('content'), str):
                event['content'] = message['content']
            if isinstance(message.get('reasoning'), str):
                event['reasoning'] = message['reasoning']
            if isinstance(message.get('toolCalls'), list):
                event['toolCalls'] = [c for c in message['toolCalls'] if isinstance(c, dict) and isinstance(c.get('index'), int)]
            queue.put_nowait(event)
        elif kind == 'vector':
            values = message.get('values')
            if isinstance(message.get('index'), int) and isinstance(values, list) and all(isinstance(v, (int, float)) and not isinstance(v, bool) for v in values):
                queue.put_nowait({'type': 'vector', 'index': message['index'], 'values': [float(v) for v in values]})
        elif kind == 'done':
            usage = message.get('usage') if isinstance(message.get('usage'), dict) else {}
            queue.finished = True
            queue.put_nowait({'type': 'done', 'finishReason': message.get('finishReason') if message.get('finishReason') in ('stop', 'length', 'tool_calls', 'content_filter') else 'stop',
                              'usage': {k: usage[k] for k in ('promptTokens', 'completionTokens', 'cachedTokens', 'reasoningTokens') if isinstance(usage.get(k), int)}})
        elif kind == 'error':
            status = message.get('status') if message.get('status') in (400, 404, 413, 429, 500, 503) else 500
            code = message.get('code') if isinstance(message.get('code'), str) else 'phone_error'
            text = message.get('message') if isinstance(message.get('message'), str) else 'The phone could not answer.'
            queue.finished = True
            queue.put_nowait({'type': 'error', 'error': ApiError(status, code[:64], text[:2000], 'server_error' if status >= 500 else 'invalid_request_error')})

    def fail_all(self, text):
        for queue in self.pending.values():
            queue.finished = True
            queue.put_nowait({'type': 'error', 'error': unavailable(text)})

    async def serve_relay(self, connection):
        """The host's relay connection; a new one replaces the old."""
        previous, self.connection = self.connection, connection
        if previous is not None:
            await previous.close(4001, 'replaced')
        try:
            async for raw in connection:
                if isinstance(raw, str):
                    try:
                        self.deliver(json.loads(raw))
                    except ValueError:
                        pass
        finally:
            if self.connection is connection:
                self.connection = None
                self.models = []
                self.fail_all(PHONE_AWAY)


# ---------------------------------------------------------------------------------------------
# The owner's fallback provider: an OpenAI-compatible API used while the phone is away.


def load_fallback(path=None):
    try:
        with open(path or CONFIG) as f:
            config = json.load(f)
    except (OSError, ValueError):
        return None
    fallback = config.get('fallback') if isinstance(config, dict) else None
    if not isinstance(fallback, dict) or not isinstance(fallback.get('baseUrl'), str) or not re.match(r'https?://', fallback['baseUrl']):
        return None
    return {'baseUrl': fallback['baseUrl'].rstrip('/'), 'apiKey': str(fallback.get('apiKey', '')), 'model': str(fallback.get('model', ''))}


def openai_body(request, model, stream=True):
    """The internal request as an OpenAI chat completions body, for the fallback provider."""
    def content(value):
        if isinstance(value, str):
            return value
        return [{'type': 'text', 'text': p['text']} if p['type'] == 'text' else
                {'type': 'image_url', 'image_url': {'url': f"data:{p['mediaType']};base64,{p['data']}"}} for p in value]
    messages = []
    for m in request['messages']:
        out = {'role': m['role'], 'content': content(m['content'])}
        if m.get('toolCalls'):
            out['tool_calls'] = [{'id': c['id'], 'type': 'function', 'function': {'name': c['name'], 'arguments': c['arguments']}} for c in m['toolCalls']]
        if m['role'] == 'tool':
            out['tool_call_id'] = m.get('toolCallId', '')
        messages.append(out)
    body = {'model': model, 'messages': messages, 'stream': stream}
    if stream:
        body['stream_options'] = {'include_usage': True}
    for key, name in (('temperature', 'temperature'), ('topP', 'top_p'), ('seed', 'seed'), ('maxTokens', 'max_tokens'), ('stop', 'stop')):
        if key in request:
            body[name] = request[key]
    if request.get('tools'):
        body['tools'] = [{'type': 'function', 'function': t} for t in request['tools']]
    choice = request.get('toolChoice')
    if choice is not None:
        body['tool_choice'] = {'type': 'function', 'function': choice} if isinstance(choice, dict) else choice
    fmt = request.get('responseFormat')
    if fmt:
        body['response_format'] = {'type': 'json_schema', 'json_schema': {'name': fmt.get('name', 'response'), 'schema': fmt['schema']}} if 'schema' in fmt else {'type': 'json_object'}
    return body


def fallback_events(chunk):
    """One streamed OpenAI chunk → internal events."""
    events = []
    for choice in chunk.get('choices') or []:
        delta = choice.get('delta') or {}
        event = {'type': 'delta'}
        if isinstance(delta.get('content'), str) and delta['content']:
            event['content'] = delta['content']
        reasoning = delta.get('reasoning_content') or delta.get('reasoning')
        if isinstance(reasoning, str) and reasoning:
            event['reasoning'] = reasoning
        if isinstance(delta.get('tool_calls'), list):
            event['toolCalls'] = [{'index': c.get('index', 0), **({'id': c['id']} if c.get('id') else {}),
                                   **({'name': c['function']['name']} if (c.get('function') or {}).get('name') else {}),
                                   'arguments': (c.get('function') or {}).get('arguments') or ''} for c in delta['tool_calls'] if isinstance(c, dict)]
        if len(event) > 1:
            events.append(event)
        if choice.get('finish_reason'):
            events.append({'type': 'finish', 'finishReason': choice['finish_reason']})
    if isinstance(chunk.get('usage'), dict):
        u = chunk['usage']
        events.append({'type': 'usage', 'usage': {'promptTokens': u.get('prompt_tokens', 0), 'completionTokens': u.get('completion_tokens', 0)}})
    return events


async def fallback_generate(fallback, request):
    """Runs a request on the fallback provider, yielding the same events as the phone."""
    model = fallback['model'] or request['model']
    body = json.dumps(openai_body(request, model)).encode()
    headers = {'Content-Type': 'application/json', 'Accept': 'text/event-stream'}
    if fallback['apiKey']:
        headers['Authorization'] = f"Bearer {fallback['apiKey']}"
    loop = asyncio.get_running_loop()
    queue = asyncio.Queue()
    stop = threading.Event()

    def worker():
        try:
            call = urllib.request.Request(fallback['baseUrl'] + '/chat/completions', data=body, headers=headers, method='POST')
            with urllib.request.urlopen(call, timeout=IDLE_SECONDS) as response:
                for line in response:
                    if stop.is_set():
                        return
                    line = line.strip()
                    if not line.startswith(b'data:'):
                        continue
                    data = line[5:].strip()
                    if data == b'[DONE]':
                        break
                    loop.call_soon_threadsafe(queue.put_nowait, ('chunk', json.loads(data)))
            loop.call_soon_threadsafe(queue.put_nowait, ('end', None))
        except urllib.error.HTTPError as error:
            detail = error.read(2000).decode('utf-8', 'replace')
            loop.call_soon_threadsafe(queue.put_nowait, ('error', ApiError(HTTPStatus.BAD_GATEWAY, 'fallback_error', f'The fallback provider answered {error.code}: {detail}', 'server_error')))
        except Exception as error:  # noqa: BLE001 - every failure is reported to the program
            loop.call_soon_threadsafe(queue.put_nowait, ('error', ApiError(HTTPStatus.BAD_GATEWAY, 'fallback_error', f'The fallback provider failed: {error}', 'server_error')))

    threading.Thread(target=worker, daemon=True).start()
    finish, usage = 'stop', {}
    try:
        while True:
            kind, value = await queue.get()
            if kind == 'error':
                raise value
            if kind == 'end':
                break
            for event in fallback_events(value):
                if event['type'] == 'finish':
                    finish = event['finishReason']
                elif event['type'] == 'usage':
                    usage = event['usage']
                else:
                    yield event
        yield {'type': 'done', 'finishReason': finish, 'usage': usage}
    finally:
        stop.set()


async def fallback_embed(fallback, request):
    """Embeddings from the fallback provider, as the phone's events."""
    body = json.dumps({'model': fallback['model'] or request['model'], 'input': request['input']}).encode()
    headers = {'Content-Type': 'application/json'}
    if fallback['apiKey']:
        headers['Authorization'] = f"Bearer {fallback['apiKey']}"

    def call():
        try:
            with urllib.request.urlopen(urllib.request.Request(fallback['baseUrl'] + '/embeddings', data=body, headers=headers, method='POST'), timeout=IDLE_SECONDS) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            raise ApiError(HTTPStatus.BAD_GATEWAY, 'fallback_error', f'The fallback provider answered {error.code}: {error.read(2000).decode("utf-8", "replace")}', 'server_error') from None
        except Exception as error:  # noqa: BLE001 - every failure is reported to the program
            raise ApiError(HTTPStatus.BAD_GATEWAY, 'fallback_error', f'The fallback provider failed: {error}', 'server_error') from None
    answer = await asyncio.to_thread(call)
    for item in answer.get('data') or []:
        yield {'type': 'vector', 'index': item.get('index', 0), 'values': [float(v) for v in item.get('embedding') or []]}
    usage = answer.get('usage') or {}
    yield {'type': 'done', 'finishReason': 'stop', 'usage': {'promptTokens': usage.get('prompt_tokens', 0), 'completionTokens': 0}}


# ---------------------------------------------------------------------------------------------
# Answers in each API's shape.


class Collected:
    """A whole answer from a stream of events."""

    def __init__(self):
        self.content, self.reasoning, self.calls, self.finish, self.usage = '', '', {}, 'stop', {}

    def add(self, event):
        if event['type'] == 'done':
            self.finish, self.usage = event['finishReason'], event['usage']
            return
        self.content += event.get('content', '')
        self.reasoning += event.get('reasoning', '')
        for call in event.get('toolCalls', []):
            entry = self.calls.setdefault(call['index'], {'id': '', 'name': '', 'arguments': ''})
            entry['id'] = call.get('id') or entry['id']
            entry['name'] = call.get('name') or entry['name']
            entry['arguments'] += call.get('arguments', '')

    def tool_calls(self):
        return [self.calls[i] | {'id': self.calls[i]['id'] or f'call_{i}'} for i in sorted(self.calls)]


def openai_usage(usage):
    prompt, completion = usage.get('promptTokens', 0), usage.get('completionTokens', 0)
    result = {'prompt_tokens': prompt, 'completion_tokens': completion, 'total_tokens': prompt + completion}
    if 'cachedTokens' in usage:
        result['prompt_tokens_details'] = {'cached_tokens': usage['cachedTokens']}
    if 'reasoningTokens' in usage:
        result['completion_tokens_details'] = {'reasoning_tokens': usage['reasoningTokens']}
    return result


def openai_chunk(cid, created, model, delta, finish=None):
    return {'id': cid, 'object': 'chat.completion.chunk', 'created': created, 'model': model, 'system_fingerprint': None,
            'choices': [{'index': 0, 'delta': delta, 'logprobs': None, 'finish_reason': finish}]}


def openai_delta(event):
    delta = {}
    if 'content' in event:
        delta['content'] = event['content']
    if 'reasoning' in event:
        delta['reasoning_content'] = event['reasoning']
    if event.get('toolCalls'):
        delta['tool_calls'] = []
        for call in event['toolCalls']:
            item = {'index': call['index'], 'function': {'arguments': call.get('arguments', '')}}
            if call.get('id'):
                item['id'], item['type'] = call['id'], 'function'
            if call.get('name'):
                item['function']['name'] = call['name']
            delta['tool_calls'].append(item)
    return delta


def openai_completion(cid, created, model, collected):
    message = {'role': 'assistant', 'content': collected.content or (None if collected.calls else ''), 'refusal': None}
    if collected.reasoning:
        message['reasoning_content'] = collected.reasoning
    if collected.calls:
        message['tool_calls'] = [{'id': c['id'], 'type': 'function', 'function': {'name': c['name'], 'arguments': c['arguments']}} for c in collected.tool_calls()]
    return {'id': cid, 'object': 'chat.completion', 'created': created, 'model': model, 'system_fingerprint': None,
            'choices': [{'index': 0, 'message': message, 'logprobs': None, 'finish_reason': collected.finish}],
            'usage': openai_usage(collected.usage)}


def ollama_time():
    return datetime.now(timezone.utc).isoformat().replace('+00:00', 'Z')


def ollama_calls(collected):
    calls = []
    for call in collected.tool_calls():
        try:
            arguments = json.loads(call['arguments'] or '{}')
        except ValueError:
            arguments = {}
        calls.append({'function': {'name': call['name'], 'arguments': arguments}})
    return calls


def ollama_final(model, collected, started, first, chat):
    now = time.monotonic()
    first = first or now
    done = {'model': model, 'created_at': ollama_time(), 'done': True, 'done_reason': collected.finish if collected.finish != 'tool_calls' else 'stop',
            'total_duration': int((now - started) * 1e9), 'load_duration': 0,
            'prompt_eval_count': collected.usage.get('promptTokens', 0), 'prompt_eval_duration': int((first - started) * 1e9),
            'eval_count': collected.usage.get('completionTokens', 0), 'eval_duration': int((now - first) * 1e9)}
    if chat:
        done['message'] = {'role': 'assistant', 'content': ''}
    else:
        done['response'] = ''
    return done


def model_entry(model):
    return {'id': model['id'], 'object': 'model', 'created': 0, 'owned_by': model.get('ownedBy', 'apple'), 'type': model.get('type', 'chat'),
            'context_window': model['contextSize'], 'capabilities': model['capabilities'], 'name': model['name']}


def ollama_tag(model):
    return {'name': model['id'], 'model': model['id'], 'modified_at': ollama_time(), 'size': 0, 'digest': hashlib.sha256(model['id'].encode()).hexdigest(),
            'details': {'format': 'apple', 'family': model.get('family', model['id']), 'families': None,
                        'parameter_size': model.get('parameterSize', ''), 'quantization_level': model.get('quantization', '')}}


# ---------------------------------------------------------------------------------------------
# HTTP on localhost.


class Request:
    def __init__(self, method, target, headers, body):
        self.method, self.target, self.headers, self.body = method, target, headers, body
        self.path = urlsplit(target).path

    def json(self):
        try:
            return json.loads(self.body or b'{}')
        except ValueError:
            raise bad('the body is not valid JSON') from None


async def read_request(reader):
    try:
        head = await reader.readuntil(b'\r\n\r\n')
    except asyncio.IncompleteReadError:
        return None
    except asyncio.LimitOverrunError:
        raise ApiError(HTTPStatus.REQUEST_HEADER_FIELDS_TOO_LARGE, 'headers_too_large', 'request headers are too large')
    lines = head.decode('latin-1').split('\r\n')
    parts = lines[0].split(' ')
    if len(parts) != 3 or not parts[2].startswith('HTTP/1.'):
        raise bad('malformed request line')
    headers = {}
    for line in lines[1:]:
        if ':' in line:
            name, value = line.split(':', 1)
            headers[name.strip().lower()] = value.strip()
    if headers.get('transfer-encoding', '').lower() == 'chunked':
        body = b''
        while True:
            try:
                size = int((await reader.readuntil(b'\r\n')).split(b';')[0].strip(), 16)
            except ValueError:
                raise bad('malformed chunked body') from None
            if len(body) + size > MAX_BODY:
                raise ApiError(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, 'body_too_large', 'the request body is larger than 32 MiB')
            if size == 0:
                await reader.readuntil(b'\r\n')
                break
            body += (await reader.readexactly(size + 2))[:size]
    else:
        try:
            length = int(headers.get('content-length', '0') or 0)
        except ValueError:
            raise bad('malformed Content-Length') from None
        if length > MAX_BODY:
            raise ApiError(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, 'body_too_large', 'the request body is larger than 32 MiB')
        body = await reader.readexactly(length) if length else b''
    request = Request(parts[0], parts[1], headers, body)
    request.version = parts[2]
    return request


def local_host(value):
    host = (value or '').lower()
    if host.startswith('['):
        host = host[:host.find(']') + 1]
    else:
        host = host.split(':')[0]
    return host in LOCAL_HOSTS


def local_origin(value):
    if not value:
        return True
    parts = urlsplit(value)
    return parts.scheme in ('http', 'https') and local_host(parts.netloc)


class Response:
    """Writes one response: whole, or streamed in chunks."""

    def __init__(self, writer, request):
        self.writer, self.request, self.started = writer, request, False
        self.keep = request.version == 'HTTP/1.1' and request.headers.get('connection', '').lower() != 'close'
        origin = request.headers.get('origin')
        self.cors = [('Access-Control-Allow-Origin', origin), ('Vary', 'Origin')] if origin and local_origin(origin) else []

    def head(self, status, headers):
        status = HTTPStatus(status)
        lines = [f'HTTP/1.1 {status.value} {status.phrase}'] + [f'{k}: {v}' for k, v in headers + self.cors]
        lines.append('Connection: keep-alive' if self.keep else 'Connection: close')
        self.writer.write(('\r\n'.join(lines) + '\r\n\r\n').encode('latin-1'))
        self.started = True

    async def whole(self, status, body, content_type='application/json', extra=()):
        payload = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.head(status, [('Content-Type', content_type), ('Content-Length', str(len(payload)))] + list(extra))
        if self.request.method != 'HEAD':
            self.writer.write(payload)
        await self.writer.drain()

    async def begin(self, content_type):
        self.head(200, [('Content-Type', content_type), ('Cache-Control', 'no-cache'), ('Transfer-Encoding', 'chunked'), ('X-Accel-Buffering', 'no')])
        await self.writer.drain()

    async def chunk(self, data):
        if data:
            self.writer.write(f'{len(data):x}\r\n'.encode() + data + b'\r\n')
            await self.writer.drain()

    async def end(self):
        self.writer.write(b'0\r\n\r\n')
        await self.writer.drain()


class Server:
    def __init__(self, phone, config=None):
        self.phone, self.config = phone, config

    def models(self):
        return list(self.phone.models) if self.phone.present else []

    def backend(self, request, kind='chat'):
        """Where a request runs: the phone's model, or the fallback provider. Raises ApiError."""
        model = self.phone.model(request['model'], kind) if self.phone.present else None
        if model is not None:
            relay = 'request' if kind == 'chat' else 'embed'
            return {**request, 'model': model['id']}, model['id'], lambda r: self.phone.generate(r, relay)
        fallback = load_fallback(self.config)
        if fallback is not None:
            name = fallback['model'] or request['model']
            return request, name, lambda r: (fallback_generate if kind == 'chat' else fallback_embed)(fallback, r)
        if self.phone.present:
            names = ', '.join(m['id'] for m in self.phone.models if m.get('type', 'chat') == kind) or 'none'
            raise ApiError(HTTPStatus.NOT_FOUND, 'model_not_found', f"The phone has no {kind} model {request['model']!r}. Its {kind} models: {names}.")
        raise unavailable(PHONE_AWAY)

    async def vectors(self, request):
        """Runs an embeddings request: (model, vectors in input order, prompt tokens)."""
        request, model, generate = self.backend(request, 'embedding')
        vectors, tokens = {}, 0
        events = generate(request)
        try:
            async for event in events:
                if event['type'] == 'vector':
                    vectors[event['index']] = event['values']
                elif event['type'] == 'done':
                    tokens = event['usage'].get('promptTokens', 0)
        finally:
            await events.aclose()
        if sorted(vectors) != list(range(len(request['input']))):
            raise ApiError(HTTPStatus.BAD_GATEWAY, 'incomplete', 'The phone did not embed every input.', 'server_error')
        return model, [vectors[i] for i in range(len(request['input']))], tokens

    async def handle(self, reader, writer):
        try:
            while True:
                try:
                    request = await read_request(reader)
                except ApiError as error:
                    writer.write(f'HTTP/1.1 {error.status.value} {error.status.phrase}\r\nContent-Type: application/json\r\nConnection: close\r\n'
                                 f'Content-Length: {len(json.dumps(error.body()))}\r\n\r\n{json.dumps(error.body())}'.encode())
                    await writer.drain()
                    return
                if request is None:
                    return
                response = Response(writer, request)
                try:
                    await self.route(request, response)
                except ApiError as error:
                    if not response.started:
                        await response.whole(error.status, error.body(), extra=[('Retry-After', '10')] if error.status == 503 else [])
                    else:
                        return
                if not response.keep:
                    return
        except (ConnectionError, asyncio.IncompleteReadError):
            return
        finally:
            writer.close()

    async def route(self, request, response):
        # Only programs in this computer, by name: refuse other Host names (DNS rebinding) and
        # pages from other origins.
        if not local_host(request.headers.get('host')) or not local_origin(request.headers.get('origin')):
            raise ApiError(HTTPStatus.FORBIDDEN, 'forbidden', 'Caboose AI answers programs in this computer at localhost only')
        method, path = request.method, request.path.rstrip('/') or '/'
        if method == 'OPTIONS':
            return await response.whole(204, b'', extra=[('Access-Control-Allow-Methods', 'GET, POST, OPTIONS'),
                                                          ('Access-Control-Allow-Headers', 'Authorization, Content-Type')])
        if method in ('GET', 'HEAD') and path == '/':
            return await response.whole(200, b'Caboose AI is running', 'text/plain; charset=utf-8')
        if method == 'GET' and path in ('/v1/models', '/models'):
            return await response.whole(200, {'object': 'list', 'data': [model_entry(m) for m in self.models()]})
        if method == 'GET' and path.startswith('/v1/models/'):
            model = self.phone.find(path[len('/v1/models/'):]) if self.phone.present else None
            if model is None:
                raise ApiError(HTTPStatus.NOT_FOUND, 'model_not_found', 'no such model')
            return await response.whole(200, model_entry(model))
        if method == 'GET' and path == '/caboose/status':
            return await response.whole(200, {'phone': 'present' if self.phone.present else 'away', 'models': self.models(),
                                              'fallback': load_fallback(self.config) is not None})
        if method == 'POST' and path in ('/v1/chat/completions', '/chat/completions'):
            return await self.openai_chat(request, response)
        if method == 'POST' and path in ('/v1/embeddings', '/embeddings'):
            request_body, encoding, dimensions = parse_openai_embeddings(request.json())
            model, vectors, tokens = await self.vectors(request_body)
            data = [{'object': 'embedding', 'index': i, 'embedding': base64_vector(shorten(v, dimensions)) if encoding == 'base64' else shorten(v, dimensions)}
                    for i, v in enumerate(vectors)]
            return await response.whole(200, {'object': 'list', 'data': data, 'model': model, 'usage': {'prompt_tokens': tokens, 'total_tokens': tokens}})
        if method == 'POST' and path in ('/api/embed', '/api/embeddings'):
            body = request.json()
            if not isinstance(body, dict):
                raise bad('the body must be a JSON object')
            legacy = path == '/api/embeddings'
            started = time.monotonic()
            model, vectors, tokens = await self.vectors({'model': str(body.get('model', '')), 'input': embedding_inputs(body.get('prompt') if legacy else body.get('input'))})
            if legacy:
                return await response.whole(200, {'embedding': vectors[0]})
            return await response.whole(200, {'model': model, 'embeddings': vectors, 'total_duration': int((time.monotonic() - started) * 1e9),
                                              'load_duration': 0, 'prompt_eval_count': tokens})
        if method == 'POST' and path in ('/v1/completions', '/v1/responses'):
            raise ApiError(HTTPStatus.NOT_IMPLEMENTED, 'not_supported', f'{path} is not supported; use /v1/chat/completions or /api/chat')
        if method == 'GET' and path == '/api/version':
            return await response.whole(200, {'version': OLLAMA_VERSION})
        if method == 'GET' and path == '/api/tags':
            return await response.whole(200, {'models': [ollama_tag(m) for m in self.models()]})
        if method == 'GET' and path == '/api/ps':
            return await response.whole(200, {'models': [ollama_tag(m) | {'expires_at': ollama_time(), 'size_vram': 0} for m in self.models()]})
        if method == 'POST' and path == '/api/show':
            body = request.json()
            model = self.phone.find(body.get('model', body.get('name', ''))) if self.phone.present else None
            if model is None:
                raise ApiError(HTTPStatus.NOT_FOUND, 'model_not_found', 'no such model')
            tag = ollama_tag(model)
            return await response.whole(200, {'modelfile': '', 'parameters': '', 'template': '', 'details': tag['details'],
                                              'model_info': {'general.architecture': 'apple', f"{model['id']}.context_length": model['contextSize']},
                                              'capabilities': (['embedding'] if model.get('type') == 'embedding' else ['completion'])
                                              + [c for c in ('tools', 'vision') if c in model['capabilities']]})
        if method == 'POST' and path == '/api/chat':
            body, stream = parse_ollama_chat(request.json())
            return await self.ollama(body, stream, response, chat=True)
        if method == 'POST' and path == '/api/generate':
            body = request.json()
            if not body.get('prompt') and not body.get('images'):
                # Ollama loads a model on an empty prompt; the phone's are always loaded.
                return await response.whole(200, {'model': body.get('model', ''), 'created_at': ollama_time(), 'response': '', 'done': True, 'done_reason': 'load'})
            parsed, stream = parse_ollama_generate(body)
            return await self.ollama(parsed, stream, response, chat=False)
        if method == 'POST' and path in ('/api/pull', '/api/push', '/api/create', '/api/copy', '/api/delete'):
            raise ApiError(HTTPStatus.NOT_IMPLEMENTED, 'not_supported', 'The phone\'s models are managed on the phone, not here')
        raise ApiError(HTTPStatus.NOT_FOUND, 'not_found', f'no route {method} {path}')

    async def openai_chat(self, request, response):
        parsed, stream, include_usage = parse_openai_chat(request.json())
        parsed, model, generate = self.backend(parsed)
        cid, created = f'chatcmpl-{secrets.token_hex(12)}', int(time.time())
        events = generate(parsed)
        try:
            if not stream:
                collected = Collected()
                async for event in events:
                    collected.add(event)
                return await response.whole(200, openai_completion(cid, created, model, collected))
            # The first event decides between a stream and an error answer.
            first = await anext(events)

            async def send(payload):
                await response.chunk(b'data: ' + json.dumps(payload).encode() + b'\n\n')
            await response.begin('text/event-stream')
            await send(openai_chunk(cid, created, model, {'role': 'assistant', 'content': ''}))
            try:
                event = first
                while True:
                    if event['type'] == 'done':
                        await send(openai_chunk(cid, created, model, {}, event['finishReason']))
                        if include_usage:
                            await send({'id': cid, 'object': 'chat.completion.chunk', 'created': created, 'model': model, 'choices': [], 'usage': openai_usage(event['usage'])})
                        break
                    await send(openai_chunk(cid, created, model, openai_delta(event)))
                    event = await anext(events)
            except ApiError as error:
                await send(error.body())
            await response.chunk(b'data: [DONE]\n\n')
            await response.end()
        finally:
            await events.aclose()

    async def ollama(self, parsed, stream, response, chat):
        parsed, model, generate = self.backend(parsed)
        started, first_token = time.monotonic(), None
        events = generate(parsed)
        try:
            collected = Collected()
            if not stream:
                async for event in events:
                    if first_token is None and event['type'] == 'delta':
                        first_token = time.monotonic()
                    collected.add(event)
                done = ollama_final(model, collected, started, first_token, chat)
                if chat:
                    done['message'] = {'role': 'assistant', 'content': collected.content}
                    if collected.calls:
                        done['message']['tool_calls'] = ollama_calls(collected)
                    if collected.reasoning:
                        done['message']['thinking'] = collected.reasoning
                else:
                    done['response'] = collected.content
                return await response.whole(200, done)
            first = await anext(events)
            await response.begin('application/x-ndjson')

            async def send(payload):
                await response.chunk(json.dumps(payload).encode() + b'\n')
            try:
                event = first
                while event['type'] != 'done':
                    collected.add(event)
                    first_token = first_token or time.monotonic()
                    text = event.get('content', '')
                    thinking = event.get('reasoning', '')
                    if text or thinking:
                        line = {'model': model, 'created_at': ollama_time(), 'done': False}
                        if chat:
                            line['message'] = {'role': 'assistant', 'content': text} | ({'thinking': thinking} if thinking else {})
                        else:
                            line['response'] = text
                        await send(line)
                    event = await anext(events)
                collected.add(event)
                if chat and collected.calls:
                    await send({'model': model, 'created_at': ollama_time(), 'done': False,
                                'message': {'role': 'assistant', 'content': '', 'tool_calls': ollama_calls(collected)}})
                await send(ollama_final(model, collected, started, first_token, chat))
            except ApiError as error:
                await send({'error': error.message})
            await response.end()
        finally:
            await events.aclose()


# ---------------------------------------------------------------------------------------------


def authorized(header, token_file=None):
    try:
        with open(token_file or TOKEN, 'rb') as f:
            token = f.read().strip()
    except OSError:
        return False
    if not token or not header or not header.startswith('Bearer '):
        return False
    candidate = header[len('Bearer '):].encode()
    return hmac.compare_digest(hashlib.sha256(candidate).digest(), hashlib.sha256(token).digest())


def relay_check(token_file=None):
    def check(connection, request):
        if not authorized(request.headers.get('Authorization'), token_file):
            return connection.respond(HTTPStatus.UNAUTHORIZED, 'unauthorized\n')
        if urlsplit(request.path).path != '/relay':
            return connection.respond(HTTPStatus.NOT_FOUND, 'not found\n')
        return None
    return check


async def listen(handler, host, port):
    """The API on loopback: IPv4 and, where the computer has it, IPv6 (`localhost` may be ::1)."""
    hosts = [host] if host != '127.0.0.1' else ['127.0.0.1', '::1']
    try:
        return await asyncio.start_server(handler, hosts, port, limit=MAX_HEADERS, reuse_address=True)
    except OSError:
        if len(hosts) == 1:
            raise
        return await asyncio.start_server(handler, host, port, limit=MAX_HEADERS, reuse_address=True)


async def main(api_host=API_HOST, api_port=API_PORT, relay_host='0.0.0.0', relay_port=RELAY_PORT, ready=None, token_file=None, config=None):
    from websockets.asyncio.server import serve
    phone = Phone()
    server = Server(phone, config)
    servers = []

    async def open_api():
        # Another program (Ollama itself) may hold the port; the relay stays up meanwhile.
        while True:
            try:
                servers.append(await listen(server.handle, api_host, api_port))
                return
            except OSError as error:
                print(f'Caboose AI cannot listen on {api_host}:{api_port} ({error.strerror or error}); trying again in 30 s', file=sys.stderr, flush=True)
                await asyncio.sleep(30)
    try:
        await asyncio.wait_for(open_api(), 0.5)
    except asyncio.TimeoutError:
        pass
    opening = None if servers else asyncio.create_task(open_api())
    try:
        async with serve(phone.serve_relay, relay_host, relay_port, process_request=relay_check(token_file), compression=None,
                         max_size=MAX_BODY + 1024 * 1024, ping_interval=20, ping_timeout=20) as relay:
            if ready is not None:
                ready(servers[0] if servers else None, relay, phone)
            stop = asyncio.get_running_loop().create_future()
            for sig in (signal.SIGTERM, signal.SIGINT):
                asyncio.get_running_loop().add_signal_handler(sig, lambda: stop.done() or stop.set_result(None))
            await stop
    finally:
        if opening is not None:
            opening.cancel()
        for api in servers:
            api.close()


if __name__ == '__main__':
    asyncio.run(main())
