"""One-session, model-constrained Gemini credentials for device-direct Live experiments."""
import os
from datetime import datetime, timedelta, timezone
from aiohttp import ClientTimeout, web
from model_catalog import MODEL_ID


async def credential(request):
    body = await request.json()
    model = body.get('model') if isinstance(body, dict) else None
    if not isinstance(model, str) or not MODEL_ID.fullmatch(model) or not model.startswith('gemini-') or '-live' not in model:
        raise web.HTTPBadRequest()
    key = os.environ.get('GEMINI_API_KEY')
    if not key: raise web.HTTPServiceUnavailable(text='Gemini Live is not configured')
    now = datetime.now(timezone.utc)
    timestamp = lambda value: value.isoformat().replace('+00:00', 'Z')
    payload = {'uses': 1, 'expireTime': timestamp(now + timedelta(minutes=30)),
        'newSessionExpireTime': timestamp(now + timedelta(seconds=60)),
        'bidiGenerateContentSetup': {'model': 'models/' + model}, 'fieldMask': 'model'}
    try:
        async with request.app['http'].post('https://generativelanguage.googleapis.com/v1beta/auth_tokens',
                headers={'x-goog-api-key': key}, json=payload, allow_redirects=False, timeout=ClientTimeout(total=12)) as response:
            if response.status != 200: raise ValueError('Gemini credential unavailable')
            result = await response.json()
            token = result.get('name')
            if not isinstance(token, str) or not token.startswith('auth_tokens/') or len(token) > 8192:
                raise ValueError('Invalid Gemini credential')
    except Exception:
        raise web.HTTPBadGateway(text='Gemini direct connection unavailable') from None
    return web.json_response({'token': token, 'model': model, 'expires_in': 1800}, headers={'Cache-Control': 'no-store'})
