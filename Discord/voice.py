import asyncio, audioop, base64, contextlib, json, os, queue, sys, time, uuid
from pathlib import Path
from aiohttp import ClientSession, ClientTimeout
from .journal import Journal

def configuration():
    values={}
    path=Path.home()/'.config/agent-live/server.env'
    if path.exists():
        for line in path.read_text().splitlines():
            if '=' in line:k,v=line.split('=',1);values[k]=v
    return values

class PCMSource:
    def __init__(self): self.buffer=bytearray();self.lock=__import__('threading').Lock();self.closed=False;self.state=None
    def write(self,pcm):
        output,self.state=audioop.ratecv(pcm,2,1,24000,48000,self.state)
        output=audioop.tostereo(output,2,1,1)
        with self.lock:
            if len(self.buffer)+len(output)>180*192000:raise RuntimeError('Playback backlog full')
            self.buffer.extend(output)
    def clear(self):
        with self.lock:self.buffer.clear()
    def read(self):
        with self.lock:
            if self.closed:return b''
            block=bytes(self.buffer[:3840]);del self.buffer[:3840]
        return block.ljust(3840,b'\0')
    def is_opus(self):return False
    def cleanup(self):self.closed=True

class LiveRoom:
    def __init__(self,voice_client,adapter,notify):
        import discord
        class Source(discord.AudioSource,PCMSource):
            def __init__(self):PCMSource.__init__(self)
            read=PCMSource.read;is_opus=PCMSource.is_opus;cleanup=PCMSource.cleanup
        self.source=Source();self.vc=voice_client;self.adapter=adapter;self.notify=notify
        self.session='discord-'+str(voice_client.guild.id)+'-'+uuid.uuid4().hex[:12]
        self.journal=Journal(Path.home()/'.local/share/agent-live-discord'/self.session);self.journal.start(self.session)
        self.receiver=None;self.http=None;self.socket=None;self.tasks=[];self.running=False;self.closed=False;self.user_text='';self.output_text='';self.resampler={};self.sent_calls=set();self.audio_queue=asyncio.Queue(maxsize=100);self.link_lock=asyncio.Lock();self.link_reported=False
        c=configuration();self.token=c.get('AGENT_LIVE_TOKEN','');self.base='http://127.0.0.1:8787';self.headers={'Authorization':'Bearer '+self.token}
    async def start(self):
        # Reuse the installed Hermes receiver, including its native DAVE decryption.
        module=next((m for name,m in sys.modules.items() if name.endswith('discord.adapter') and hasattr(m,'VoiceReceiver')),None)
        if module is None:
            from plugins.platforms.discord import adapter as module
        self.receiver=module.VoiceReceiver(self.vc);self.receiver.start()
        self.http=ClientSession(timeout=ClientTimeout(total=200))
        self.vc.play(self.source);self.running=True
        self.tasks=[asyncio.create_task(self.capture()),asyncio.create_task(self.receive()),asyncio.create_task(self.send_audio()),asyncio.create_task(self.synchronize())]
    async def connect_live(self):
        async with self.link_lock:
            if self.socket and not self.socket.closed:return self.socket
            socket=await self.http.ws_connect(self.base+'/live/gemini?session='+self.session,headers=self.headers)
            try:
                await self.setup_live(socket)
                if not self.running:await socket.close();return None
                self.socket=socket
                while not self.audio_queue.empty():self.audio_queue.get_nowait()
                if self.link_reported:
                    self.journal.text('音声AIへの接続が回復しました。','connection');self.link_reported=False
                return socket
            except BaseException:
                await socket.close();raise
    async def setup_live(self,socket):
        async with self.http.get(self.base+'/context',headers=self.headers) as response:context=(await response.json()).get('context','')
        declaration={'name':'delegate_agent','description':'本人のHermesに記憶・調査・計画を依頼する。実行は通常のHermes会話で本人が指示する。','parameters':{'type':'object','properties':{'task':{'type':'string'},'purpose':{'type':'string','enum':['think','research','work']}},'required':['task','purpose']}}
        await socket.send_json({'setup':{'model':'models/gemini-3.8-live','generationConfig':{'responseModalities':['AUDIO']},'systemInstruction':{'parts':[{'text':'日本語で短く自然に話してください。聞き手のエージェントはHermesです。調査・計画・記憶の参照はdelegate_agentを使ってください。\n'+context}]},'inputAudioTranscription':{},'outputAudioTranscription':{},'tools':[{'functionDeclarations':[declaration]}],'contextWindowCompression':{'slidingWindow':{}}}})
        setup=await asyncio.wait_for(socket.receive_json(),20)
        if 'setupComplete' not in setup:raise RuntimeError('Live setup rejected')
    async def lost_link(self,socket=None):
        if socket and self.socket is socket:self.socket=None
        if socket:await socket.close()
        self.source.clear()
        if not self.link_reported:
            self.journal.text('音声AIへの接続待ち。音声の記録は続けています。','connection');self.link_reported=True
    async def capture(self):
        import array
        try:
            while self.running:
                began=time.monotonic();blocks=[]
                with self.receiver._lock:
                    for ssrc,buf in list(self.receiver._buffers.items()):
                        user=self.receiver._ssrc_to_user.get(ssrc,0)
                        if not user or not self.adapter._is_allowed_user(str(user),guild=self.vc.guild,is_dm=False):continue
                        block=bytes(buf[:3840]);del buf[:3840]
                        if len(buf)>192000:del buf[:-192000]
                        mono=audioop.tomono(block.ljust(3840,b'\0'),2,0.5,0.5)
                        pcm,state=audioop.ratecv(mono,2,1,48000,16000,self.resampler.get(ssrc));self.resampler[ssrc]=state
                        blocks.append(array.array('h',pcm))
                samples=array.array('h',(max(-32768,min(32767,sum(b[i] if i<len(b) else 0 for b in blocks))) for i in range(320)))
                pcm=samples.tobytes();self.journal.audio(pcm)
                if self.audio_queue.full():self.audio_queue.get_nowait()
                self.audio_queue.put_nowait(pcm)
                await asyncio.sleep(max(0,0.02-(time.monotonic()-began)))
        except Exception:
            await self.close()
            await self.notify('音声の接続が切れました。記録は保存待ちとして残っています。!live joinで再接続できます。')
    async def send_audio(self):
        while self.running:
            pcm=await self.audio_queue.get();socket=self.socket
            if not socket or socket.closed:continue
            try:await socket.send_json({'realtimeInput':{'audio':{'mimeType':'audio/pcm;rate=16000','data':base64.b64encode(pcm).decode()}}})
            except Exception:await self.lost_link(socket)
    async def receive(self):
        while self.running:
            socket=None
            try:
                socket=await self.connect_live()
                if not socket:break
                async for message in socket:
                    await self.receive_event(json.loads(message.data),socket)
            except Exception:pass
            if self.running:
                await self.lost_link(socket);await asyncio.sleep(5)
    async def receive_event(self,event,socket):
        if event.get('error') or event.get('goAway'):raise RuntimeError('Live ended')
        content=event.get('serverContent',{})
        if content.get('interrupted'):self.source.clear();self.output_text=''
        self.user_text+=content.get('inputTranscription',{}).get('text','')
        self.output_text+=content.get('outputTranscription',{}).get('text','')
        for part in content.get('modelTurn',{}).get('parts',[]):
            inline=part.get('inlineData',{})
            if inline.get('mimeType','').startswith('audio/pcm'):
                pcm=base64.b64decode(inline['data']);self.journal.audio(pcm,'assistant',24000);self.source.write(pcm)
        if content.get('inputTranscription',{}).get('finished'):
            self.journal.text(self.user_text);self.user_text=''
        if content.get('turnComplete'):
            self.journal.text(self.user_text);self.user_text='';self.journal.text(self.output_text,'assistant');self.output_text=''
        for call in event.get('toolCall',{}).get('functionCalls',[]):
            if call['id'] in self.sent_calls:continue
            self.sent_calls.add(call['id']);task=asyncio.create_task(self.delegate(call,socket));self.tasks.append(task)
            task.add_done_callback(lambda done:self.tasks.remove(done) if done in self.tasks else None)
    async def delegate(self,call,socket):
        args=call.get('args',{});purpose=args.get('purpose','think')
        if purpose=='work':result={'status':'confirmation_required','message':'作業開始はHermesの通常の会話で本人から明示してください。'}
        else:
            async with self.http.post(self.base+'/agent',headers=self.headers,json={'input':args.get('task',''),'session_id':self.session,'purpose':purpose}) as response:
                if response.status==200:result=await response.json();self.journal.text(result.get('text',''),'hermes')
                else:result={'status':'temporarily_unavailable'}
        if self.running and self.socket is socket:
            with contextlib.suppress(Exception):await socket.send_json({'toolResponse':{'functionResponses':[{'id':call['id'],'response':{'output':result}}]}})
    async def synchronize(self):
        while self.running:
            try:await sync_journal(self.http,self.base,self.headers,self.journal)
            except Exception:pass
            await asyncio.sleep(5)
    async def close(self):
        if self.closed:return
        self.closed=True
        self.running=False
        current=asyncio.current_task()
        for task in self.tasks:
            if task is not current:task.cancel()
        self.receiver.stop() if self.receiver else None
        self.source.cleanup();self.vc.stop()
        self.journal.text(self.user_text);self.journal.text(self.output_text,'assistant');self.journal.finish()
        if self.http:
            with contextlib.suppress(Exception):
                async with self.http.post(self.base+'/agent/stop',headers=self.headers,json={'session_id':self.session}):pass
        if self.socket:await self.socket.close()
        if self.vc.is_connected():await self.vc.disconnect()
        if self.http:await self.http.close();self.http=None

async def sync_journal(http,base,headers,journal):
    for item in journal.pending():
        if item['kind']=='audio' and item['source']!='assistant' and not item.get('transcribed'):
            try:
                with (journal.root/item['filename']).open('rb') as data:
                    async with http.post(base+'/transcribe',headers=headers,data=data,timeout=ClientTimeout(total=30)) as response:
                        if response.status!=200:raise RuntimeError('Transcription deferred')
                        text=(await response.json()).get('text','')
                journal.text(text,'verified:'+item['source'],session_id=item['sessionID']);item['transcribed']=True;journal._save(item)
            except Exception:pass  # The bridge retries STT after the original has been saved.
        async with http.get(base+'/archive/'+item['id'],headers=headers) as response:receipt=await response.json()
        if not receipt.get('exists'):
            metadata=base64.b64encode(json.dumps(item).encode()).decode()
            with (journal.root/item['filename']).open('rb') as data:
                async with http.put(base+'/archive/'+item['id'],headers={**headers,'X-Archive-Metadata':metadata,'Content-Type':item['mimeType']},data=data) as response:
                    if response.status not in (200,201):raise RuntimeError('Upload deferred')
                    receipt=await response.json()
        journal.verify(item,receipt)
