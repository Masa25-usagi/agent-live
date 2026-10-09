import asyncio
import json
import os
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
from aiohttp import web
from aiohttp.test_utils import TestClient, TestServer
import fast_reply
import gemini_direct
from companion import client_credential


class Upstream:
    def __init__(self, lines=(), status=200, payload=None):
        self.status, self.payload, self.closed = status, payload, False
        self.content = asyncio.StreamReader()
        for line in lines: self.content.feed_data(line)
        if lines: self.content.feed_eof()
    async def __aenter__(self): return self
    async def __aexit__(self, *args): self.close()
    async def json(self): return self.payload
    def close(self): self.closed = True


class FastReplyTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.environ = patch.dict(os.environ, {'HERMES_HOME': self.tmp.name, 'GEMINI_API_KEY': 'synthetic-google-key', 'TYPESAFE_API_KEY': 'synthetic-jev-key'})
        self.environ.start()
        self.calls = []
        self.upstream = Upstream([b'data: {"choices":[{"delta":{"content":"first sentence."}}]}\n', b'data: [DONE]\n'])
        async def post(url, **kwargs): self.calls.append((url, kwargs)); return self.upstream
        # aiohttp's context-manager API is also awaitable.
        class Post:
            def __init__(inner, url, **kwargs): inner.url, inner.kwargs = url, kwargs
            def __await__(inner): return post(inner.url, **inner.kwargs).__await__()
            async def __aenter__(inner): return await post(inner.url, **inner.kwargs)
            async def __aexit__(inner, *args): self.upstream.close()
        self.app = web.Application()
        self.app['http'] = SimpleNamespace(post=Post)
        self.app['companion_root'] = Path(self.tmp.name)
        self.app.router.add_post('/reply', fast_reply.reply)
        self.app.router.add_post('/gemini', gemini_direct.credential)
        self.app.router.add_post('/jev-key', client_credential)
        self.client = TestClient(TestServer(self.app)); await self.client.start_server()
        self.adapter = SimpleNamespace(get_credential=lambda: SimpleNamespace(base_url='https://inference-api.nousresearch.com/v1', bearer='synthetic-subscription-key'))
        self.adapter_patch = patch.object(fast_reply, 'subscription_adapter', return_value=self.adapter); self.adapter_patch.start()
        self.body = {'provider': 'nous', 'model': 'z-ai/glm-5.2', 'text': 'hello', 'context': '', 'persona': 'short reply', 'objective': 'fixture'}
    async def asyncTearDown(self):
        await self.client.close(); self.adapter_patch.stop(); self.environ.stop(); self.tmp.cleanup()
    async def test_streams_only_text_and_has_no_tools_or_paid_fallback(self):
        response = await self.client.post('/reply', json=self.body)
        events = [json.loads(line) for line in (await response.text()).splitlines()]
        self.assertEqual(events, [{'delta': 'first sentence.'}, {'done': True}])
        url, request = self.calls[0]
        self.assertEqual(url, 'https://inference-api.nousresearch.com/v1/chat/completions')
        self.assertFalse(request['allow_redirects']); self.assertNotIn('tools', request['json'])
        self.assertEqual(request['json']['reasoning_effort'], 'medium'); self.assertNotIn('thinking', request['json']); self.assertEqual(request['json']['max_tokens'], 512)
        self.assertFalse(self.app['fast_replies'])
    async def test_rejects_unsupported_provider_and_invalid_input_without_inference(self):
        for changes in ({'provider': 'openai'}, {'model': '../bad'}, {'text': ''}, {'context': 2}, {'frame_session': '../credentials'}):
            response = await self.client.post('/reply', json={**self.body, **changes})
            self.assertEqual(response.status, 400)
        self.assertFalse(self.calls)
    async def test_foreign_url_never_receives_subscription_key(self):
        self.adapter.get_credential = lambda: SimpleNamespace(base_url='https://nousresearch.com.attacker.invalid/v1', bearer='synthetic-secret')
        response = await self.client.post('/reply', json=self.body)
        self.assertEqual(response.status, 502); self.assertFalse(self.calls)
        self.assertNotIn('synthetic-secret', await response.text())
    async def test_upstream_error_and_tool_call_do_not_execute_or_leak(self):
        self.upstream = Upstream([b'data: {"choices":[{"delta":{"tool_calls":[{"secret":"synthetic-secret"}]}}]}\n', b'data: [DONE]\n'])
        response = await self.client.post('/reply', json=self.body)
        value = await response.text()
        self.assertIn('conversation_unavailable', value); self.assertNotIn('synthetic-secret', value)
        self.assertTrue(self.upstream.closed)
    async def test_incomplete_stream_is_not_reported_completed(self):
        self.upstream = Upstream([b'data: {"choices":[{"delta":{"content":"partial"}}]}\n'])
        response = await self.client.post('/reply', json=self.body)
        value = await response.text(); self.assertIn('conversation_unavailable', value); self.assertNotIn('"done"', value)
    async def test_disconnected_client_cancels_waiting_upstream(self):
        self.upstream = Upstream([b'data: {"choices":[{"delta":{"content":"partial"}}]}\n'])
        self.upstream.content = asyncio.StreamReader()
        self.upstream.content.feed_data(b'data: {"choices":[{"delta":{"content":"partial"}}]}\n')
        response = await self.client.post('/reply', json=self.body)
        await response.content.readline(); response.close()
        for _ in range(30):
            if self.upstream.closed: break
            await asyncio.sleep(0.02)
        self.assertTrue(self.upstream.closed); self.assertFalse(self.app['fast_replies'])
    async def test_gemini_token_is_constrained_and_key_is_not_returned(self):
        self.upstream = Upstream(payload={'name': 'auth_tokens/synthetic-ephemeral'})
        response = await self.client.post('/gemini', json={'model': 'gemini-3.8-live'})
        result = await response.json()
        self.assertEqual(result['token'], 'auth_tokens/synthetic-ephemeral'); self.assertNotIn('synthetic-google-key', json.dumps(result))
        self.assertEqual(response.headers['Cache-Control'], 'no-store')
        _, kwargs = self.calls[0]
        self.assertEqual(kwargs['json']['uses'], 1)
        self.assertEqual(kwargs['json']['bidiGenerateContentSetup'], {'model': 'models/gemini-3.8-live'})
        self.assertEqual(kwargs['json']['fieldMask'], 'model'); self.assertFalse(kwargs['allow_redirects'])
    async def test_gemini_invalid_model_and_provider_failure_do_not_fallback(self):
        response = await self.client.post('/gemini', json={'model': 'gemini-3.8-flash'})
        self.assertEqual(response.status, 400); self.assertFalse(self.calls)
        self.upstream = Upstream(status=403, payload={'error': 'synthetic-secret'})
        response = await self.client.post('/gemini', json={'model': 'gemini-3.8-live'})
        self.assertEqual(response.status, 502); self.assertNotIn('synthetic-secret', await response.text())
    async def test_opt_in_jev_key_response_is_not_cacheable(self):
        response = await self.client.post('/jev-key', json={})
        result = await response.json(); self.assertEqual(result['key'], 'synthetic-jev-key')
        self.assertEqual(response.headers['Cache-Control'], 'no-store'); self.assertEqual(len(result['questions']), 6)


if __name__ == '__main__': unittest.main()
