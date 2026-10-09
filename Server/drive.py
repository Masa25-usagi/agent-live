"""Resumable Drive publishing. Stable preallocated IDs survive ambiguous responses."""
import asyncio
import hashlib
import json
import time
import os
from datetime import datetime, timezone, timedelta
from pathlib import Path

class DrivePublisher:
    def __init__(self, root, http, folder_id):
        self.root, self.http, self.folder_id = Path(root), http, folder_id
        self.token = None
        self.folders_path = self.root / 'session-folders.json'
        self.folders = json.loads(self.folders_path.read_text()) if self.folders_path.exists() else {}

    @property
    def configured(self):
        return bool(self.folder_id and (self.root / 'google-token.json').exists())

    async def authorization(self):
        if not self.configured:
            raise RuntimeError('Drive OAuth and destination folder required')
        if not self.token or self.token.get('expires_at', 0) < time.time() + 60:
            saved = json.loads((self.root / 'google-token.json').read_text())
            async with self.http.post('https://oauth2.googleapis.com/token', data={
                'client_id': saved['client_id'], 'client_secret': saved['client_secret'],
                'refresh_token': saved['refresh_token'], 'grant_type': 'refresh_token'
            }) as response:
                if response.status != 200:
                    raise RuntimeError('Drive authorization requires attention')
                self.token = await response.json()
                self.token['expires_at'] = time.time() + self.token['expires_in']
        return {'Authorization': 'Bearer ' + self.token['access_token']}

    async def metadata(self, file_id):
        async with self.http.get('https://www.googleapis.com/drive/v3/files/' + file_id,
            headers=await self.authorization(), params={'fields': 'id,size,md5Checksum,appProperties,mimeType,parents'}) as response:
            if response.status == 404:
                return None
            if response.status != 200:
                raise RuntimeError('Drive metadata verification failed')
            return await response.json()

    async def download(self, item):
        """Read a verified original for deferred STT without retaining a second spool copy."""
        async with self.http.get('https://www.googleapis.com/drive/v3/files/' + item['cloud_file_id'],
                headers=await self.authorization(), params={'alt':'media'}) as response:
            if response.status != 200: raise RuntimeError('Saved audio download deferred')
            data = bytearray()
            async for block in response.content.iter_chunked(65536):
                data.extend(block)
                if len(data) > min(int(item['bytes']),32 * 1024 ** 2): raise RuntimeError('Saved audio size differs')
        if len(data) != item['bytes'] or hashlib.sha256(data).hexdigest() != item['sha256']:
            raise RuntimeError('Saved audio checksum differs')
        return bytes(data)

    async def session_folder(self, item):
        session = item['sessionID']; key = self.folder_id + ':' + session
        folder_id = self.folders.get(key)
        if not folder_id:
            async with self.http.get('https://www.googleapis.com/drive/v3/files/generateIds', headers=await self.authorization(), params={'count':'1','space':'drive','type':'files'}) as response:
                if response.status != 200: raise RuntimeError('Drive folder ID allocation failed')
                folder_id = (await response.json())['ids'][0]
            self.folders[key] = folder_id
            temporary = self.folders_path.with_suffix('.tmp')
            with temporary.open('w') as stream:
                json.dump(self.folders,stream);stream.flush();os.fsync(stream.fileno())
            temporary.replace(self.folders_path)
        existing = await self.metadata(folder_id)
        if existing:
            if existing.get('mimeType') != 'application/vnd.google-apps.folder' or existing.get('appProperties',{}).get('sessionID') != session:
                raise RuntimeError('Drive session folder differs')
            return folder_id
        stamp = datetime.fromtimestamp(float(item.get('startedAt',time.time()-978307200))+978307200,timezone(timedelta(hours=9)))
        metadata = {'id':folder_id,'name':stamp.strftime('%Y-%m-%d_%H%M')+'_'+session[-12:],
                    'mimeType':'application/vnd.google-apps.folder','parents':[self.folder_id], 'appProperties':{'sessionID':session}}
        async with self.http.post('https://www.googleapis.com/drive/v3/files',headers=await self.authorization(),params={'fields':'id'},json=metadata) as response:
            if response.status not in (200,201): raise RuntimeError('Drive session folder creation deferred')
            if (await response.json()).get('id') != folder_id: raise RuntimeError('Drive session folder identifier differs')
        return folder_id

    @staticmethod
    def display_name(item):
        stamp = datetime.fromtimestamp(float(item.get('startedAt',time.time()-978307200))+978307200,timezone(timedelta(hours=9)))
        extension = Path(item['filename']).suffix
        source = item.get('source',item.get('kind','record')).replace('/','-')[:40]
        return stamp.strftime('%H%M%S')+'_'+source+'_'+item['id'][:8]+extension

    async def publish(self, item, path, persist):
        path = Path(path)
        size = path.stat().st_size
        def digest():
            result = hashlib.md5()
            with path.open('rb') as stream:
                for block in iter(lambda: stream.read(1024 * 1024), b''):
                    result.update(block)
            return result.hexdigest()
        md5 = await asyncio.to_thread(digest)
        file_id = item.get('cloud_file_id')
        if not file_id:
            async with self.http.get('https://www.googleapis.com/drive/v3/files/generateIds',
                headers=await self.authorization(), params={'count': '1', 'space': 'drive', 'type': 'files'}) as response:
                if response.status != 200:
                    raise RuntimeError('Drive ID allocation failed')
                file_id = (await response.json())['ids'][0]
            item['cloud_file_id'] = file_id
            persist(item)
        existing = await self.metadata(file_id)
        if existing:
            if existing.get('md5Checksum') != md5 or int(existing.get('size', -1)) != size:
                raise RuntimeError('Drive copy differs; keeping original')
            return file_id
        upload_url = item.get('upload_url')
        offset = 0
        if upload_url:
            async with self.http.put(upload_url, headers={**await self.authorization(), 'Content-Range': f'bytes */{size}', 'Content-Length': '0'}, data=b'') as response:
                if response.status in (200, 201):
                    offset = size
                elif response.status == 308:
                    acknowledged = response.headers.get('Range')
                    offset = int(acknowledged.split('-')[-1]) + 1 if acknowledged else 0
                else:
                    upload_url = None
        if not upload_url:
            folder = await self.session_folder(item)
            metadata = {'id': file_id, 'name': self.display_name(item), 'parents': [folder],
                'appProperties': {'agentLiveID': item['id'], 'sessionID': item['sessionID'], 'sha256': item['sha256']}}
            async with self.http.post('https://www.googleapis.com/upload/drive/v3/files',
                params={'uploadType': 'resumable', 'fields': 'id'},
                headers={**await self.authorization(), 'X-Upload-Content-Type': item['mimeType'], 'X-Upload-Content-Length': str(size)}, json=metadata) as response:
                if response.status != 200:
                    raise RuntimeError('Drive upload initialization failed')
                upload_url = response.headers['Location']
            item['upload_url'] = upload_url
            persist(item)
        with path.open('rb') as stream:
            stream.seek(offset)
            while offset < size:
                block = stream.read(4 * 1024 * 1024)
                async with self.http.put(upload_url, headers={**await self.authorization(),
                    'Content-Type': item['mimeType'], 'Content-Range': f'bytes {offset}-{offset + len(block) - 1}/{size}'}, data=block) as response:
                    if response.status not in (200, 201, 308):
                        if response.status in (400, 404, 410):
                            item.pop('upload_url', None); persist(item)
                        raise RuntimeError('Drive upload paused; original retained')
                offset += len(block)
        verified = await self.metadata(file_id)
        if not verified or verified.get('md5Checksum') != md5 or int(verified.get('size', -1)) != size:
            raise RuntimeError('Drive checksum verification failed; original retained')
        return file_id
