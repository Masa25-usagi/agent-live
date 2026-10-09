"""Explicit Nous speech uses only its managed gateway, independent of global TTS selection."""
import json
import uuid
from urllib.parse import urlparse
from urllib.request import Request, build_opener
from model_catalog import NoRedirect


def resolve_gateway():
    from tools.managed_tool_gateway import resolve_managed_tool_gateway
    gateway = resolve_managed_tool_gateway('openai-audio')
    if gateway is None:
        raise RuntimeError('Subscription speech unavailable')
    parsed = urlparse(gateway.gateway_origin)
    if parsed.scheme != 'https' or not (parsed.hostname or '').endswith('.nousresearch.com'):
        raise RuntimeError('Unsupported speech gateway')
    return gateway


def synthesize(text):
    gateway = resolve_gateway()
    body = json.dumps({'model': 'gpt-4o-mini-tts', 'voice': 'alloy', 'input': text,
                       'response_format': 'mp3', 'instructions': '自然な日本語で話してください。'}).encode()
    request = Request(gateway.gateway_origin.rstrip('/') + '/v1/audio/speech', data=body,
                      headers={'Authorization': 'Bearer ' + gateway.nous_user_token,
                               'Content-Type': 'application/json', 'x-idempotency-key': str(uuid.uuid4())}, method='POST')
    with build_opener(NoRedirect).open(request, timeout=35) as response:
        if not response.headers.get('Content-Type', '').lower().startswith('audio/'):
            raise RuntimeError('Unexpected speech response')
        audio = response.read(4_000_001)
        if not audio or len(audio) > 4_000_000:
            raise RuntimeError('Invalid speech response')
        return audio
