import asyncio, base64, copy, hashlib, importlib.util, io, json, os, tempfile, unittest, uuid, wave
from pathlib import Path
from aiohttp.test_utils import TestClient, TestServer
from aiohttp import web, WSServerHandshakeError
from drive import DrivePublisher
from speech import JapaneseTranscriber, digital_silence
from unittest.mock import patch
from types import SimpleNamespace

def wav_sample(value=0):
    output = io.BytesIO()
    with wave.open(output,'wb') as stream:
        stream.setnchannels(1); stream.setsampwidth(2); stream.setframerate(16000)
        stream.writeframes(int(value).to_bytes(2,'little',signed=True)*1600)
    return output.getvalue()

class ArchiveHTTPTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.tmp=tempfile.TemporaryDirectory();os.environ['AGENT_LIVE_DATA']=self.tmp.name;os.environ['AGENT_LIVE_TOKEN']='test-device-token'
        spec=importlib.util.spec_from_file_location('isolated_'+uuid.uuid4().hex,Path(__file__).with_name('app.py'));self.module=importlib.util.module_from_spec(spec);spec.loader.exec_module(self.module)
        self.client=TestClient(TestServer(self.module.app));await self.client.start_server();self.headers={'Authorization':'Bearer test-device-token'}
    async def asyncTearDown(self):await self.client.close();self.tmp.cleanup()
    def metadata(self,data,key='chunk',kind='audio'):
        return {'id':key,'sessionID':'session','filename':key+'.wav','kind':kind,'source':'microphone','mimeType':'audio/wav','bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()}
    async def upload(self,data,item):
        headers={**self.headers,'X-Archive-Metadata':base64.b64encode(json.dumps(item).encode()).decode()}
        return await self.client.put('/archive/'+item['id'],data=data,headers=headers)
    async def test_unauthorized_is_rejected(self):
        response=await self.client.get('/records');self.assertEqual(response.status,401)
    async def test_experimental_endpoints_require_device_authentication(self):
        for path in ('/conversation/reply', '/live/gemini/credential', '/companion/client-credential'):
            response = await self.client.post(path, json={}); self.assertEqual(response.status, 401)
    async def test_model_catalog_is_authenticated_and_public_fields_only(self):
        response=await self.client.get('/models');self.assertEqual(response.status,401)
        async def catalog():return {'providers':[{'id':'nous','title':'Nous','ready':False,'models':[],'message':'認証を確認してください'}],'live':{}}
        with patch.object(self.module.model_catalog,'get',catalog):
            response=await self.client.get('/models',headers=self.headers)
            self.assertEqual(response.status,200);self.assertEqual((await response.json())['providers'][0]['ready'],False)
    async def test_tts_subscription_override_is_forwarded_even_in_economy_mode_and_has_no_paid_fallback(self):
        import subscription_speech
        calls=[]
        def speak(text):calls.append(text);return b'fixture-mp3'
        with patch.object(subscription_speech,'synthesize',speak):
            response=await self.client.post('/tts',headers=self.headers,json={'text':'短い返答。','provider':'nous'})
            self.assertEqual(response.status,200)
            self.assertEqual(base64.b64decode(json.loads(await response.text())['audio']),b'fixture-mp3')
        self.assertEqual(calls,['短い返答。']);self.assertTrue(self.module.economy.enabled)
        def failed(_):raise RuntimeError('fixture-secret')
        with patch.object(subscription_speech,'synthesize',failed):
            response=await self.client.post('/tts',headers=self.headers,json={'text':'返答','provider':'nous'})
            self.assertEqual(await response.text(),'{"error":"tts_unavailable"}\n')
        response=await self.client.post('/tts',headers=self.headers,json={'text':'返答','provider':'unknown'})
        self.assertEqual(response.status,400)
    async def test_automatic_speech_remains_edge_when_economy_is_off_and_paid_keys_exist(self):
        self.module.economy.enabled=False
        calls=[]
        class EdgeSpeech:
            def __init__(self,text,voice):calls.append((text,voice))
            async def save(self,path):Path(path).write_bytes(b'fixture-mp3')
        with patch.dict(os.environ,{'AGENT_LIVE_TTS_PROVIDER':'','GEMINI_API_KEY':'fixture-only'}), patch.dict('sys.modules',{'edge_tts':SimpleNamespace(Communicate=EdgeSpeech)}):
            response=await self.client.post('/tts',headers=self.headers,json={'text':'短い返答。'})
            result=json.loads(await response.text())
            self.assertEqual(base64.b64decode(result['audio']),b'fixture-mp3');self.assertEqual(result['mime'],'audio/mpeg')
        self.assertEqual(calls,[('短い返答。','ja-JP-NanamiNeural')])
    async def test_speech_stream_reports_wav_container_without_changing_explicit_provider(self):
        import subscription_speech
        sample=wav_sample(1000)
        with patch.object(subscription_speech,'synthesize',return_value=sample):
            response=await self.client.post('/tts',headers=self.headers,json={'text':'声。','provider':'nous'})
            result=json.loads(await response.text())
        self.assertEqual(result['mime'],'audio/wav');self.assertEqual(base64.b64decode(result['audio']),sample)
    async def test_economy_settings_require_authentication_and_are_shared_and_durable(self):
        response=await self.client.post('/settings/economy',json={'enabled':False});self.assertEqual(response.status,401)
        response=await self.client.get('/settings/economy',headers=self.headers);self.assertTrue((await response.json())['enabled'])
        response=await self.client.post('/settings/economy',headers=self.headers,json={'enabled':1});self.assertEqual(response.status,400)
        response=await self.client.post('/settings/economy',headers=self.headers,json={'enabled':False});self.assertEqual(response.status,200)
        response=await self.client.get('/settings/economy',headers=self.headers);self.assertFalse((await response.json())['enabled'])
        self.assertEqual((Path(self.tmp.name)/'economy-settings.json').stat().st_mode & 0o777,0o600)
    async def test_live_economy_relays_speech_and_tools_but_keeps_silence_and_duplicate_frames_local(self):
        incoming=asyncio.Queue()
        async def upstream(request):
            socket=web.WebSocketResponse();await socket.prepare(request)
            async for event in socket:
                value=json.loads(event.data);await incoming.put(value)
                if 'setup' in value:await socket.send_json({'setupComplete':{}})
                elif value.get('realtimeInput',{}).get('audio'):
                    await socket.send_json({'serverContent':{'outputTranscription':{'text':'fixture reply'}}})
            return socket
        fake=web.Application();fake.router.add_get('/voice',upstream)
        server=TestServer(fake);await server.start_server()
        original=self.module.app['http'].ws_connect
        def redirected(url,**kwargs):return original(server.make_url('/voice'),**kwargs)
        try:
            with patch.dict(os.environ,{'GEMINI_API_KEY':'fixture-only'}), patch.object(self.module.app['http'],'ws_connect',redirected):
                socket=await self.client.ws_connect('/live/gemini?session=fixture-live',headers=self.headers)
                await socket.send_json({'setup':{'model':'models/gemini-3.8-live','sessionResumption':{'handle':'fixture-resume'}}})
                self.assertIn('setupComplete',await socket.receive_json())
                setup=(await incoming.get())['setup'];self.assertEqual(setup['sessionResumption']['handle'],'fixture-resume')
                silence=(0).to_bytes(2,'little',signed=True)*16000
                await socket.send_json({'realtimeInput':{'audio':{'mimeType':'audio/pcm;rate=16000','data':base64.b64encode(silence).decode()}}})
                tool={'toolResponse':{'functionResponses':[{'id':'fixture','response':{'ok':True}}]}}
                await socket.send_json(tool)
                self.assertEqual(await asyncio.wait_for(incoming.get(),2),tool)
                speech=(30).to_bytes(2,'little',signed=True)*3200
                await socket.send_json({'realtimeInput':{'audio':{'mimeType':'audio/pcm;rate=16000','data':base64.b64encode(speech).decode()}}})
                forwarded=(await asyncio.wait_for(incoming.get(),2))['realtimeInput']['audio']
                self.assertEqual(base64.b64decode(forwarded['data']),silence[-9600:]+speech)
                self.assertEqual((await socket.receive_json())['serverContent']['outputTranscription']['text'],'fixture reply')
                image=b'\xff\xd8\xfffixture-image'
                response=await self.client.post('/frame/fixture-live',headers=self.headers,data=image);self.assertEqual(response.status,200)
                self.assertIn('video',(await asyncio.wait_for(incoming.get(),2))['realtimeInput'])
                response=await self.client.post('/frame/fixture-live',headers=self.headers,data=image)
                self.assertFalse((await response.json())['forwarded'])
                await socket.send_json(tool);self.assertEqual(await asyncio.wait_for(incoming.get(),2),tool)
                await socket.close()
        finally:await server.close()
    async def test_exhausted_voice_provider_is_not_called_again_by_other_devices_during_cooldown(self):
        calls=[]
        def exhausted(*args,**kwargs):
            calls.append(True);raise WSServerHandshakeError(None,(),status=429,headers={'Retry-After':'120'})
        with patch.dict(os.environ,{'GEMINI_API_KEY':'fixture-only'}), patch.object(self.module.app['http'],'ws_connect',exhausted):
            for session in ('iphone','mac','discord'):
                response=await self.client.get('/live/gemini?session='+session,headers=self.headers)
                self.assertEqual(response.status,503)
        self.assertEqual(len(calls),1)
    async def test_tamper_keeps_no_false_receipt(self):
        response=await self.upload(b'altered',self.metadata(b'original'));self.assertEqual(response.status,400)
        response=await self.client.get('/archive/chunk',headers=self.headers);self.assertFalse((await response.json())['exists'])
        self.assertFalse(list(Path(self.tmp.name).glob('*.part')))
    async def test_retry_is_idempotent_and_unverified_original_stays(self):
        data=b'original audio';item=self.metadata(data)
        response=await self.upload(data,item);self.assertEqual(response.status,201)
        self.assertFalse((await response.json())['cloud_verified'])
        response=await self.upload(data,item);self.assertEqual(response.status,200)
        self.assertEqual((Path(self.tmp.name)/'chunk.blob').read_bytes(),data)
        self.assertEqual(self.module.db.execute('SELECT COUNT(*) FROM archive').fetchone()[0],1)
        response=await self.upload(b'different',self.metadata(b'different'));self.assertEqual(response.status,409)
    async def test_parallel_admission_cannot_overfill_spool(self):
        self.module.MAX_SPOOL=12
        responses=await asyncio.gather(self.upload(b'12345678',self.metadata(b'12345678','a')),self.upload(b'abcdefgh',self.metadata(b'abcdefgh','b')))
        self.assertEqual(sorted(r.status for r in responses),[201,507])
    async def test_final_transcript_wins_and_is_searchable(self):
        data=(json.dumps({'id':'utterance','source':'user','timestamp':'2026-10-03T02:00:00Z','text':'日本語の接続試験','isFinal':True},ensure_ascii=False)+'\n').encode()
        response=await self.upload(data,self.metadata(data,'text','transcript'));self.assertEqual(response.status,201)
        response=await self.client.get('/records?q=日本語',headers=self.headers);self.assertEqual(len((await response.json())['matches']),1)
        response=await self.client.post('/sessions/session/finish',headers=self.headers,json={'items':['text']});self.assertEqual((await response.json())['status'],'pending')
    async def test_host_preset_requires_authentication_and_never_upgrades_existing_admissions(self):
        response=await self.client.post('/settings/host',json={'mode':'dedicated'});self.assertEqual(response.status,401)
        response=await self.client.get('/settings/host',headers=self.headers);self.assertEqual((await response.json())['mode'],'main')
        response=await self.client.post('/settings/host',headers=self.headers,json={'mode':'dedicated'});self.assertEqual(response.status,200)
        self.module.persist_policy('old-main','draft','main');self.module.persist_policy('new-dedicated','draft','dedicated')
        from action_policy import directive
        args={'command':'python -m pip install fixture'}
        self.assertEqual(directive(Path(self.tmp.name),'terminal','old-main',args)['action'],'block')
        self.assertIsNone(directive(Path(self.tmp.name),'terminal','new-dedicated',args))
        await self.client.post('/settings/host',headers=self.headers,json={'mode':'main'})
        self.assertEqual(directive(Path(self.tmp.name),'terminal','new-dedicated',args)['action'],'block')
        response=await self.client.post('/settings/host',headers=self.headers,json={'mode':'arbitrary'});self.assertEqual(response.status,400)

    async def test_screen_frames_work_for_subscription_voice_are_private_and_bounded(self):
        image=b'\xff\xd8\xfffixture-screen'
        response=await self.client.post('/frame/phone',data=image);self.assertEqual(response.status,401)
        response=await self.client.post('/frame/phone',headers=self.headers,data=image)
        self.assertEqual(response.status,200);self.assertEqual((await response.json())['destination'],'hermes')
        response=await self.client.get('/frame/phone');self.assertEqual(response.status,401)
        response=await self.client.get('/frame/phone',headers=self.headers)
        self.assertEqual(await response.read(),image);self.assertEqual(response.headers['Cache-Control'],'no-store')
        folder=Path(self.tmp.name)/'frames';self.assertEqual((folder/'phone.jpg').stat().st_mode & 0o777,0o600)
        response=await self.client.post('/frame/phone',headers=self.headers,data=b'not an image');self.assertEqual(response.status,400)
        for index in range(35):await self.client.post('/frame/session-'+str(index),headers=self.headers,data=image)
        self.assertLessEqual(len(list(folder.glob('*.jpg'))),32)
        expired=folder/'session-34.jpg';os.utime(expired,(0,0))
        response=await self.client.get('/frame/session-34',headers=self.headers);self.assertEqual(response.status,404)

    async def test_late_broadcast_chunk_is_included_in_finished_session_and_invalidates_old_minutes(self):
        first=b'first';await self.upload(first,self.metadata(first,'first','video'))
        await self.client.post('/sessions/session/finish',headers=self.headers,json={'items':['first']})
        self.module.db.execute("UPDATE finish SET status='completed',minutes='older summary' WHERE session='session'");self.module.db.commit()
        late=b'late';await self.upload(late,self.metadata(late,'late-screen','video'))
        row=self.module.db.execute("SELECT expected,status FROM finish WHERE session='session'").fetchone()
        self.assertEqual(set(json.loads(row[0])),{'first','late-screen'});self.assertEqual(row[1],'pending')
        response=await self.client.post('/sessions/session/finish',headers=self.headers,json={'items':['first']})
        self.assertEqual((await response.json())['status'],'pending')

    async def test_provider_credentials_are_private_and_never_echoed(self):
        fake_key='fixture-secret-key-never-real'
        response=await self.client.post('/settings/provider',headers=self.headers,json={'provider':'grok','key':fake_key})
        self.assertEqual(response.status,200);self.assertNotIn(fake_key,await response.text())
        path=Path(self.tmp.name)/'provider-keys.json'
        self.assertEqual(path.stat().st_mode & 0o777,0o600)
        response=await self.client.post('/settings/provider',headers=self.headers,json={'provider':'grok','key':'bad\nkey'})
        self.assertEqual(response.status,400)
    async def test_preview_ticket_is_limited_to_its_session_and_relative_assets_work(self):
        base=Path(self.tmp.name)/'workspaces'/'session';base.mkdir(parents=True)
        (base/'index.html').write_text('<html><link rel="stylesheet" href="style.css"><p>Fixture preview</p></html>')
        (base/'style.css').write_text('p { color: blue; }')
        outside=Path(self.tmp.name)/'private.txt';outside.write_text('never expose')
        (base/'escape.txt').symlink_to(outside)
        response=await self.client.get('/workspaces/session',headers=self.headers);files=(await response.json())['files']
        self.assertNotIn('escape.txt',[f['name'] for f in files]);access=files[0]['ticket']
        response=await self.client.get('/artifacts/session/index.html?ticket='+access)
        self.assertEqual(response.status,200);self.assertIn('Fixture preview',await response.text())
        response=await self.client.get('/artifacts/session/style.css');self.assertEqual(response.status,200)
        response=await self.client.get('/artifacts/other/index.html?ticket='+access);self.assertEqual(response.status,401)
        response=await self.client.get('/context',headers={'Cookie':self.module.workspaces.cookie_name('session')+'='+access});self.assertEqual(response.status,401)
        response=await self.client.get('/artifacts/session/escape.txt?ticket='+access);self.assertEqual(response.status,404)
    async def test_stop_before_admission_is_recorded(self):
        self.module.active_runs['session']={'run_id':None,'stop':False}
        response=await self.client.post('/agent/stop',headers=self.headers,json={'session_id':'session'})
        self.assertTrue((await response.json())['stop_requested']);self.assertTrue(self.module.active_runs['session']['stop'])

    async def test_stt_outage_keeps_the_uploaded_original_and_does_not_fake_completion(self):
        data=wav_sample(1000);item=self.metadata(data,'stt-outage')
        response=await self.upload(data,item);self.assertEqual(response.status,201)
        async def unavailable(_):raise ConnectionError('fixture outage')
        self.module.app['speech'].transcribe=unavailable
        await self.module.process_transcriptions(self.module.app)
        self.assertEqual((Path(self.tmp.name)/'stt-outage.blob').read_bytes(),data)
        saved=self.module.get_item('stt-outage')
        self.assertFalse(saved.get('transcribed',False));self.assertFalse(saved['cloud_verified'])
        self.assertEqual(self.module.db.execute('SELECT COUNT(*) FROM timeline').fetchone()[0],0)

    async def test_deferred_stt_uses_verified_drive_audio_and_preserves_cloud_receipt(self):
        data=wav_sample(1000);item=self.metadata(data,'saved-audio')
        await self.upload(data,item)
        saved=self.module.get_item(item['id']);saved['cloud_verified']=True;saved['cloud_file_id']='fixture-drive-file'
        self.module.save_item(saved);(Path(self.tmp.name)/'saved-audio.blob').unlink()
        downloads=[]
        async def download(value):downloads.append(value['id']);return data
        async def recognized(_):return '元の音声から後で文字起こし'
        self.module.app['drive'].download=download;self.module.app['speech'].transcribe=recognized
        await self.module.process_transcriptions(self.module.app)
        current=self.module.get_item(item['id'])
        self.assertTrue(current['cloud_verified']);self.assertTrue(current['transcribed'])
        self.assertEqual(downloads,['saved-audio']);self.assertIsNotNone(self.module.get_item(current['transcript_id']))
        self.module.save_item(saved)  # A publishing worker holding older metadata cannot erase STT progress.
        self.assertTrue(self.module.get_item(item['id'])['transcribed'])
        await self.module.process_transcriptions(self.module.app);self.assertEqual(downloads,['saved-audio'])
        response=await self.client.get('/records?q=後で',headers=self.headers)
        self.assertEqual(len((await response.json())['matches']),1)

    async def test_silent_audio_needs_no_provider_and_is_cached_without_invented_words(self):
        class NoNetwork:
            def post(self,*args,**kwargs):raise AssertionError('Silence must not call a provider')
        recognizer=JapaneseTranscriber(NoNetwork(),self.module.db)
        self.assertTrue(digital_silence(wav_sample(0)));self.assertFalse(digital_silence(wav_sample(1000)))
        self.assertEqual(await recognizer.transcribe(wav_sample(0)),'')
        self.assertEqual(await recognizer.transcribe(wav_sample(0)),'')
        self.assertEqual(self.module.db.execute('SELECT COUNT(*) FROM transcriptions').fetchone()[0],1)

    async def test_same_original_is_recognized_once_across_native_and_server_requests(self):
        class SpeechHTTP:
            calls=0
            def post(self,*args,**kwargs):
                self.calls+=1;return Response(data={'text':'認識結果を共有する'})
        http=SpeechHTTP();recognizer=JapaneseTranscriber(http,self.module.db)
        with patch.dict(os.environ,{'GROQ_API_KEY':'fixture'}):
            answers=await asyncio.gather(recognizer.transcribe(wav_sample(1000)),recognizer.transcribe(wav_sample(1000)))
        self.assertEqual(answers,['認識結果を共有する']*2);self.assertEqual(http.calls,1)

class AgentLifecycleTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        await ArchiveHTTPTests.asyncSetUp(self)
        self.accepted=0;self.state='running';self.last_idempotency=None;self.admission_failures=0
        async def admit(request):
            self.last_body = await request.json()
            if self.admission_failures:
                self.admission_failures-=1;return web.json_response({},status=503)
            self.accepted+=1;self.last_idempotency=request.headers.get('Idempotency-Key')
            self.requested_session=self.last_body.get('session_id')
            return web.json_response({'run_id':'fixture-run'},status=202)
        async def status(request):return web.json_response({'status':self.state,'output_text':'Fixture result' if self.state=='completed' else ''})
        async def stop(request):self.state='stopped';return web.json_response({'status':'stopped'})
        app=web.Application();app.add_routes([web.post('/v1/runs',admit),web.get('/v1/runs/{run}',status),web.post('/v1/runs/{run}/stop',stop)])
        self.hermes=TestServer(app);await self.hermes.start_server();self.module.HERMES=str(self.hermes.make_url('')).rstrip('/')
    async def asyncTearDown(self):await self.hermes.close();await ArchiveHTTPTests.asyncTearDown(self)
    async def test_background_result_is_durable_and_same_request_reconnects(self):
        payload={'session_id':'async-session','input':'fixture','purpose':'think','background':True,'request_id':'stable-request'}
        response=await self.client.post('/agent',headers=self.headers,json=payload);self.assertEqual(response.status,202)
        response=await self.client.post('/agent',headers=self.headers,json=payload);self.assertEqual(response.status,202)
        response=await self.client.post('/agent',headers=self.headers,json={**payload,'input':'changed'});self.assertEqual(response.status,409)
        response=await self.client.post('/agent',headers=self.headers,json={**payload,'request_id':'different-request'});self.assertEqual(response.status,409)
        response=await self.client.get('/agent/status/async-session',headers=self.headers);self.assertEqual((await response.json())['status'],'running')
        self.state='completed'
        response=await self.client.get('/agent/status/async-session',headers=self.headers);self.assertEqual((await response.json())['text'],'Fixture result')
        response=await self.client.post('/agent',headers=self.headers,json=payload);self.assertEqual(response.status,202)
        self.assertEqual((await response.json())['status'],'completed')
        response=await self.client.get('/agent/status/async-session',headers=self.headers);self.assertEqual((await response.json())['text'],'Fixture result')
        self.assertEqual(self.accepted,1);self.assertNotIn('async-session',self.module.active_runs)
        self.assertEqual(self.requested_session,'async-session')
    async def test_old_request_keeps_its_result_after_the_next_job_starts(self):
        payload={'session_id':'history','input':'first','background':True,'request_id':'first-request'}
        response=await self.client.post('/agent',headers=self.headers,json=payload);self.assertEqual(response.status,202)
        self.state='completed'
        response=await self.client.post('/agent',headers=self.headers,json={**payload,'input':'second','request_id':'second-request'})
        self.assertEqual(response.status,202);self.assertEqual(self.accepted,2)
        self.state='running'
        response=await self.client.post('/agent',headers=self.headers,json=payload)
        self.assertEqual((await response.json())['status'],'completed');self.assertEqual(self.accepted,2)
        response=await self.client.get('/agent/status/history?request_id=first-request',headers=self.headers)
        result=await response.json();self.assertEqual(result['text'],'Fixture result');self.assertEqual(result['request_id'],'first-request')
        response=await self.client.get('/agent/status/history?request_id=second-request',headers=self.headers)
        self.assertEqual((await response.json())['status'],'running')
        old=json.loads(self.module.db.execute('SELECT state FROM agent_requests WHERE request=?',('first-request',)).fetchone()[0])
        self.module.persist_run('history',old)  # A late poll must not replace the next job's recovery pointer.
        latest=json.loads(self.module.db.execute('SELECT state FROM agent_runs WHERE session=?',('history',)).fetchone()[0])
        self.assertEqual(latest['request_id'],'second-request')
        response=await self.client.post('/agent',headers=self.headers,json={**payload,'session_id':'other-session'})
        self.assertEqual(response.status,409)
    async def test_admission_outage_can_recover_with_the_original_request_key(self):
        self.admission_failures=1
        payload={'session_id':'admission-outage','input':'fixture','background':True,'request_id':'outage-key'}
        response=await self.client.post('/agent',headers=self.headers,json=payload);self.assertEqual(response.status,502)
        self.assertIn('admission-outage',self.module.active_runs)
        response=await self.client.post('/agent',headers=self.headers,json=payload);self.assertEqual(response.status,202)
        response=await self.client.get('/agent/status/admission-outage?request_id=outage-key',headers=self.headers)
        self.assertEqual((await response.json())['status'],'running')
        self.assertEqual(self.accepted,1);self.assertEqual(self.last_idempotency,'outage-key')
    async def test_stop_uses_the_same_run_and_survives_status_polling(self):
        response=await self.client.post('/agent',headers=self.headers,json={'session_id':'async-session','input':'fixture','background':True})
        self.assertEqual(response.status,202)
        response=await self.client.post('/agent/stop',headers=self.headers,json={'session_id':'async-session'});self.assertTrue((await response.json())['stop_requested'])
        response=await self.client.get('/agent/status/async-session',headers=self.headers);self.assertEqual((await response.json())['status'],'stopped')
    async def test_stop_before_http_admission_prevents_a_late_start(self):
        response=await self.client.post('/agent/stop',headers=self.headers,json={'session_id':'late-session','request_id':'late-request'})
        self.assertTrue((await response.json())['stop_requested'])
        response=await self.client.post('/agent',headers=self.headers,json={'session_id':'late-session','request_id':'late-request','input':'fixture','background':True})
        self.assertEqual(response.status,410);self.assertEqual(self.accepted,0)
    async def test_recovered_admission_reuses_the_hermes_idempotency_key(self):
        state={'run_id':None,'input':'fixture','request_id':'saved-key','stop':False,'status':'admitting','recovered':True}
        self.module.active_runs['recover']=state;self.module.persist_run('recover',state)
        response=await self.client.get('/agent/status/recover',headers=self.headers);self.assertEqual(response.status,200)
        self.assertEqual(self.last_idempotency,'saved-key')
        self.assertEqual(self.requested_session,'recover')
        response=await self.client.get('/agent/status/recover',headers=self.headers);self.assertEqual(response.status,200)
        self.assertEqual(self.accepted,1)
    async def test_selected_subscription_and_model_are_pinned_on_retry_and_crash_recovery(self):
        payload={'session_id':'model-switch','request_id':'model-job','input':'fixture','background':True,'provider':'xai-oauth','model':'grok-fixture'}
        self.admission_failures=1
        response=await self.client.post('/agent',headers=self.headers,json=payload);self.assertEqual(response.status,502)
        self.assertEqual(self.last_body['provider'],'xai-oauth');self.assertEqual(self.last_body['model'],'grok-fixture')
        response=await self.client.post('/agent',headers=self.headers,json={**payload,'model':'another-fixture'});self.assertEqual(response.status,409)
        response=await self.client.post('/agent',headers=self.headers,json={**payload,'provider':'nous'});self.assertEqual(response.status,409)
        response=await self.client.get('/agent/status/model-switch?request_id=model-job',headers=self.headers)
        self.assertEqual(response.status,200);self.assertEqual(self.last_body['model'],'grok-fixture');self.assertEqual(self.last_body['provider'],'xai-oauth')
        self.assertEqual(self.accepted,1)
    async def test_invalid_provider_model_and_missing_subscription_model_are_rejected_before_admission(self):
        base={'session_id':'bad-model','input':'fixture','background':True}
        for selection in ({'provider':'unknown','model':'fixture'},{'provider':'nous'}, {'model':'bad\nmodel'},{'model':10}):
            response=await self.client.post('/agent',headers=self.headers,json={**base,**selection});self.assertEqual(response.status,400)
        self.assertEqual(self.accepted,0)
    async def test_draft_retry_keeps_admitted_scope_after_host_switch(self):
        payload={'session_id':'main-draft','request_id':'main-request','input':'make a clock','purpose':'draft','background':True}
        response=await self.client.post('/agent',headers=self.headers,json=payload);self.assertEqual(response.status,202)
        original=copy.deepcopy(self.last_body)
        await self.client.post('/settings/host',headers=self.headers,json={'mode':'dedicated'})
        response=await self.client.post('/agent',headers=self.headers,json=payload);self.assertEqual(response.status,202)
        self.assertEqual(self.accepted,1)
        state=self.module.active_runs['main-draft'];state['run_id']=None;state['recovered']=True
        response=await self.client.get('/agent/status/main-draft?request_id=main-request',headers=self.headers)
        self.assertEqual(response.status,200);self.assertEqual(self.last_body,original)
        policies=json.loads((self.module.ROOT/'run-policy.json').read_text())
        self.assertEqual(policies['main-draft'],'draft')
        dedicated={**payload,'session_id':'dedicated-draft','request_id':'dedicated-request'}
        response=await self.client.post('/agent',headers=self.headers,json=dedicated);self.assertEqual(response.status,202)
        await self.client.post('/settings/host',headers=self.headers,json={'mode':'main'})
        response=await self.client.post('/agent',headers=self.headers,json=dedicated);self.assertEqual(response.status,202)
        from action_policy import directive
        self.assertEqual(directive(self.module.ROOT,'terminal','dedicated-draft',{'command':'touch fixture'})['action'],'block')
    async def test_legacy_request_keeps_existing_hermes_configuration(self):
        response=await self.client.post('/agent',headers=self.headers,json={'session_id':'legacy-model','input':'fixture','background':True})
        self.assertEqual(response.status,202);self.assertNotIn('provider',self.last_body);self.assertNotIn('model',self.last_body)
    async def test_voice_reply_replays_the_same_image_without_disabling_required_reasoning(self):
        image=b'\xff\xd8\xfffixture-jpeg'
        response=await self.client.post('/frame/voice-frame',headers=self.headers,data=image)
        self.assertEqual(response.status,200)
        payload={'session_id':'voice-model','request_id':'voice-job','input':'read the image','purpose':'reply','background':True,
                 'provider':'nous','model':'z-ai/glm-5.2','frame_session':'voice-frame'}
        self.admission_failures=1
        response=await self.client.post('/agent',headers=self.headers,json=payload);self.assertEqual(response.status,502)
        first=copy.deepcopy(self.last_body)
        self.assertNotIn('model_options',first)
        self.assertEqual(first['input'][0]['role'],'user')
        parts=first['input'][0]['content'];self.assertEqual(parts[0]['type'],'text')
        self.assertEqual(parts[1],{'type':'image_url','image_url':{'url':'data:image/jpeg;base64,'+base64.b64encode(image).decode()}})
        (self.module.ROOT/'frames/voice-frame.jpg').unlink()
        response=await self.client.get('/agent/status/voice-model?request_id=voice-job')
        self.assertEqual(response.status,401)
        response=await self.client.get('/agent/status/voice-model?request_id=voice-job',headers=self.headers)
        self.assertEqual(response.status,200);self.assertEqual(self.last_body,first);self.assertEqual(self.accepted,1)

class Response:
    def __init__(self,status=200,data=None,headers=None):self.status=status;self.data=data or {};self.headers=headers or {}
    async def json(self):return self.data
    async def __aenter__(self):return self
    async def __aexit__(self,*args):pass
class FakeHTTP:
    def __init__(self):self.calls=[]
    def get(self,url,**kwargs):self.calls.append(('get',url,kwargs));return Response(data={'ids':['stable-id']})
    def post(self,url,**kwargs):self.calls.append(('post',url,kwargs));return Response(headers={'Location':'https://upload.example/session'})
    def put(self,url,**kwargs):self.calls.append(('put',url,kwargs));return Response()

class DriveReceiptTests(unittest.IsolatedAsyncioTestCase):
    async def test_resume_without_range_starts_at_zero_and_preserves_first_samples(self):
        with tempfile.TemporaryDirectory() as root:
            data=b'original';path=Path(root)/'record.wav';path.write_bytes(data)
            class ResumeHTTP(FakeHTTP):
                def put(self,url,**kwargs):
                    self.calls.append(('put',url,kwargs))
                    return Response(status=308 if len(self.calls)==1 else 200)
            http=ResumeHTTP();publisher=DrivePublisher(root,http,'folder')
            async def authorization():return {'Authorization':'Bearer fixture'}
            answers=iter([None,{'md5Checksum':hashlib.md5(data).hexdigest(),'size':str(len(data))}])
            async def metadata(_):return next(answers)
            publisher.authorization=authorization;publisher.metadata=metadata
            item={'cloud_file_id':'stable','upload_url':'https://upload.example/resume','mimeType':'audio/wav'}
            self.assertEqual(await publisher.publish(item,path,lambda _:None),'stable')
            self.assertEqual(http.calls[1][2]['data'],data)
            self.assertEqual(http.calls[1][2]['headers']['Content-Range'],'bytes 0-7/8')
    async def test_stable_id_is_persisted_before_upload_and_bad_checksum_never_verifies(self):
        with tempfile.TemporaryDirectory() as root:
            path=Path(root)/'record.wav';path.write_bytes(b'original')
            http=FakeHTTP();publisher=DrivePublisher(root,http,'folder');snapshots=[]
            async def authorization():return {'Authorization':'Bearer test'}
            answers=iter([None,{'id':'stable-id','md5Checksum':'wrong','size':'8'}])
            async def metadata(_):return next(answers)
            publisher.authorization=authorization;publisher.metadata=metadata
            async def folder(_):return "folder"
            publisher.session_folder=folder
            item={'id':'archive','sessionID':'session','filename':'record.wav','mimeType':'audio/wav','sha256':hashlib.sha256(b'original').hexdigest()}
            with self.assertRaises(RuntimeError):await publisher.publish(item,path,lambda x:snapshots.append(dict(x)))
            self.assertEqual(snapshots[0]['cloud_file_id'],'stable-id');self.assertTrue(path.exists())
            self.assertEqual(http.calls[1][2]['json']['id'],'stable-id')
    async def test_session_folder_id_survives_restart_and_is_saved_before_creation(self):
        with tempfile.TemporaryDirectory() as root:
            class FolderHTTP:
                def __init__(self):self.created=0;self.folder=None
                def get(self,url,**kwargs):
                    if url.endswith('generateIds'):return Response(data={'ids':['folder-fixed']})
                    return Response(status=200 if self.folder else 404,data=self.folder)
                def post(self,url,**kwargs):
                    self.created+=1
                    self_folder=kwargs['json'];self.folder=self_folder
                    self_outer.assertEqual(json.loads((Path(root)/'session-folders.json').read_text())['root:session'],'folder-fixed')
                    return Response(data={'id':'folder-fixed'})
            self_outer=self;http=FolderHTTP();item={'sessionID':'session','startedAt':100}
            async def authorization():return {'Authorization':'Bearer fixture'}
            publisher=DrivePublisher(root,http,'root');publisher.authorization=authorization
            self.assertEqual(await publisher.session_folder(item),'folder-fixed')
            restarted=DrivePublisher(root,http,'root');restarted.authorization=authorization
            self.assertEqual(await restarted.session_folder(item),'folder-fixed');self.assertEqual(http.created,1)
    async def test_previously_completed_upload_returns_same_verified_file(self):
        with tempfile.TemporaryDirectory() as root:
            path=Path(root)/'record.wav';path.write_bytes(b'original')
            publisher=DrivePublisher(root,FakeHTTP(),'folder')
            async def metadata(_):return {'id':'stable-id','md5Checksum':hashlib.md5(b'original').hexdigest(),'size':'8'}
            publisher.metadata=metadata
            item={'cloud_file_id':'stable-id'}
            self.assertEqual(await publisher.publish(item,path,lambda _:None),'stable-id')
            self.assertTrue(path.exists())
if __name__=='__main__':unittest.main(verbosity=2)
