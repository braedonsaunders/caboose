"""Caboose AI: request translation, and the real service against a fake host and phone.

The service tests need `websockets` (Debian's python3-websockets); without it only the
translation tests run. `openai` (the Python client) is used when installed.
"""
import asyncio
import base64
import importlib.util
import json
import os
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

spec = importlib.util.spec_from_file_location('caboose_ai', os.path.join(os.path.dirname(__file__), 'caboose-ai.py'))
ai = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ai)

try:
    import websockets  # noqa: F401
    HAVE_WEBSOCKETS = True
except ImportError:
    HAVE_WEBSOCKETS = False

PNG = base64.b64encode(b'\x89PNG\r\n\x1a\n' + b'\0' * 16).decode()
MODELS = [{'id': 'apple-foundation', 'name': 'Apple Foundation Model', 'contextSize': 4096, 'capabilities': ['tools', 'json'], 'ownedBy': 'apple'},
          {'id': 'apple-embedding', 'name': 'Apple Embedding', 'contextSize': 256, 'capabilities': [], 'ownedBy': 'apple', 'type': 'embedding'}]


class Translation(unittest.TestCase):
    def test_openai_chat(self):
        request, stream, usage = ai.parse_openai_chat({
            'model': 'apple-foundation', 'stream': True, 'stream_options': {'include_usage': True}, 'temperature': 0.2, 'max_tokens': 50,
            'messages': [
                {'role': 'developer', 'content': 'Be brief.'},
                {'role': 'user', 'content': [{'type': 'text', 'text': 'What is '}, {'type': 'text', 'text': 'this?'}]},
                {'role': 'assistant', 'content': None, 'tool_calls': [{'id': 'call_1', 'type': 'function', 'function': {'name': 'look', 'arguments': '{"x":1}'}}]},
                {'role': 'tool', 'tool_call_id': 'call_1', 'content': 'a cat'},
            ],
            'tools': [{'type': 'function', 'function': {'name': 'look', 'description': 'Looks', 'parameters': {'type': 'object', 'properties': {'x': {'type': 'integer'}}}}}],
            'tool_choice': 'auto', 'response_format': {'type': 'json_schema', 'json_schema': {'name': 'answer', 'schema': {'type': 'object'}}}})
        self.assertTrue(stream)
        self.assertTrue(usage)
        self.assertEqual(request['messages'][0], {'role': 'system', 'content': 'Be brief.'})
        self.assertEqual(request['messages'][1], {'role': 'user', 'content': 'What is this?'})
        self.assertEqual(request['messages'][2]['toolCalls'], [{'id': 'call_1', 'name': 'look', 'arguments': '{"x":1}'}])
        self.assertEqual(request['messages'][3], {'role': 'tool', 'content': 'a cat', 'toolCallId': 'call_1'})
        self.assertEqual(request['tools'][0]['name'], 'look')
        self.assertEqual(request['toolChoice'], 'auto')
        self.assertEqual(request['responseFormat'], {'type': 'json', 'name': 'answer', 'schema': {'type': 'object'}})
        self.assertEqual((request['temperature'], request['maxTokens']), (0.2, 50))
        self.assertNotIn('seed', request)

    def test_openai_images(self):
        request, _, _ = ai.parse_openai_chat({'messages': [{'role': 'user', 'content': [
            {'type': 'text', 'text': 'Read it'}, {'type': 'image_url', 'image_url': {'url': f'data:image/png;base64,{PNG}'}}]}]})
        self.assertEqual(request['messages'][0]['content'], [{'type': 'text', 'text': 'Read it'}, {'type': 'image', 'mediaType': 'image/png', 'data': PNG}])
        self.assertEqual(request['model'], '')

    def test_openai_refusals(self):
        for body in ({}, {'messages': []}, {'messages': [{'role': 'robot', 'content': 'x'}]},
                     {'messages': [{'role': 'user', 'content': 'x'}], 'temperature': 3},
                     {'messages': [{'role': 'user', 'content': 'x'}], 'max_tokens': 0},
                     {'messages': [{'role': 'user', 'content': 'x'}], 'n': 2},
                     {'messages': [{'role': 'user', 'content': [{'type': 'image_url', 'image_url': {'url': 'https://example.com/a.png'}}]}]},
                     {'messages': [{'role': 'user', 'content': [{'type': 'image_url', 'image_url': {'url': 'data:image/png;base64,***'}}]}]},
                     {'messages': [{'role': 'tool', 'content': 'x'}]},
                     {'messages': [{'role': 'user', 'content': 'x'}], 'tools': [{'type': 'function', 'function': {'name': 'bad name'}}]},
                     {'messages': [{'role': 'user', 'content': 'x'}], 'response_format': {'type': 'xml'}},
                     {'messages': [{'role': 'user', 'content': 'x'}], 'stop': ['a'] * 5}):
            with self.assertRaises(ai.ApiError, msg=body) as caught:
                ai.parse_openai_chat(body)
            self.assertEqual(caught.exception.status, 400)

    def test_ollama(self):
        request, stream = ai.parse_ollama_chat({'model': 'apple-foundation', 'format': 'json', 'options': {'temperature': 0.5, 'num_predict': 20, 'top_k': 40},
                                                'messages': [{'role': 'user', 'content': 'hi', 'images': [PNG]}]})
        self.assertTrue(stream)
        self.assertEqual(request['messages'][0]['content'], [{'type': 'text', 'text': 'hi'}, {'type': 'image', 'mediaType': 'image/png', 'data': PNG}])
        self.assertEqual((request['temperature'], request['maxTokens'], request['topK'], request['responseFormat']), (0.5, 20, 40, {'type': 'json'}))
        request, stream = ai.parse_ollama_generate({'model': 'x', 'prompt': 'hello', 'system': 'be nice', 'stream': False, 'options': {'num_predict': -1}})
        self.assertFalse(stream)
        self.assertEqual(request['messages'], [{'role': 'system', 'content': 'be nice'}, {'role': 'user', 'content': 'hello'}])
        self.assertNotIn('maxTokens', request)

    def test_rendering(self):
        collected = ai.Collected()
        for event in ({'type': 'delta', 'content': 'Hel'}, {'type': 'delta', 'content': 'lo'},
                      {'type': 'delta', 'toolCalls': [{'index': 0, 'id': 'call_a', 'name': 'look', 'arguments': '{"x"'}]},
                      {'type': 'delta', 'toolCalls': [{'index': 0, 'arguments': ':1}'}]},
                      {'type': 'done', 'finishReason': 'tool_calls', 'usage': {'promptTokens': 7, 'completionTokens': 3, 'cachedTokens': 2}}):
            collected.add(event)
        body = ai.openai_completion('id', 1, 'apple-foundation', collected)
        self.assertEqual(body['choices'][0]['message']['content'], 'Hello')
        self.assertEqual(body['choices'][0]['message']['tool_calls'], [{'id': 'call_a', 'type': 'function', 'function': {'name': 'look', 'arguments': '{"x":1}'}}])
        self.assertEqual(body['choices'][0]['finish_reason'], 'tool_calls')
        self.assertEqual(body['usage'], {'prompt_tokens': 7, 'completion_tokens': 3, 'total_tokens': 10, 'prompt_tokens_details': {'cached_tokens': 2}})
        self.assertEqual(ai.ollama_calls(collected), [{'function': {'name': 'look', 'arguments': {'x': 1}}}])
        delta = ai.openai_delta({'type': 'delta', 'toolCalls': [{'index': 0, 'id': 'c', 'name': 'n', 'arguments': ''}]})
        self.assertEqual(delta, {'tool_calls': [{'index': 0, 'function': {'arguments': '', 'name': 'n'}, 'id': 'c', 'type': 'function'}]})

    def test_fallback_body(self):
        request, _, _ = ai.parse_openai_chat({'model': 'apple-foundation', 'max_tokens': 9, 'messages': [{'role': 'user', 'content': 'hi'}],
                                             'tools': [{'type': 'function', 'function': {'name': 't', 'parameters': {'type': 'object'}}}], 'tool_choice': {'type': 'function', 'function': {'name': 't'}}})
        body = ai.openai_body(request, 'gpt-test')
        self.assertEqual(body['model'], 'gpt-test')
        self.assertEqual(body['max_tokens'], 9)
        self.assertEqual(body['tool_choice'], {'type': 'function', 'function': {'name': 't'}})
        self.assertEqual(body['tools'][0]['function']['name'], 't')
        events = ai.fallback_events({'choices': [{'delta': {'content': 'x', 'tool_calls': [{'index': 0, 'id': 'c', 'function': {'name': 'n', 'arguments': '{'}}]}, 'finish_reason': 'tool_calls'}],
                                     'usage': {'prompt_tokens': 1, 'completion_tokens': 2}})
        self.assertEqual(events, [{'type': 'delta', 'content': 'x', 'toolCalls': [{'index': 0, 'id': 'c', 'name': 'n', 'arguments': '{'}]},
                                  {'type': 'finish', 'finishReason': 'tool_calls'}, {'type': 'usage', 'usage': {'promptTokens': 1, 'completionTokens': 2}}])

    def test_hosts(self):
        for host in ('localhost:11434', '127.0.0.1', '[::1]:11434', '0.0.0.0:11434'):
            self.assertTrue(ai.local_host(host), host)
        for host in ('evil.example:11434', '', None, '10.0.0.5:11434'):
            self.assertFalse(ai.local_host(host), host)
        self.assertTrue(ai.local_origin('http://localhost:3000'))
        self.assertFalse(ai.local_origin('https://evil.example'))

    def test_token(self):
        with tempfile.NamedTemporaryFile('w', delete=False) as f:
            f.write('secret\n')
        try:
            self.assertTrue(ai.authorized('Bearer secret', f.name))
            self.assertFalse(ai.authorized('Bearer other', f.name))
            self.assertFalse(ai.authorized(None, f.name))
            self.assertFalse(ai.authorized('Bearer secret', f.name + '-missing'))
        finally:
            os.unlink(f.name)


async def http(port, method, path, body=None, host='localhost', read_all=True):
    """A minimal HTTP/1.1 client: (status, headers, body bytes) with chunked bodies decoded."""
    reader, writer = await asyncio.open_connection('127.0.0.1', port)
    payload = json.dumps(body).encode() if body is not None else b''
    writer.write(f'{method} {path} HTTP/1.1\r\nHost: {host}\r\nContent-Type: application/json\r\nContent-Length: {len(payload)}\r\nConnection: close\r\n\r\n'.encode() + payload)
    await writer.drain()
    head = (await reader.readuntil(b'\r\n\r\n')).decode()
    status = int(head.split(' ')[1])
    headers = {line.split(':', 1)[0].lower(): line.split(':', 1)[1].strip() for line in head.split('\r\n')[1:] if ':' in line}
    if not read_all:
        return status, headers, (reader, writer)
    data = b''
    if headers.get('transfer-encoding') == 'chunked':
        while True:
            size = int((await reader.readuntil(b'\r\n')).strip(), 16)
            if size == 0:
                break
            data += (await reader.readexactly(size + 2))[:size]
    else:
        data = await reader.readexactly(int(headers.get('content-length', '0')))
    writer.close()
    return status, headers, data


@unittest.skipUnless(HAVE_WEBSOCKETS, 'needs python3-websockets')
class Service(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.token = os.path.join(self.dir.name, 'token')
        with open(self.token, 'w') as f:
            f.write('relay-token')
        self.config = os.path.join(self.dir.name, 'ai.json')
        ready = asyncio.get_running_loop().create_future()
        self.task = asyncio.create_task(ai.main('127.0.0.1', 0, '127.0.0.1', 0, ready=lambda api, relay, phone: ready.set_result((api, relay, phone)),
                                                token_file=self.token, config=self.config))
        api, relay, self.phone = await ready
        self.api_port = next(s.getsockname()[1] for s in api.sockets if s.getsockname()[0] == '127.0.0.1')
        self.relay_port = next(iter(relay.sockets)).getsockname()[1]
        self.requests, self.cancels, self.host = [], [], None

    async def asyncTearDown(self):
        if self.host is not None:
            await self.host.close()
        self.task.cancel()
        try:
            await self.task
        except asyncio.CancelledError:
            pass
        self.dir.cleanup()

    async def connect(self, answer):
        """The host's relay with a phone that answers each request with `answer(request)` events."""
        from websockets.asyncio.client import connect
        self.host = await connect(f'ws://127.0.0.1:{self.relay_port}/relay', additional_headers={'Authorization': 'Bearer relay-token'})
        await self.host.send(json.dumps({'type': 'phone', 'models': MODELS}))

        async def serve():
            async for raw in self.host:
                message = json.loads(raw)
                if message['type'] == 'cancel':
                    self.cancels.append(message['id'])
                    continue
                self.requests.append(message['request'])
                for event in (self.embed if message['type'] == 'embed' else answer)(message['request']):
                    if event == 'hang':
                        break
                    if event == 'close':
                        await self.host.close()
                        return
                    await self.host.send(json.dumps({'id': message['id'], **event}))
                    await asyncio.sleep(0)
        self.serving = asyncio.create_task(serve())
        for _ in range(100):
            if self.phone.present:
                return
            await asyncio.sleep(0.01)
        self.fail('the phone never became present')

    @staticmethod
    def embed(request):
        yield {'type': 'started'}
        for index, text in reversed(list(enumerate(request['input']))):
            yield {'type': 'vector', 'index': index, 'values': [0.6, 0.8, float(len(text))]}
        yield {'type': 'done', 'finishReason': 'stop', 'usage': {'promptTokens': 7, 'completionTokens': 0}}

    @staticmethod
    def hello(request):
        yield {'type': 'started'}
        for word in ('Hello', ' from', ' the', ' phone'):
            yield {'type': 'delta', 'content': word}
        yield {'type': 'done', 'finishReason': 'stop', 'usage': {'promptTokens': 12, 'completionTokens': 4}}

    async def test_away(self):
        status, headers, body = await http(self.api_port, 'POST', '/v1/chat/completions', {'model': 'apple-foundation', 'messages': [{'role': 'user', 'content': 'hi'}]})
        self.assertEqual(status, 503)
        self.assertEqual(headers['retry-after'], '10')
        self.assertEqual(json.loads(body)['error']['code'], 'phone_unavailable')
        status, _, body = await http(self.api_port, 'GET', '/v1/models')
        self.assertEqual((status, json.loads(body)['data']), (200, []))
        status, _, body = await http(self.api_port, 'POST', '/api/chat', {'model': 'apple-foundation', 'messages': [{'role': 'user', 'content': 'hi'}]})
        self.assertEqual(status, 503)

    async def test_relay_needs_the_token(self):
        from websockets.asyncio.client import connect
        from websockets.exceptions import InvalidStatus
        with self.assertRaises(InvalidStatus):
            await connect(f'ws://127.0.0.1:{self.relay_port}/relay', additional_headers={'Authorization': 'Bearer wrong'})

    async def test_other_hosts_are_refused(self):
        status, _, _ = await http(self.api_port, 'GET', '/v1/models', host='attacker.example')
        self.assertEqual(status, 403)

    async def test_openai_stream(self):
        await self.connect(self.hello)
        status, headers, body = await http(self.api_port, 'POST', '/v1/chat/completions', {
            'model': 'apple-foundation', 'stream': True, 'stream_options': {'include_usage': True}, 'messages': [{'role': 'user', 'content': 'hi'}]})
        self.assertEqual(status, 200)
        self.assertEqual(headers['content-type'], 'text/event-stream')
        events = [line[6:] for line in body.decode().split('\n\n') if line.startswith('data: ')]
        self.assertEqual(events[-1], '[DONE]')
        chunks = [json.loads(e) for e in events[:-1]]
        self.assertEqual(''.join(c['choices'][0]['delta'].get('content', '') for c in chunks if c['choices']), 'Hello from the phone')
        self.assertEqual(chunks[-2]['choices'][0]['finish_reason'], 'stop')
        self.assertEqual(chunks[-1]['usage'], {'prompt_tokens': 12, 'completion_tokens': 4, 'total_tokens': 16})
        self.assertEqual(self.requests[0]['messages'], [{'role': 'user', 'content': 'hi'}])

    async def test_openai_whole_and_default_model(self):
        await self.connect(self.hello)
        status, _, body = await http(self.api_port, 'POST', '/v1/chat/completions', {'model': 'default', 'messages': [{'role': 'user', 'content': 'hi'}]})
        self.assertEqual(status, 200)
        answer = json.loads(body)
        self.assertEqual(answer['model'], 'apple-foundation')
        self.assertEqual(answer['choices'][0]['message']['content'], 'Hello from the phone')
        self.assertEqual(self.requests[0]['model'], 'apple-foundation')
        status, _, body = await http(self.api_port, 'POST', '/v1/chat/completions', {'model': 'gpt-4o', 'messages': [{'role': 'user', 'content': 'hi'}]})
        self.assertEqual(status, 404)
        self.assertIn('apple-foundation', json.loads(body)['error']['message'])

    async def test_models_and_tags(self):
        await self.connect(self.hello)
        _, _, body = await http(self.api_port, 'GET', '/v1/models')
        self.assertEqual([m['id'] for m in json.loads(body)['data']], ['apple-foundation', 'apple-embedding'])
        _, _, body = await http(self.api_port, 'GET', '/api/tags')
        self.assertEqual(json.loads(body)['models'][0]['name'], 'apple-foundation')
        status, _, body = await http(self.api_port, 'POST', '/api/show', {'model': 'apple-foundation'})
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body)['model_info']['apple-foundation.context_length'], 4096)

    async def test_ollama_stream(self):
        await self.connect(self.hello)
        status, headers, body = await http(self.api_port, 'POST', '/api/chat', {'model': 'apple-foundation', 'messages': [{'role': 'user', 'content': 'hi'}]})
        self.assertEqual(status, 200)
        lines = [json.loads(line) for line in body.decode().splitlines()]
        self.assertEqual(''.join(line['message']['content'] for line in lines), 'Hello from the phone')
        self.assertTrue(lines[-1]['done'])
        self.assertEqual((lines[-1]['prompt_eval_count'], lines[-1]['eval_count']), (12, 4))
        status, _, body = await http(self.api_port, 'POST', '/api/generate', {'model': 'apple-foundation', 'prompt': 'hi', 'stream': False})
        self.assertEqual(json.loads(body)['response'], 'Hello from the phone')

    async def test_embeddings(self):
        await self.connect(self.hello)
        status, _, body = await http(self.api_port, 'POST', '/v1/embeddings', {'model': 'apple-embedding', 'input': ['ab', 'abc']})
        self.assertEqual(status, 200)
        answer = json.loads(body)
        self.assertEqual([d['embedding'] for d in answer['data']], [[0.6, 0.8, 2.0], [0.6, 0.8, 3.0]])
        self.assertEqual((answer['model'], answer['usage']['prompt_tokens']), ('apple-embedding', 7))
        self.assertEqual(self.requests[-1], {'model': 'apple-embedding', 'input': ['ab', 'abc']})
        _, _, body = await http(self.api_port, 'POST', '/v1/embeddings', {'model': 'default', 'input': 'x', 'encoding_format': 'base64', 'dimensions': 2})
        import struct
        vector = struct.unpack('<2f', base64.b64decode(json.loads(body)['data'][0]['embedding']))
        self.assertAlmostEqual(vector[0], 0.6, places=5)
        _, _, body = await http(self.api_port, 'POST', '/api/embed', {'model': 'apple-embedding', 'input': 'hello'})
        self.assertEqual(json.loads(body)['embeddings'], [[0.6, 0.8, 5.0]])
        _, _, body = await http(self.api_port, 'POST', '/api/embeddings', {'model': 'apple-embedding', 'prompt': 'hi'})
        self.assertEqual(json.loads(body)['embedding'], [0.6, 0.8, 2.0])
        # A chat model does not embed, and an embedding model does not chat.
        status, _, _ = await http(self.api_port, 'POST', '/v1/embeddings', {'model': 'apple-foundation', 'input': 'x'})
        self.assertEqual(status, 404)
        status, _, _ = await http(self.api_port, 'POST', '/v1/chat/completions', {'model': 'apple-embedding', 'messages': [{'role': 'user', 'content': 'hi'}]})
        self.assertEqual(status, 404)
        status, _, _ = await http(self.api_port, 'POST', '/v1/embeddings', {'model': 'apple-embedding', 'input': [1, 2, 3]})
        self.assertEqual(status, 400)

    async def test_tool_calls(self):
        def tool(request):
            yield {'type': 'started'}
            yield {'type': 'delta', 'toolCalls': [{'index': 0, 'id': 'call_x', 'name': 'get_weather', 'arguments': '{"city":'}]}
            yield {'type': 'delta', 'toolCalls': [{'index': 0, 'arguments': '"Toronto"}'}]}
            yield {'type': 'done', 'finishReason': 'tool_calls', 'usage': {'promptTokens': 30, 'completionTokens': 9}}
        await self.connect(tool)
        _, _, body = await http(self.api_port, 'POST', '/v1/chat/completions', {
            'messages': [{'role': 'user', 'content': 'weather?'}],
            'tools': [{'type': 'function', 'function': {'name': 'get_weather', 'parameters': {'type': 'object', 'properties': {'city': {'type': 'string'}}}}}]})
        message = json.loads(body)['choices'][0]
        self.assertEqual(message['finish_reason'], 'tool_calls')
        self.assertEqual(message['message']['tool_calls'][0]['function'], {'name': 'get_weather', 'arguments': '{"city":"Toronto"}'})
        self.assertIsNone(message['message']['content'])

    async def test_phone_errors_pass_through(self):
        def too_long(request):
            yield {'type': 'started'}
            yield {'type': 'error', 'status': 400, 'code': 'context_length_exceeded', 'message': 'The conversation is 5000 tokens; the model takes 4096.'}
        await self.connect(too_long)
        status, _, body = await http(self.api_port, 'POST', '/v1/chat/completions', {'messages': [{'role': 'user', 'content': 'hi'}]})
        self.assertEqual(status, 400)
        self.assertEqual(json.loads(body)['error']['code'], 'context_length_exceeded')

    async def test_phone_leaves_mid_stream(self):
        def leaves(request):
            yield {'type': 'started'}
            yield {'type': 'delta', 'content': 'Hel'}
            yield 'close'
        await self.connect(leaves)
        status, _, body = await http(self.api_port, 'POST', '/v1/chat/completions', {'stream': True, 'messages': [{'role': 'user', 'content': 'hi'}]})
        self.assertEqual(status, 200)
        events = [line[6:] for line in body.decode().split('\n\n') if line.startswith('data: ')]
        self.assertEqual(events[-1], '[DONE]')
        self.assertEqual(json.loads(events[-2])['error']['code'], 'phone_unavailable')
        self.assertFalse(self.phone.present)

    async def test_phone_that_never_answers(self):
        ai.ACCEPT_SECONDS = 0.2
        try:
            await self.connect(lambda request: iter(['hang']))
            status, _, body = await http(self.api_port, 'POST', '/v1/chat/completions', {'messages': [{'role': 'user', 'content': 'hi'}]})
        finally:
            ai.ACCEPT_SECONDS = 10
        self.assertEqual(status, 503)
        self.assertIn('did not answer', json.loads(body)['error']['message'])
        for _ in range(50):
            if self.cancels:
                break
            await asyncio.sleep(0.01)
        self.assertEqual(len(self.cancels), 1)

    async def test_program_leaves_mid_stream(self):
        def slow(request):
            yield {'type': 'started'}
            yield {'type': 'delta', 'content': 'one'}
            yield 'hang'
        await self.connect(slow)
        status, _, (reader, writer) = await http(self.api_port, 'POST', '/v1/chat/completions', {'stream': True, 'messages': [{'role': 'user', 'content': 'hi'}]}, read_all=False)
        self.assertEqual(status, 200)
        await reader.readuntil(b'one')
        writer.close()
        # The service notices on its next write; deliver one more event to make it write.
        rid = next(iter(self.phone.pending))
        for _ in range(3):
            await self.host.send(json.dumps({'id': rid, 'type': 'delta', 'content': 'two'}))
            await asyncio.sleep(0.05)
        for _ in range(100):
            if self.cancels:
                break
            await asyncio.sleep(0.01)
        self.assertEqual(self.cancels, [rid])

    async def test_fallback(self):
        seen = []

        class Provider(BaseHTTPRequestHandler):
            def do_POST(self):
                seen.append((self.path, self.headers['Authorization'], json.loads(self.rfile.read(int(self.headers['Content-Length'])))))
                self.send_response(200)
                self.send_header('Content-Type', 'text/event-stream')
                self.end_headers()
                for chunk in ({'choices': [{'delta': {'content': 'from'}}]}, {'choices': [{'delta': {'content': ' cloud'}, 'finish_reason': 'stop'}]},
                              {'choices': [], 'usage': {'prompt_tokens': 3, 'completion_tokens': 2}}):
                    self.wfile.write(b'data: ' + json.dumps(chunk).encode() + b'\n\n')
                self.wfile.write(b'data: [DONE]\n\n')

            def log_message(self, *args):
                pass
        provider = ThreadingHTTPServer(('127.0.0.1', 0), Provider)
        threading.Thread(target=provider.serve_forever, daemon=True).start()
        try:
            with open(self.config, 'w') as f:
                json.dump({'fallback': {'baseUrl': f'http://127.0.0.1:{provider.server_port}/v1', 'apiKey': 'sk-test', 'model': 'cloud-model'}}, f)
            status, _, body = await http(self.api_port, 'POST', '/v1/chat/completions', {'model': 'apple-foundation', 'messages': [{'role': 'user', 'content': 'hi'}]})
            self.assertEqual(status, 200)
            answer = json.loads(body)
            self.assertEqual(answer['choices'][0]['message']['content'], 'from cloud')
            self.assertEqual(answer['model'], 'cloud-model')
            self.assertEqual(answer['usage']['total_tokens'], 5)
            self.assertEqual(seen[0][:2], ('/v1/chat/completions', 'Bearer sk-test'))
            self.assertEqual(seen[0][2]['model'], 'cloud-model')
            _, _, body = await http(self.api_port, 'GET', '/caboose/status')
            self.assertEqual(json.loads(body), {'phone': 'away', 'models': [], 'fallback': True})
        finally:
            provider.shutdown()
            provider.server_close()

    async def test_openai_client(self):
        try:
            import openai
        except ImportError:
            self.skipTest('needs the openai package')
        await self.connect(self.hello)
        client = openai.AsyncOpenAI(base_url=f'http://localhost:{self.api_port}/v1', api_key='unused')
        stream = await client.chat.completions.create(model='apple-foundation', messages=[{'role': 'user', 'content': 'hi'}], stream=True)
        text = ''.join([chunk.choices[0].delta.content or '' async for chunk in stream if chunk.choices])
        self.assertEqual(text, 'Hello from the phone')
        whole = await client.chat.completions.create(model='apple-foundation', messages=[{'role': 'user', 'content': 'hi'}])
        self.assertEqual(whole.choices[0].message.content, 'Hello from the phone')
        # The client asks for base64 unless told otherwise.
        embedded = await client.embeddings.create(model='apple-embedding', input=['ab', 'abcd'])
        self.assertEqual([round(v, 4) for v in embedded.data[1].embedding], [0.6, 0.8, 4.0])
        await self.host.close()
        self.host = None
        bare = openai.AsyncOpenAI(base_url=f'http://localhost:{self.api_port}/v1', api_key='unused', max_retries=0)
        with self.assertRaises(openai.APIStatusError) as caught:
            await bare.chat.completions.create(model='apple-foundation', messages=[{'role': 'user', 'content': 'hi'}])
        self.assertEqual(caught.exception.status_code, 503)
        await bare.close()
        await client.close()


if __name__ == '__main__':
    unittest.main()
