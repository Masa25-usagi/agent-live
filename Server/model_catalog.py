"""Model discovery through Hermes-managed subscription credentials; no global model changes."""
import asyncio
import json
import os
import re
import time
from pathlib import Path
from urllib.parse import urlparse
from urllib.request import Request, build_opener, HTTPRedirectHandler

MODEL_ID = re.compile(r'[A-Za-z0-9_.:/@+-]{1,200}')
SUBSCRIPTIONS = {'xai-oauth': 'Grok（サブスク）', 'nous': 'Nous Portal（サブスク枠）'}


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None  # Never forward an authorization header to a redirected host.


def get_json(url, headers):
    with build_opener(NoRedirect).open(Request(url, headers=headers), timeout=8) as response:
        data = response.read(2_000_001)
        if len(data) > 2_000_000:
            raise ValueError('Model response too large')
        return json.loads(data)


def configured_model():
    try:
        try:
            import hermes_yaml as yaml
        except ImportError:
            import yaml
        root = Path(os.environ.get('HERMES_HOME', str(Path.home() / '.hermes')))
        config = yaml.safe_load((root / 'config.yaml').read_text()) or {}
        return config.get('model', {}) if isinstance(config.get('model'), dict) else {}
    except Exception:
        return {}


def model_rows(ids, preferred=''):
    ids = sorted({value for value in ids if isinstance(value, str) and MODEL_ID.fullmatch(value)})
    if preferred in ids:
        ids.remove(preferred); ids.insert(0, preferred)
    return [{'id': value, 'title': value} for value in ids]


def subscription_adapter(provider):
    if provider == 'xai-oauth':
        from hermes_cli.proxy.adapters.xai import XAIGrokAdapter
        return XAIGrokAdapter()
    from hermes_cli.proxy.adapters.nous_portal import NousPortalAdapter
    return NousPortalAdapter()


def curated_subscription_ids(provider):
    try:
        from hermes_cli.models_catalog_static import _PROVIDER_MODELS
    except ImportError:
        from hermes_cli.models import _PROVIDER_MODELS
    # The OAuth picker has a local curated floor; broad discovery may do slow HTTP probes.
    return list(_PROVIDER_MODELS.get(provider, []))


def subscription_models(provider):
    choice = {'id': provider, 'title': SUBSCRIPTIONS[provider], 'ready': False, 'models': []}
    try:
        adapter = subscription_adapter(provider)
        if not adapter.is_authenticated():
            choice['message'] = 'このサーバーのHermesでサブスク認証を確認してください。'
            return choice
        credential = adapter.get_credential()
        parsed = urlparse(credential.base_url)
        domain = 'x.ai' if provider == 'xai-oauth' else 'nousresearch.com'
        if parsed.scheme != 'https' or not (parsed.hostname == domain or (parsed.hostname or '').endswith('.' + domain)):
            raise ValueError('Unsupported subscription host')
        config = configured_model()
        preferred = config.get('default', '') if config.get('provider') == provider else ''
        if provider == 'xai-oauth':
            # OAuth uses Hermes's curated catalog; GET /models is not an entitlement check.
            choice['models'] = model_rows(curated_subscription_ids(provider), preferred)
            choice['ready'] = bool(choice['models'])
            choice['message'] = 'Hermesの認証情報とモデル候補を取得しました。契約で利用できるかは会話開始後に確認します。'
            return choice
        payload = get_json(credential.base_url.rstrip('/') + '/models', {'Authorization': 'Bearer ' + credential.bearer})
        choice['models'] = model_rows([row.get('id') for row in payload.get('data', []) if isinstance(row, dict)], preferred)
        choice['ready'] = bool(choice['models'])
        choice['message'] = ('モデル一覧に接続できました。推論は会話開始後に確認します。' if choice['ready'] else '選択できるモデルを取得できませんでした。')
    except Exception:
        # Provider exceptions can contain auth material. Return only a public explanation.
        choice['message'] = 'サブスクのモデル一覧に接続できませんでした。サーバー側のHermes認証・契約・接続を確認してください。'
    return choice


def live_models():
    values = {
        'gemini': model_rows([os.environ.get('GEMINI_LIVE_MODEL', 'gemini-3.8-live')]) if os.environ.get('GEMINI_API_KEY') else [],
        'openai': model_rows([os.environ.get('OPENAI_LIVE_MODEL', 'gpt-realtime-2.1')]) if os.environ.get('OPENAI_API_KEY') else [],
        'grok': model_rows(['grok-voice-latest']) if os.environ.get('XAI_API_KEY') else [],
    }
    if os.environ.get('GEMINI_API_KEY'):
        try:
            payload = get_json('https://generativelanguage.googleapis.com/v1beta/models', {'x-goog-api-key': os.environ['GEMINI_API_KEY']})
            discovered = [row['name'].removeprefix('models/') for row in payload.get('models', [])
                          if any('bidi' in method.lower() for method in row.get('supportedGenerationMethods', []))]
            values['gemini'] = model_rows(discovered + [row['id'] for row in values['gemini']])
        except Exception:
            pass  # Retain the configured model, without claiming its availability was verified.
    return values


class ModelCatalog:
    def __init__(self):
        self.value = None
        self.at = 0
        self.lock = asyncio.Lock()

    async def get(self):
        async with self.lock:
            if self.value is not None and time.monotonic() - self.at < 300:
                return self.value
            async def discover(provider):
                try:
                    return await asyncio.wait_for(asyncio.to_thread(subscription_models, provider), 25)
                except Exception:
                    return {'id': provider, 'title': SUBSCRIPTIONS[provider], 'ready': False, 'models': [], 'message': 'モデル一覧の接続確認がタイムアウトしました。'}
            grok, nous, live = await asyncio.gather(discover('xai-oauth'), discover('nous'), asyncio.to_thread(live_models))
            config = configured_model()
            current = {'id': '', 'title': 'Hermesの現在の設定', 'ready': bool(config.get('default')),
                       'models': model_rows([config.get('default', '')]), 'message': '既存のHermes設定を使います。サーバー接続は「接続を確認」で確認できます。'}
            self.value = {'providers': [current, grok, nous], 'live': live}
            self.at = time.monotonic()
            return self.value

    def invalidate(self):
        self.value = None
