"""Private AgentLive bridge: Live voice, Hermes, Japanese STT and durable Drive spool."""
import asyncio
import base64
import contextlib
import hashlib
import hmac
import json
import os
import re
import sqlite3
import tempfile
import uuid
import time
from datetime import datetime, timezone
from pathlib import Path
from aiohttp import web, ClientSession, ClientTimeout, WSMsgType, WSServerHandshakeError
from drive import DrivePublisher
from speech import JapaneseTranscriber
from economy import EconomySettings, LiveEconomy, ProviderBackoff
from model_catalog import ModelCatalog, MODEL_ID, SUBSCRIPTIONS
from urllib.parse import urlencode
import workspaces
from companion import CompanionJudge, judge_turn, client_credential
import host_policy
from fast_reply import reply as fast_reply
from gemini_direct import credential as gemini_credential

ROOT = Path(os.environ.get('AGENT_LIVE_DATA', str(Path.home() / '.local/share/agent-live')))
ROOT.mkdir(parents=True, exist_ok=True, mode=0o700)
economy = EconomySettings(ROOT)
provider_backoff = ProviderBackoff()
PROVIDER_KEYS = {'gemini':'GEMINI_API_KEY','openai':'OPENAI_API_KEY','grok':'XAI_API_KEY','groq':'GROQ_API_KEY','jev':'TYPESAFE_API_KEY'}
provider_keys_path = ROOT / 'provider-keys.json'
if provider_keys_path.exists():
    for provider, key in json.loads(provider_keys_path.read_text()).items():
        if provider in PROVIDER_KEYS: os.environ[PROVIDER_KEYS[provider]] = key
TOKEN = os.environ.get('AGENT_LIVE_TOKEN', '')
HERMES = os.environ.get('HERMES_API_URL', 'http://127.0.0.1:8642')
HERMES_KEY = os.environ.get('HERMES_API_KEY', '')
MAX_SPOOL = int(os.environ.get('AGENT_LIVE_MAX_BYTES', str(2 * 1024 ** 3)))
db = sqlite3.connect(ROOT / 'archive.sqlite')
db.execute('PRAGMA journal_mode=WAL')
db.execute('CREATE TABLE IF NOT EXISTS archive (id TEXT PRIMARY KEY, metadata TEXT NOT NULL, verified INTEGER DEFAULT 0)')
db.execute('CREATE TABLE IF NOT EXISTS timeline (session TEXT, event TEXT, source TEXT, timestamp TEXT, text TEXT, final INTEGER, PRIMARY KEY(session,event))')
db.execute('CREATE TABLE IF NOT EXISTS finish (session TEXT PRIMARY KEY, expected TEXT, status TEXT, minutes TEXT)')
db.execute('CREATE TABLE IF NOT EXISTS agent_runs (session TEXT PRIMARY KEY, state TEXT)')
db.execute('CREATE TABLE IF NOT EXISTS agent_requests (request TEXT PRIMARY KEY, session TEXT, state TEXT)')
for saved_session, saved_json in db.execute('SELECT session,state FROM agent_runs').fetchall():
    saved_request = json.loads(saved_json).get('request_id')
    if saved_request: db.execute('INSERT OR IGNORE INTO agent_requests VALUES(?,?,?)',(saved_request,saved_session,saved_json))
db.execute('CREATE TABLE IF NOT EXISTS stop_requests (request TEXT PRIMARY KEY, session TEXT)')
db.execute("UPDATE finish SET status='pending' WHERE status='processing'")
db.commit()
TERMINAL = ('completed', 'failed', 'cancelled', 'stopped', 'interrupted')
active_runs = {session: json.loads(state) for session, state in db.execute('SELECT session,state FROM agent_runs')
               if json.loads(state).get('status') not in TERMINAL}
for state in active_runs.values(): state['recovered'] = True
live_sessions = {}
live_policies = {}
upload_lock = asyncio.Lock()
run_lock = asyncio.Lock()
model_catalog = ModelCatalog()

def run_body(session, state):
    value = state['input']
    if state.get('image'):
        value = [{'role': 'user', 'content': [{'type': 'text', 'text': value}, {'type': 'image_url', 'image_url': {'url': state['image']}}]}]
    return {'input': value, 'session_id': session, **state.get('runtime', {})}

def runtime_selection(payload):
    provider = payload.get('provider', '')
    model = payload.get('model', '')
    if provider not in ('', *SUBSCRIPTIONS) or not isinstance(model, str) or (model and not MODEL_ID.fullmatch(model)):
        raise web.HTTPBadRequest(text='Invalid provider or model')
    if provider and not model:
        raise web.HTTPBadRequest(text='Select a subscription model before starting')
    return {key: value for key, value in [('provider', provider), ('model', model)] if value}

def persist_run(session, state):
    if state.get('status') in TERMINAL: state.pop('image', None)
    latest = db.execute('SELECT state FROM agent_runs WHERE session=?',(session,)).fetchone()
    if active_runs.get(session) is state or not latest or json.loads(latest[0]).get('request_id') == state.get('request_id'):
        db.execute('INSERT INTO agent_runs VALUES(?,?) ON CONFLICT(session) DO UPDATE SET state=excluded.state', (session,json.dumps(state)))
    if state.get('request_id'): db.execute('INSERT INTO agent_requests VALUES(?,?,?) ON CONFLICT(request) DO UPDATE SET state=excluded.state',(state['request_id'],session,json.dumps(state)))
    db.commit()

def persist_policy(session, purpose, host_mode='main'):
    path = ROOT / 'run-policy.json'
    policies = json.loads(path.read_text()) if path.exists() else {}
    policies[session] = 'dedicated_draft' if purpose == 'draft' and host_mode == 'dedicated' else purpose
    temp = path.with_suffix('.tmp'); temp.write_text(json.dumps(policies)); temp.chmod(0o600); temp.replace(path)

def run_headers(session, state):
    return {'Authorization':'Bearer '+HERMES_KEY, 'X-Hermes-Session-Id':session,
            'X-Hermes-Session-Key':'agent-live:'+session, 'Idempotency-Key':state['request_id']}

def extract_text(value):
    if isinstance(value, str): return value
    if isinstance(value, dict):
        for field in ('output_text','final_response','text','content','output','response','result'):
            if field in value:
                text = extract_text(value[field])
                if text: return text
    if isinstance(value, list): return '\n'.join(filter(None,(extract_text(x) for x in value)))
    return ''

async def run_status(request):
    session = request.match_info['session']
    request_id = request.query.get('request_id')
    state = active_runs.get(session)
    if request_id and (not state or state.get('request_id') != request_id):
        row = db.execute('SELECT state FROM agent_requests WHERE request=? AND session=?',(request_id,session)).fetchone()
        if not row: raise web.HTTPNotFound()
        saved = json.loads(row[0])
        return web.json_response({'status':saved.get('status'),'text':saved.get('text',''),'run_id':saved.get('run_id'),'request_id':saved.get('request_id')})
    if not state:
        row = db.execute('SELECT state FROM agent_runs WHERE session=?',(session,)).fetchone()
        if not row: raise web.HTTPNotFound()
        saved = json.loads(row[0])
        return web.json_response({'status':saved.get('status'),'text':saved.get('text',''),'run_id':saved.get('run_id'),'request_id':saved.get('request_id')})
    http = request.app['http']; headers = run_headers(session,state)
    if not state.get('run_id'):
        if not state.get('recovered'): return web.json_response({'status':'admitting','text':'','request_id':state['request_id']})
        async with run_lock:
            if not state.get('run_id'):
                persist_policy(session,state.get('purpose','think'),state.get('host_mode','main'))
                # A repeated admission uses the durable Hermes idempotency key after a bridge crash.
                async with http.post(HERMES+'/v1/runs',headers=headers,json=run_body(session,state)) as response:
                    if response.status not in (200,201,202): raise web.HTTPBadGateway()
                    result = await response.json()
                state['run_id'] = result.get('id') or result.get('run_id')
                if not state['run_id']: raise web.HTTPBadGateway()
                persist_run(session,state)
    run_id = state['run_id']
    async with http.get(HERMES+'/v1/runs/'+run_id,headers=headers) as response:
        if response.status != 200: raise web.HTTPBadGateway()
        current = await response.json()
    status = current.get('status','running'); state['status'] = status
    if state.get('stop') and status not in TERMINAL:
        async with http.post(HERMES+'/v1/runs/'+run_id+'/stop',headers=headers,json={}): pass
    text = extract_text(current) if status == 'completed' else ''
    if status in TERMINAL:
        state['text'] = text
        if active_runs.get(session) is state: active_runs.pop(session,None)
    persist_run(session,state)
    return web.json_response({'status':status,'text':text,'run_id':run_id,'request_id':state['request_id']})

def get_item(key):
    row = db.execute('SELECT metadata,verified FROM archive WHERE id=?', (key,)).fetchone()
    if not row:
        return None
    item = json.loads(row[0]); item['cloud_verified'] = bool(row[1])
    return item

def save_item(item):
    existing = get_item(item['id'])
    if existing:
        # Network workers may have read the same item before another worker committed.
        if existing.get('transcribed'):
            item['transcribed'] = True
            if existing.get('transcript_id'): item['transcript_id'] = existing['transcript_id']
        if existing.get('cloud_verified'):
            item['cloud_verified'] = True; item['cloud_file_id'] = existing['cloud_file_id']
    db.execute('INSERT INTO archive(id,metadata,verified) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET metadata=excluded.metadata,verified=excluded.verified',
        (item['id'], json.dumps(item), int(item.get('cloud_verified', False))))
    db.commit()

def receipt(item):
    return {'exists': True, 'id': item['id'], 'sha256': item['sha256'], 'cloud_verified': item.get('cloud_verified', False),
        'cloud_file_id': item.get('cloud_file_id'), 'status': 'saved' if item.get('cloud_verified') else 'awaiting_drive'}

@web.middleware
async def authenticate(request, handler):
    supplied = request.headers.get('Authorization', '').removeprefix('Bearer ')
    authorized = bool(TOKEN and hmac.compare_digest(supplied, TOKEN))
    if not authorized and request.path.startswith('/artifacts/'):
        authorized = bool(TOKEN and workspaces.permits(request,TOKEN))
    if not authorized:
        raise web.HTTPUnauthorized(text='Connect this device to AgentLive.')
    try:
        return await handler(request)
    except web.HTTPException:
        raise
    except Exception:
        # Provider error bodies, transcripts and credentials never enter service logs.
        return web.json_response({'error': 'operation_failed', 'recordings_retained': True}, status=502)

async def health(request):
    agent = False
    drive = False
    try:
        async with request.app['http'].get(HERMES + '/v1/capabilities', headers={'Authorization': 'Bearer ' + HERMES_KEY}, timeout=ClientTimeout(total=3)) as response:
            agent = response.status == 200
    except Exception:
        pass
    if request.app['drive'].configured:
        try:
            await asyncio.wait_for(request.app['drive'].authorization(), 5); drive = True
        except Exception: pass
    return web.json_response({'agent': agent, 'drive': drive,
        'live': {p: bool(os.environ.get(k)) for p, k in [('gemini', 'GEMINI_API_KEY'), ('openai', 'OPENAI_API_KEY'), ('grok', 'XAI_API_KEY')]},
        'stt': bool(os.environ.get('GROQ_API_KEY')), 'pending': db.execute('SELECT COUNT(*) FROM archive WHERE verified=0').fetchone()[0],
        'economy': economy.public(), 'host_policy': host_policy.public(ROOT),
        'jev': bool(os.environ.get('TYPESAFE_API_KEY') or os.environ.get('JEV_API_KEY')),
        'active_live_sessions': len(live_sessions), 'active_reply_sessions': len(request.app.get('fast_replies', ()))})

async def host_settings(request):
    if request.method == 'POST':
        body = await request.json()
        if not isinstance(body, dict) or body.get('mode') not in ('main', 'dedicated'): raise web.HTTPBadRequest()
        host_policy.save(ROOT, body['mode'])
    return web.json_response(host_policy.public(ROOT))

async def models(request):
    if request.query.get('refresh') == '1': model_catalog.invalidate()
    return web.json_response(await model_catalog.get())

async def economy_settings(request):
    if request.method == 'POST':
        body = await request.json()
        if not isinstance(body, dict) or type(body.get('enabled')) is not bool: raise web.HTTPBadRequest()
        economy.save(body['enabled'])
    return web.json_response(economy.public())

async def configure_provider(request):
    body = await request.json(); provider = body.get('provider'); key = str(body.get('key','')).strip()
    if provider not in PROVIDER_KEYS or not 16 <= len(key) <= 4096 or any(ord(c) < 33 or ord(c) > 126 for c in key):
        raise web.HTTPBadRequest(text='Invalid provider credential')
    provider_backoff.clear(provider)
    values = json.loads(provider_keys_path.read_text()) if provider_keys_path.exists() else {}
    values[provider] = key
    temporary = provider_keys_path.with_suffix('.tmp')
    with temporary.open('w') as stream:
        os.chmod(temporary,0o600);json.dump(values,stream);stream.flush();os.fsync(stream.fileno())
    temporary.replace(provider_keys_path);os.environ[PROVIDER_KEYS[provider]] = key
    model_catalog.invalidate()
    return web.json_response({'stored':True,'provider':provider})

async def archive_status(request):
    item = get_item(request.match_info['id'])
    return web.json_response(receipt(item) if item else {'exists': False})

async def archive_upload(request):
    # Serialize admission so concurrent uploads cannot reuse a .part or exceed the spool budget.
    async with upload_lock:
        return await _archive_upload(request)

async def _archive_upload(request):
    key = request.match_info['id']
    if not re.fullmatch(r'[A-Za-z0-9_-]{1,80}', key):
        raise web.HTTPBadRequest()
    try:
        item = json.loads(base64.b64decode(request.headers['X-Archive-Metadata'], validate=True))
        if item['id'] != key or not re.fullmatch(r'[0-9a-f]{64}', item['sha256']):
            raise ValueError()
    except Exception:
        raise web.HTTPBadRequest(text='Invalid archive metadata')
    existing = get_item(key)
    if existing:
        if existing['sha256'] != item['sha256']:
            raise web.HTTPConflict(text='Archive identifier already used')
        return web.json_response(receipt(existing))
    used = sum(p.stat().st_size for p in ROOT.glob('*.blob'))
    part = ROOT / (key + '.part')
    digest = hashlib.sha256(); size = 0
    try:
        with part.open('wb') as stream:
            async for block in request.content.iter_chunked(65536):
                size += len(block)
                if size > 32 * 1024 ** 2 or used + size > MAX_SPOOL:
                    raise web.HTTPInsufficientStorage(text='Pending storage full; retain original')
                stream.write(block); digest.update(block)
            stream.flush(); os.fsync(stream.fileno())
        if digest.hexdigest() != item['sha256'] or size != item['bytes']:
            raise web.HTTPBadRequest(text='Checksum mismatch')
        part.replace(ROOT / (key + '.blob'))
        for field in ('cloudFileID','cloud_file_id','upload_url','cloud_verified','transcribed','transcript_id','stt_retry_at'):
            item.pop(field, None)
        item['cloud_verified'] = False
        save_item(item)
        finished = db.execute('SELECT expected FROM finish WHERE session=?', (item['sessionID'],)).fetchone()
        if finished and item.get('kind') != 'minutes':
            expected = sorted(set(json.loads(finished[0])) | {key})
            db.execute("UPDATE finish SET expected=?,status='pending' WHERE session=?", (json.dumps(expected),item['sessionID'])); db.commit()
        if item.get('kind') == 'transcript':
            for line_number, line in enumerate((ROOT / (key + '.blob')).read_text().splitlines()):
                try:
                    row = json.loads(line)
                    db.execute('INSERT INTO timeline VALUES(?,?,?,?,?,?) ON CONFLICT(session,event) DO UPDATE SET source=excluded.source,timestamp=excluded.timestamp,text=excluded.text,final=excluded.final WHERE excluded.final>=timeline.final AND excluded.timestamp>=timeline.timestamp',
                        (item['sessionID'], str(row.get('id') or key + ':' + str(line_number)), str(row.get('source',item.get('source',''))), str(row.get('timestamp','')), str(row.get('text','')), int(row.get('isFinal',True))))
                except (ValueError, TypeError): continue
            db.commit()
    finally:
        with contextlib.suppress(FileNotFoundError): part.unlink()
    return web.json_response(receipt(item), status=201)

async def agent(request):
    payload = await request.json()
    if not isinstance(payload, dict): raise web.HTTPBadRequest()
    runtime = runtime_selection(payload)
    session_id = str(payload.get('session_id', ''))
    if not re.fullmatch(r'[A-Za-z0-9:_-]{1,160}', session_id):
        raise web.HTTPBadRequest()
    purpose = payload.get('purpose', 'think')
    if purpose not in ('think', 'research', 'work', 'policy', 'reply', 'draft', 'memory'): raise web.HTTPBadRequest()
    selected_host_mode = host_policy.mode(ROOT)
    # A retry keeps the original instruction and scope even after the host preset changes.
    # The current host policy still limits tools if a dedicated host is downgraded.
    retry_id = payload.get('request_id')
    if payload.get('background') and isinstance(retry_id, str):
        saved = db.execute('SELECT session,state FROM agent_requests WHERE request=?',(retry_id,)).fetchone()
        if saved and saved[0] == session_id:
            selected_host_mode = json.loads(saved[1]).get('host_mode', 'main')
    instruction = ('検討・比較・計画を日本語で返してください。制作や外部への送信は始めないでください。' if purpose == 'think' else
                   '用語や事実を検索し、日本語で短い説明と出典を返してください。制作・設定変更・メッセージ送信は行わないでください。' if purpose == 'research' else
                   'ユーザーが依頼した作業を進め、成果物と進捗を返してください。')
    if purpose in ('policy', 'reply', 'memory', 'draft'):
        instruction = {'policy': '本人の目的と関連記憶から行動基準のJSONを作ってください。外部への送信・制作は始めないでください。',
            'reply': '日本語で自然な短い音声返答をしてください。ツールは使用しない。未実行の作業が完了したとは言わない。',
            'memory': '本人が明確に記憶を希望した継続的な事実や好みだけをmemoryへ反映し、短く結果を返してください。その他の作業は行わない。',
            'draft': '会話から案や試作品を作ってください。成果物は専用フォルダー内へwrite_fileで保存する。terminal等の実行・既存環境変更・送信・公開・購入は許可されていない。HTMLやMarkdownなど確認できる成果物を作り、結果を日本語で短く返してください。'}[purpose]
    if purpose in ('work', 'draft'):
        directory = ROOT / 'workspaces' / session_id; directory.mkdir(parents=True,exist_ok=True)
        instruction += '\n今回の制作物は専用フォルダー '+str(directory)+' に保存してください。Webの試作は表示可能なindex.htmlも用意してください。Hermes自体の設定や人格は、それが依頼内容に明記された場合だけ変更してください。'
    if purpose == 'draft' and selected_host_mode == 'dedicated':
        instruction = '本人がこの接続先を専用PC／隔離環境として選択しています。このホスト内部の制作・ファイル変更・設定変更・依存パッケージのインストールを進めてください。成果物は '+str(directory)+' にまとめ、Web試作にはindex.htmlを用意してください。外部への送信・公開・購入・他ホストの変更は本人の確認が必要なので実行しない。Hermesの設定や人格は明確な依頼がある場合だけ変更してください。'
    headers = {'Authorization': 'Bearer ' + HERMES_KEY, 'X-Hermes-Session-Id': session_id,
               'X-Hermes-Session-Key': 'agent-live:' + session_id,
               'Idempotency-Key': str(payload.get('request_id') or __import__('uuid').uuid4())}
    http = request.app['http']
    prepared_input = instruction+'\n'+str(payload.get('input',''))[:30000]
    async with run_lock:
        if db.execute('SELECT 1 FROM stop_requests WHERE request=?',(headers['Idempotency-Key'],)).fetchone(): raise web.HTTPGone(text='This request was stopped before admission')
        cached = db.execute('SELECT session,state FROM agent_requests WHERE request=?',(headers['Idempotency-Key'],)).fetchone()
        if cached and payload.get('background'):
            previous_state = json.loads(cached[1])
            if cached[0] != session_id or previous_state.get('input') != prepared_input or previous_state.get('runtime', {}) != runtime: raise web.HTTPConflict(text='Request identifier already used with different input or model')
            return web.json_response({'status':previous_state.get('status','running'),'run_id':previous_state.get('run_id')},status=202)
        existing = active_runs.get(session_id)
        if existing and existing.get('run_id'):
            async with http.get(HERMES + '/v1/runs/' + existing['run_id'], headers=headers) as response:
                if response.status != 200: raise web.HTTPBadGateway()
                previous = await response.json()
            if previous.get('status') in ('completed','failed','cancelled','stopped','interrupted'):
                existing['status'] = previous['status']; existing['text'] = extract_text(previous) if previous['status']=='completed' else ''; persist_run(session_id,existing)
                active_runs.pop(session_id, None); existing = None
        if existing: raise web.HTTPConflict(text='This conversation has an active task')
        persist_policy(session_id,purpose,selected_host_mode)
        state = {'run_id': None, 'stop': False, 'status':'admitting', 'request_id':headers['Idempotency-Key'],
                 'input':prepared_input,'purpose':purpose,'runtime':runtime,'host_mode':selected_host_mode}
        frame_session = payload.get('frame_session', '')
        if purpose == 'reply' and isinstance(frame_session, str) and re.fullmatch(r'[A-Za-z0-9-]{1,100}', frame_session):
            image = ROOT / 'frames' / (frame_session + '.jpg')
            if image.exists() and time.time() - image.stat().st_mtime < 30:
                state['image'] = 'data:image/jpeg;base64,' + base64.b64encode(image.read_bytes()).decode()
        active_runs[session_id] = state; persist_run(session_id,state)
    current = {}; run_id = None; background = bool(payload.get('background'))
    try:
        async with http.post(HERMES + '/v1/runs', headers=headers,
            json=run_body(session_id,state)) as response:
            if response.status not in (200, 201, 202):
                raise web.HTTPBadGateway(text='Agent did not accept request')
            run = await response.json()
        run_id = run.get('id') or run.get('run_id')
        if not run_id: raise web.HTTPBadGateway()
        state['run_id'] = run_id
        state['status'] = 'running'; persist_run(session_id,state)
        if state['stop']:
            async with http.post(HERMES + '/v1/runs/' + run_id + '/stop', headers=headers, json={}): pass
        if payload.get('background'):
            return web.json_response({'status':'running','run_id':run_id},status=202)
        for _ in range(180):
            async with http.get(HERMES + '/v1/runs/' + run_id, headers=headers) as response:
                current = await response.json()
            status = current.get('status')
            if status in ('completed', 'failed', 'cancelled', 'stopped', 'interrupted'):
                if status != 'completed': return web.json_response({'text': '', 'status': status, 'run_id': run_id})
                return web.json_response({'text': extract_text(current), 'status': status, 'run_id': run_id})
            if status in ('awaiting_approval', 'waiting_for_approval', 'needs_attention'):
                state['approval_wait'] = True
                return web.json_response({'text': 'この作業にはHermes側で確認が必要です。', 'status': status, 'run_id': run_id})
            await asyncio.sleep(1)
        async with http.post(HERMES + '/v1/runs/' + run_id + '/stop', headers=headers, json={}): pass
        raise web.HTTPGatewayTimeout()
    except BaseException:
        if background:
            state['recovered'] = True; persist_run(session_id,state)
        raise
    finally:
        if not background and current.get('status') not in ('awaiting_approval', 'waiting_for_approval', 'needs_attention') and active_runs.get(session_id) is state:
            active_runs.pop(session_id, None)
            state['status'] = current.get('status','failed'); state['text'] = extract_text(current) if state['status']=='completed' else ''
            persist_run(session_id,state)

async def stop_agent(request):
    body = await request.json(); session_id = str(body.get('session_id')); state = active_runs.get(session_id)
    request_id = str(body.get('request_id',''))
    if request_id:
        db.execute('INSERT OR IGNORE INTO stop_requests VALUES(?,?)',(request_id,session_id));db.commit()
        if state and state.get('request_id') != request_id: state = None
    run_id = state.get('run_id') if state else None
    if state: state['stop'] = True; persist_run(str(body.get('session_id')),state)
    if run_id:
        async with request.app['http'].post(HERMES + '/v1/runs/' + run_id + '/stop', headers={'Authorization': 'Bearer ' + HERMES_KEY}, json={}) as response:
            if response.status not in (200, 202): raise web.HTTPBadGateway()
    return web.json_response({'stop_requested': bool(state or request_id)})

async def context(request):
    home = Path(os.environ.get('HERMES_HOME', str(Path.home() / '.hermes')))
    parts = []
    for name in ('SOUL.md', 'memories/MEMORY.md', 'memories/USER.md'):
        path = home / name
        if path.is_file(): parts.append(path.read_text()[:6000])
    return web.json_response({'context': '\n'.join(parts), 'agent': 'Hermes'})

async def records(request):
    query = request.query.get('q', '')[:200]
    if query:
        rows = db.execute('SELECT session,source,timestamp,text FROM timeline WHERE final=1 AND instr(text,?)>0 ORDER BY timestamp DESC LIMIT 40', (query,)).fetchall()
        return web.json_response({'matches': [dict(zip(('session','source','timestamp','text'), row)) for row in rows]})
    rows = db.execute('SELECT session,MAX(timestamp),COUNT(*) FROM timeline GROUP BY session ORDER BY MAX(timestamp) DESC LIMIT 40').fetchall()
    return web.json_response({'sessions': [dict(zip(('session','last_at','entries'), row)) for row in rows]})

async def session_record(request):
    session = request.match_info['session']
    rows = db.execute('SELECT event,source,timestamp,text FROM timeline WHERE session=? AND final=1 ORDER BY timestamp DESC LIMIT 2000', (session,)).fetchall()
    return web.json_response({'session': session, 'entries': [dict(zip(('id','source','timestamp','text'), row)) for row in reversed(rows)]})

async def finish_session(request):
    session = request.match_info['session']
    if not re.fullmatch(r'[A-Za-z0-9:_-]{1,160}',session): raise web.HTTPBadRequest()
    body = await request.json(); expected = sorted(set(body.get('items', [])))
    if len(expected) > 20000 or any(not isinstance(key,str) or not re.fullmatch(r'[A-Za-z0-9_-]{1,80}',key) for key in expected): raise web.HTTPBadRequest()
    expected = sorted(set(expected) | {row[0] for row in db.execute("SELECT id FROM archive WHERE json_extract(metadata,'$.sessionID')=? AND json_extract(metadata,'$.kind')!='minutes'", (session,))})
    encoded = json.dumps(expected)
    current = db.execute('SELECT expected,status,minutes FROM finish WHERE session=?',(session,)).fetchone()
    if not current or current[0] != encoded:
        db.execute("INSERT INTO finish VALUES(?,?,'pending','') ON CONFLICT(session) DO UPDATE SET expected=excluded.expected,status='pending'",(session,encoded)); db.commit()
        return web.json_response({'status':'pending'})
    return web.json_response({'status':current[1], 'minutes':current[2] if current[1]=='completed' else ''})

async def minutes_worker(app):
    while True:
        for session, expected_json in db.execute("SELECT session,expected FROM finish WHERE status='pending'").fetchall():
            expected = json.loads(expected_json)
            if any(get_item(key) is None for key in expected): continue
            if any(item.get('kind') == 'audio' and item.get('source') != 'assistant' and not item.get('transcribed')
                   for key in expected for item in [get_item(key)]): continue
            rows = db.execute('SELECT source,timestamp,text FROM timeline WHERE session=? AND final=1 ORDER BY timestamp', (session,)).fetchall()
            if not expected: continue
            db.execute("UPDATE finish SET status='processing' WHERE session=?",(session,)); db.commit()
            try:
                transcript = '\n'.join(f'{stamp} {source}: {text}' for source,stamp,text in rows)
                parts=[]
                for offset in range(0,len(transcript),24000):
                    prompt = '以下は録音記録の一部分です。ツールを使わず、日本語のMarkdownで要約、決定事項、未決事項、次の行動を整理してください。不明な内容を補わず、繰り返しの文字起こしはまとめてください。\n' + transcript[offset:offset+24000]
                    async with app['http'].post('http://127.0.0.1:'+os.environ.get('AGENT_LIVE_PORT','8787')+'/agent', headers={'Authorization':'Bearer '+TOKEN}, json={'input':prompt,'session_id':'minutes-'+session,'purpose':'think'}) as response:
                        if response.status != 200: raise RuntimeError('Minutes postponed')
                        part=(await response.json()).get('text','')
                    if not part: raise RuntimeError('Minutes incomplete')
                    parts.append(part)
                minutes='# 会話の記録\n\n'+ ('\n\n---\n\n'.join(parts) if parts else '文字起こしで確認できた発話はありませんでした。音声の原本は保存されています。\n')
                data=minutes.encode(); key=uuid.uuid5(uuid.NAMESPACE_URL,session+hashlib.sha256(data).hexdigest()).hex
                item={'id':key,'sessionID':session,'source':'hermes','kind':'minutes','filename':'minutes-'+session+'.md','mimeType':'text/markdown','bytes':len(data),'sha256':hashlib.sha256(data).hexdigest(),'startedAt':time.time()-978307200,'duration':0,'cloud_verified':False}
                async with upload_lock: store_generated(item, data)
                db.execute("UPDATE finish SET status='completed',minutes=? WHERE session=? AND expected=?",(minutes,session,expected_json)); db.commit()
            except Exception:
                db.execute("UPDATE finish SET status='pending' WHERE session=?",(session,)); db.commit()
        await asyncio.sleep(20)

async def transcribe(request):
    data = await request.read()
    text = await request.app['speech'].transcribe(data)
    return web.json_response({'text': text})

def store_generated(item, data):
    if get_item(item['id']): return
    used = sum(p.stat().st_size for p in ROOT.glob('*.blob'))
    if used + len(data) > MAX_SPOOL: raise RuntimeError('Pending storage full')
    path = ROOT / (item['id'] + '.part')
    with path.open('wb') as stream:
        stream.write(data); stream.flush(); os.fsync(stream.fileno())
    path.replace(ROOT / (item['id'] + '.blob')); save_item(item)

async def process_transcriptions(app):
    processed = 0
    for key, in db.execute('SELECT id FROM archive').fetchall():
        item = get_item(key)
        if item.get('kind') != 'audio' or item.get('source') == 'assistant' or item.get('transcribed') or item.get('stt_retry_at',0) > time.time(): continue
        try:
            path = ROOT / (key + '.blob')
            try: data = await asyncio.to_thread(path.read_bytes)
            except FileNotFoundError:
                if not item.get('cloud_verified'): continue
                data = await app['drive'].download(item)
            if hashlib.sha256(data).hexdigest() != item['sha256']: raise RuntimeError('Original checksum differs')
            text = await app['speech'].transcribe(data)
            stamp = datetime.fromtimestamp(float(item.get('startedAt',time.time()-978307200))+978307200,timezone.utc).isoformat().replace('+00:00','Z')
            async with upload_lock:
                current = get_item(key)
                if text:
                    transcript_id = uuid.uuid5(uuid.NAMESPACE_URL,'transcript:'+key).hex
                    row = {'id':key,'source':'verified:'+item.get('source','audio'),'timestamp':stamp,'text':text,'isFinal':True}
                    encoded = (json.dumps(row,ensure_ascii=False)+'\n').encode()
                    transcript_item = {'id':transcript_id,'sessionID':item['sessionID'],'source':row['source'],'kind':'transcript','filename':transcript_id+'.jsonl','mimeType':'application/x-ndjson','bytes':len(encoded),'sha256':hashlib.sha256(encoded).hexdigest(),'startedAt':item.get('startedAt',time.time()-978307200),'duration':item.get('duration',0),'cloud_verified':False}
                    store_generated(transcript_item,encoded)
                    db.execute('INSERT INTO timeline VALUES(?,?,?,?,?,1) ON CONFLICT(session,event) DO NOTHING', (item['sessionID'],key,row['source'],stamp,text))
                    current['transcript_id'] = transcript_id
                current['transcribed'] = True; current.pop('stt_retry_at',None); save_item(current)
        except Exception:
            current = get_item(key); current['stt_retry_at'] = time.time()+60; save_item(current)
        processed += 1
        if processed >= 3: break

async def transcription_worker(app):
    while True:
        try: await process_transcriptions(app)
        except Exception: pass
        await asyncio.sleep(5)

async def speak(request):
    body = await request.json()
    if not isinstance(body, dict) or body.get('provider', '') not in ('', 'edge', 'nous'): raise web.HTTPBadRequest()
    text = str(body.get('text', ''))[:10000]
    selected = body.get('provider') or os.environ.get('AGENT_LIVE_TTS_PROVIDER') or 'edge'
    def synthesize(part):
        # An app-specific override leaves normal Hermes voice settings untouched.
        provider = selected
        if provider == 'nous':
            from subscription_speech import synthesize as nous_speech
            return nous_speech(part)
        with tempfile.TemporaryDirectory(prefix='tts-', dir=ROOT) as directory:
            output = Path(directory) / 'speech.mp3'
            if provider == 'edge':
                import edge_tts
                # App-only Japanese voice; do not modify Hermes' existing voice or config.
                asyncio.run(edge_tts.Communicate(part, voice=os.environ.get('AGENT_LIVE_EDGE_VOICE', 'ja-JP-NanamiNeural')).save(str(output)))
                return output.read_bytes()
            from tools.tts_tool import text_to_speech_tool
            result = json.loads(text_to_speech_tool(text=part, output_path=str(output), provider=provider))
            path = result.get('file_path') or (result.get('file_paths') or [None])[0]
            if not path: raise RuntimeError('No TTS result')
            return Path(path).read_bytes()
    response = web.StreamResponse(headers={'Content-Type':'application/x-ndjson'}); await response.prepare(request)
    chunks=[]; current=''
    for phrase in re.findall(r'[^。！？\n]+[。！？\n]?',text):
        if len(current)+len(phrase)>240 and current:chunks.append(current);current=''
        for offset in range(0,len(phrase),240):
            piece=phrase[offset:offset+240]
            if len(current)+len(piece)>240:chunks.append(current);current=''
            current+=piece
    if current:chunks.append(current)
    try:
        for chunk in chunks:
            audio=await asyncio.to_thread(synthesize,chunk)
            mime = 'audio/wav' if audio[:4] == b'RIFF' and audio[8:12] == b'WAVE' else 'audio/mpeg'
            await response.write((json.dumps({'audio':base64.b64encode(audio).decode(),'mime':mime})+'\n').encode())
    except Exception:
        with contextlib.suppress(Exception):await response.write(b'{"error":"tts_unavailable"}\n')
    await response.write_eof();return response

@contextlib.asynccontextmanager
async def provider_connection(app, provider, url, headers):
    if provider_backoff.remaining(provider):
        raise web.HTTPServiceUnavailable(text='Waiting for voice provider recovery')
    try:
        upstream = await asyncio.wait_for(app['http'].ws_connect(url, headers=headers, max_msg_size=8 * 1024 ** 2), 18)
        async with upstream:
            yield upstream
    except WSServerHandshakeError as error:
        if error.status in (401, 403, 429):
            try: delay = float((error.headers or {}).get('Retry-After', '0'))
            except ValueError: delay = 0
            provider_backoff.fail(provider, delay)
            raise web.HTTPServiceUnavailable(text='Waiting for voice provider recovery') from None
        raise

async def live(request):
    provider = request.match_info['provider']
    choices = {
        'gemini': ('wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent', 'GEMINI_API_KEY', 'x-goog-api-key'),
        'openai': ('wss://api.openai.com/v1/realtime?model=' + os.environ.get('OPENAI_LIVE_MODEL', 'gpt-realtime-2.1'), 'OPENAI_API_KEY', 'Authorization'),
        'grok': ('wss://api.x.ai/v1/realtime?model=grok-voice-latest', 'XAI_API_KEY', 'Authorization')}
    if provider not in choices: raise web.HTTPNotFound()
    url, key_name, header = choices[provider]; key = os.environ.get(key_name, '')
    model = request.query.get('model', '')
    if model and not MODEL_ID.fullmatch(model): raise web.HTTPBadRequest()
    if model and provider in ('grok', 'openai'):
        if provider == 'grok' and model != 'grok-voice-latest': raise web.HTTPBadRequest()
        url = url.split('?')[0] + '?' + urlencode({'model': model})
    if not key: raise web.HTTPServiceUnavailable(text='Voice provider is not configured')
    headers = {header: ('Bearer ' if header == 'Authorization' else '') + key}
    async with provider_connection(request.app, provider, url, headers) as upstream:
        session_id = request.query.get('session', '')
        if session_id:
            if not re.fullmatch(r'[A-Za-z0-9:_-]{1,160}', session_id): raise web.HTTPBadRequest()
            live_sessions[session_id] = (provider, upstream)
        client = web.WebSocketResponse(max_msg_size=4 * 1024 ** 2); await client.prepare(request)
        policy = LiveEconomy(economy.enabled)
        if session_id: live_policies[session_id] = policy
        async def relay(source, destination, filter_input=False):
            async for message in source:
                if message.type == WSMsgType.TEXT:
                    if not filter_input:
                        with contextlib.suppress(ValueError, TypeError, AttributeError):
                            event = json.loads(message.data); failure = event.get('error', {})
                            if str(failure.get('code')) in ('401', '403', '429', 'rate_limit_exceeded', 'insufficient_quota') or failure.get('status') == 'RESOURCE_EXHAUSTED':
                                provider_backoff.fail(provider)
                            elif event.get('serverContent') or event.get('type') in ('response.audio.delta', 'response.output_audio.delta'):
                                provider_backoff.clear(provider)
                    payloads = policy.filter_gemini(message.data) if filter_input and provider == 'gemini' else [message.data]
                    for payload in payloads: await destination.send_str(payload)
                elif message.type == WSMsgType.BINARY: await destination.send_bytes(message.data)
                else: break
        tasks = [asyncio.create_task(relay(client, upstream, True)), asyncio.create_task(relay(upstream, client))]
        try:
            await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
        finally:
            for task in tasks: task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            await client.close()
            if session_id and live_sessions.get(session_id, (None, None))[1] is upstream:
                live_sessions.pop(session_id, None); live_policies.pop(session_id, None)
        return client

async def frame(request):
    session_id = request.match_info['session']
    if not re.fullmatch(r'[A-Za-z0-9-]{1,100}', session_id): raise web.HTTPBadRequest()
    data = await request.read()
    if len(data) > 2_000_000 or not data.startswith(b'\xff\xd8\xff'): raise web.HTTPBadRequest()
    directory = ROOT / 'frames'; directory.mkdir(exist_ok=True, mode=0o700)
    for old in directory.glob('*.jpg'):
        if time.time() - old.stat().st_mtime > 30: old.unlink(missing_ok=True)
    images = sorted(directory.glob('*.jpg'), key=lambda value: value.stat().st_mtime)
    for old in images[:-31]: old.unlink(missing_ok=True)
    path = directory / (session_id + '.jpg')
    temporary = path.with_suffix('.tmp'); temporary.write_bytes(data); temporary.chmod(0o600); temporary.replace(path)
    session = live_sessions.get(session_id)
    if not session: return web.json_response({'received': True, 'destination': 'hermes', 'forwarded': False})
    provider, upstream = session
    if provider not in ('gemini', 'openai'): return web.json_response({'received': True, 'destination': 'hermes', 'forwarded': False})
    policy = live_policies.get(session_id)
    if policy and not policy.frame_allowed(data): return web.json_response({'received': True, 'forwarded': False})
    encoded = base64.b64encode(data).decode()
    if provider == 'gemini': await upstream.send_json({'realtimeInput': {'video': {'mimeType': 'image/jpeg', 'data': encoded}}})
    else: await upstream.send_json({'type': 'conversation.item.create', 'item': {'type': 'message', 'role': 'user', 'content': [{'type': 'input_image', 'image_url': 'data:image/jpeg;base64,' + encoded}]}})
    return web.json_response({'received': True})

async def latest_frame(request):
    session_id = request.match_info['session']
    if not re.fullmatch(r'[A-Za-z0-9-]{1,100}', session_id): raise web.HTTPBadRequest()
    path = ROOT / 'frames' / (session_id + '.jpg')
    if not path.exists() or time.time() - path.stat().st_mtime > 30: raise web.HTTPNotFound()
    return web.Response(body=path.read_bytes(), content_type='image/jpeg', headers={'Cache-Control': 'no-store'})

async def publish_worker(app):
    while True:
        if app['drive'].configured:
            for key, in db.execute('SELECT id FROM archive WHERE verified=0').fetchall():
                item = get_item(key); path = ROOT / (key + '.blob')
                if not path.exists(): continue
                try:
                    file_id = await app['drive'].publish(item, path, save_item)
                    item['cloud_file_id'] = file_id; item['cloud_verified'] = True; save_item(item)
                    path.unlink()  # Only after the cloud checksum and durable receipt.
                except Exception:
                    continue
        await asyncio.sleep(15)

async def lifecycle(app):
    if not TOKEN: raise RuntimeError('AGENT_LIVE_TOKEN must be configured')
    async with ClientSession(timeout=ClientTimeout(total=200)) as http:
        app['http'] = http; app['drive'] = DrivePublisher(ROOT, http, os.environ.get('DRIVE_FOLDER_ID', ''))
        app['speech'] = JapaneseTranscriber(http,db, economy=lambda: economy.enabled)
        app['companion'] = CompanionJudge(http,db)
        worker = asyncio.create_task(publish_worker(app))
        notes = asyncio.create_task(minutes_worker(app))
        speech = asyncio.create_task(transcription_worker(app))
        yield
        worker.cancel(); await asyncio.gather(worker, return_exceptions=True)
        notes.cancel(); await asyncio.gather(notes, return_exceptions=True)
        speech.cancel(); await asyncio.gather(speech, return_exceptions=True)
    db.close()

app = web.Application(middlewares=[authenticate], client_max_size=32 * 1024 ** 2)
app['companion_root'] = ROOT
app.cleanup_ctx.append(lifecycle)
app.add_routes(workspaces.routes(ROOT,TOKEN))
app.add_routes([web.post('/companion/judge', judge_turn), web.post('/companion/client-credential', client_credential)])
app.add_routes([web.post('/live/gemini/credential', gemini_credential)])
app.add_routes([web.post('/conversation/reply', fast_reply)])
app.add_routes([web.get('/frame/{session}', latest_frame)])
app.add_routes([web.get('/settings/host', host_settings), web.post('/settings/host', host_settings)])
app.add_routes([web.get('/health', health), web.get('/models', models), web.get('/archive/{id}', archive_status), web.put('/archive/{id}', archive_upload),
    web.post('/settings/provider',configure_provider), web.get('/settings/economy',economy_settings), web.post('/settings/economy',economy_settings), web.get('/context', context), web.get('/records', records), web.get('/sessions/{session}', session_record), web.post('/sessions/{session}/finish', finish_session), web.post('/frame/{session}', frame), web.post('/agent', agent), web.get('/agent/status/{session}',run_status), web.post('/agent/stop', stop_agent), web.post('/transcribe', transcribe), web.post('/tts', speak), web.get('/live/{provider}', live)])
if __name__ == '__main__':
    web.run_app(app, host=os.environ.get('AGENT_LIVE_HOST', '127.0.0.1'), port=int(os.environ.get('AGENT_LIVE_PORT', '8787')), access_log=None, print=None)
