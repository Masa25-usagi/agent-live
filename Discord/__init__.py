import asyncio, json, urllib.request, urllib.parse
from pathlib import Path
from .voice import LiveRoom, configuration, sync_journal
from .journal import Journal

def register(ctx):
    def before_dispatch(event=None,**kwargs):
        if str(getattr(event,'text','')).startswith('!live '):return {'action':'skip','reason':'Agent Live command handled by native Discord listener'}
    ctx.register_hook('pre_gateway_dispatch',before_dispatch)
    def policy(tool_name='',session_id='',args=None,**kwargs):
        root=Path.home()/'.local/share/agent-live'
        try: policies=json.loads((root/'run-policy.json').read_text())
        except Exception:return None  # Ordinary Hermes sessions remain independent of the app.
        if session_id not in policies:return None
        try:
            import sys
            server=str(Path.home()/'.local/share/agent-live-server')
            if server not in sys.path:sys.path.insert(0,server)
            from action_policy import directive
            return directive(root,tool_name,session_id,args or {})
        except Exception:
            return {'action':'block','message':'このアプリの実行範囲を確認できないため、処理を見送ります。'}
    ctx.register_hook('pre_tool_call',policy)
    def history(query='',session_id='',**kwargs):
        c=configuration();url='http://127.0.0.1:8787/' + ('sessions/'+urllib.parse.quote(session_id,safe='') if session_id else 'records?q='+urllib.parse.quote(query))
        try:
            with urllib.request.urlopen(urllib.request.Request(url,headers={'Authorization':'Bearer '+c['AGENT_LIVE_TOKEN']}),timeout=15) as response:return response.read().decode()
        except Exception:return json.dumps({'error':'Records temporarily unavailable'})
    ctx.register_tool(name='agent_live_records',toolset='agent_live',schema={'name':'agent_live_records','description':'本人の音声・画面共有アプリの記録を検索し、会話の文脈を参照する。','parameters':{'type':'object','properties':{'query':{'type':'string'},'session_id':{'type':'string'}}}},handler=history)
    def factory(native,adapter):
        rooms={};command_locks={}
        async def listener(message):
            text=message.content.strip()
            if message.author.bot or not text.startswith('!live ') or not message.guild:return
            if not adapter._is_allowed_user(str(message.author.id),guild=message.guild,is_dm=False):return
            mode=text[6:].strip();guild=message.guild.id
            async def notify(text):await message.reply(text,mention_author=False)
            async with command_locks.setdefault(guild,asyncio.Lock()):
                if mode=='join':
                    if guild in rooms and rooms[guild].running:await notify('ライブ会話と記録はすでに進んでいます。');return
                    if message.guild.voice_client:await notify('先に現在の音声参加を終了してください。Hermesの通常音声は /voice leave、Agent Liveは !live leave です。');return
                    channel=getattr(getattr(message.author,'voice',None),'channel',None)
                    if not channel:await notify('音声チャンネルに参加してから !live join を使ってください。');return
                    room=None
                    try:
                        voice=await channel.connect();room=LiveRoom(voice,adapter,notify);rooms[guild]=room;await room.start()
                        await notify('記録を開始しました。Gemini Liveへ接続しています。終了は !live leave です。')
                    except Exception:
                        if room:await room.close()
                        await notify('接続できませんでした。サーバー設定を確認してください。元の記録は残っています。')
                elif mode=='leave':
                    room=rooms.pop(guild,None)
                    if room:await room.close()
                    await notify('ライブ会話を終了しました。未同期の記録は保存待ちとして残ります。')
                elif mode=='status':
                    room=rooms.get(guild)
                    if room and room.running:
                        await notify('会話と記録を続けています。' if room.socket and not room.socket.closed else '音声AIへの接続を待っています。記録は続いています。')
                    else:await notify('ライブ会話は停止中です。!live joinで開始できます。')
        native.add_listener(listener,'on_message')
        async def pending_sync():
            from aiohttp import ClientSession,ClientTimeout
            c=configuration();headers={'Authorization':'Bearer '+c.get('AGENT_LIVE_TOKEN','')}
            async with ClientSession(timeout=ClientTimeout(total=150)) as http:
                while True:
                    try:
                        # Avoid a second writer while any room owns the journal.
                        if not any(room.running for room in rooms.values()):
                            root=Path.home()/'.local/share/agent-live-discord';root.mkdir(parents=True,exist_ok=True)
                            for directory in root.iterdir():
                                if not directory.is_dir():continue
                                journal=Journal(directory)
                                await sync_journal(http,'http://127.0.0.1:8787',headers,journal)
                                sessions={item['sessionID'] for item in journal.items.values()}
                                for session in sessions:
                                    async with http.post('http://127.0.0.1:8787/sessions/'+session+'/finish',headers=headers,json={'items':[item['id'] for item in journal.items.values() if item['sessionID']==session]}):pass
                    except Exception:pass
                    await asyncio.sleep(15)
        native._agent_live_sync_task=asyncio.create_task(pending_sync())
    ctx.register_platform_handler('discord',factory)
