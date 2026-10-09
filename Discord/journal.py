"""Durable segmented recordings for the existing Discord bot."""
import hashlib
import json
import os
import shutil
import time
import uuid
import wave
from pathlib import Path
from datetime import datetime, timezone


def atomic_json(path, value):
    temporary = path.with_suffix('.tmp')
    with temporary.open('w') as stream:
        json.dump(value, stream, ensure_ascii=False)
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)


class Journal:
    """One process owns a journal; only matching cloud receipts release originals."""
    def __init__(self, root, maximum=512 * 1024**2):
        self.root = Path(root)
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.maximum = maximum
        self.writers = {}
        self.session = None
        self.items = {item['id']: item for item in
                      (json.loads(p.read_text()) for p in self.root.glob('*.item.json'))}
        self._recover()
        self._used = self._count_bytes()
        for item in list(self.items.values()):
            if item.get('cloudVerified'):
                self._evict(item)
        self._last_disk_check = 0

    def _count_bytes(self):
        return sum(p.stat().st_size for p in self.root.iterdir()
                   if p.suffix in ('.wav', '.jsonl', '.part'))

    def _recover(self):
        for metadata in self.root.glob('*.recovery.json'):
            info = json.loads(metadata.read_text())
            part = self.root / (info['id'] + '.wav.part')
            path = self.root / (info['id'] + '.wav')
            if part.exists():
                raw = part.read_bytes()[44:]
                raw = raw[:len(raw) // 2 * 2]
                with wave.open(str(path), 'wb') as stream:
                    stream.setnchannels(1)
                    stream.setsampwidth(2)
                    stream.setframerate(info['rate'])
                    stream.writeframes(raw)
                part.unlink()
            if path.exists():
                self._register(info, path, 'audio', 'audio/wav',
                               max(0, path.stat().st_size - 44) / (info['rate'] * 2))
                metadata.unlink()
        for metadata in self.root.glob('*.text-recovery.json'):
            info = json.loads(metadata.read_text())
            part = self.root / (info['id'] + '.jsonl.part')
            path = self.root / (info['id'] + '.jsonl')
            if part.exists():
                part.replace(path)
            if path.exists():
                self._register(info, path, 'transcript', 'application/x-ndjson', 0)
                metadata.unlink()

    def start(self, session):
        self.finish()
        self.session = session

    def used(self):
        return self._used

    def _capacity(self, adding):
        if self.used() + adding > self.maximum:
            raise RuntimeError('Pending storage full')
        if time.monotonic() - self._last_disk_check > 2:
            self._last_disk_check = time.monotonic()
            if shutil.disk_usage(self.root).free < adding + 64 * 1024**2:
                raise RuntimeError('Disk reserve reached')

    def audio(self, data, source='discord', rate=16000):
        if not self.session or not data:
            return
        if len(data) % 2 or rate <= 0:
            raise ValueError('Expected mono PCM16')
        key = (source, rate)
        capacity = rate * 40
        available = capacity - self.writers[key]['count'] if key in self.writers else 0
        headers = max(0, len(data) - available + capacity - 1) // capacity * 44
        self._capacity(len(data) + headers)
        while data:
            if key not in self.writers:
                info = {'id': uuid.uuid4().hex, 'sessionID': self.session, 'source': source,
                        'rate': rate, 'startedAt': time.time() - 978307200}
                atomic_json(self.root / (info['id'] + '.recovery.json'), info)
                path = self.root / (info['id'] + '.wav.part')
                handle = path.open('wb')
                stream = wave.open(handle, 'wb')
                stream.setnchannels(1)
                stream.setsampwidth(2)
                stream.setframerate(rate)
                stream.writeframesraw(b'')
                self.writers[key] = {'info': info, 'stream': stream, 'handle': handle,
                                     'path': path, 'count': 0, 'synced': 0, 'closed': False}
                self._used += 44
            writer = self.writers[key]
            length = min(len(data), capacity - writer['count'])
            writer['stream'].writeframesraw(data[:length])
            writer['count'] += length
            self._used += length
            data = data[length:]
            if time.monotonic() - writer['synced'] > 1:
                writer['handle'].flush()
                os.fsync(writer['handle'].fileno())
                writer['synced'] = time.monotonic()
            if writer['count'] >= capacity:
                self._seal(key)

    def text(self, text, source='user', final=True, event_id=None, session_id=None):
        session = session_id or self.session
        if not text or not session:
            return
        data = (json.dumps({'id': event_id or uuid.uuid4().hex, 'source': source,
                            'text': text, 'isFinal': final,
                            'timestamp': datetime.now(timezone.utc).isoformat()},
                           ensure_ascii=False) + '\n').encode()
        self._capacity(len(data))
        info = {'id': uuid.uuid4().hex, 'sessionID': session, 'source': source,
                'startedAt': time.time() - 978307200}
        recovery = self.root / (info['id'] + '.text-recovery.json')
        atomic_json(recovery, info)
        part = self.root / (info['id'] + '.jsonl.part')
        with part.open('wb') as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        self._used += len(data)
        path = self.root / (info['id'] + '.jsonl')
        part.replace(path)
        self._register(info, path, 'transcript', 'application/x-ndjson', 0)
        recovery.unlink()

    def _seal(self, key):
        writer = self.writers[key]
        if not writer['closed']:
            writer['stream'].close()
            writer['handle'].flush()
            os.fsync(writer['handle'].fileno())
            writer['handle'].close()
            writer['closed'] = True
        info = writer['info']
        path = self.root / (info['id'] + '.wav')
        if writer['path'].exists():
            writer['path'].replace(path)
        self._register(info, path, 'audio', 'audio/wav', writer['count'] / (info['rate'] * 2))
        (self.root / (info['id'] + '.recovery.json')).unlink(missing_ok=True)
        self.writers.pop(key)

    def _register(self, info, path, kind, mime, duration):
        item = {**info, 'kind': kind, 'mimeType': mime, 'duration': duration,
                'filename': path.name, 'bytes': path.stat().st_size,
                'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
        self.items[item['id']] = item
        self._save(item)

    def _save(self, item):
        atomic_json(self.root / (item['id'] + '.item.json'), item)

    def finish(self):
        for key in list(self.writers):
            self._seal(key)
        self.session = None

    def pending(self):
        return [item for item in self.items.values() if not item.get('cloudVerified')]

    def _evict(self, item):
        path = self.root / item['filename']
        if path.exists():
            self._used -= path.stat().st_size
            path.unlink()
        item['localRemoved'] = True
        self._save(item)

    def verify(self, item, receipt):
        if (receipt.get('cloud_verified') and receipt.get('sha256') == item['sha256']
                and receipt.get('cloud_file_id')):
            item['cloudVerified'] = True
            item['cloudFileID'] = receipt['cloud_file_id']
            self._save(item)
            self._evict(item)
            return True
        return False
