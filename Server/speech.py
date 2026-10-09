"""Japanese archival STT, independent of Live and cloud publishing."""
import array
import asyncio
import hashlib
import io
import math
import os
import sys
import time
import wave
from aiohttp import ClientTimeout, FormData


def digital_silence(data):
    """Only skip near-zero PCM. Quiet speech is left to the recognizer."""
    try:
        with wave.open(io.BytesIO(data), 'rb') as stream:
            if stream.getsampwidth() != 2 or stream.getcomptype() != 'NONE':
                return False
            samples = array.array('h', stream.readframes(stream.getnframes()))
        if sys.byteorder != 'little': samples.byteswap()
        if not samples: return True
        if max(abs(value) for value in samples) >= 64: return False
        return math.sqrt(sum(value * value for value in samples) / len(samples)) < 16
    except (ValueError, EOFError, wave.Error):
        return False


def trim_silent_edges(data):
    """Trim near-zero edges for STT only, retaining 300ms around non-silent PCM."""
    try:
        with wave.open(io.BytesIO(data), 'rb') as stream:
            if stream.getsampwidth() != 2 or stream.getnchannels() != 1 or stream.getcomptype() != 'NONE': return data
            rate = stream.getframerate(); pcm = stream.readframes(stream.getnframes())
        step = max(2, int(rate * .02) * 2); first = None; last = 0
        for offset in range(0, len(pcm), step):
            samples = array.array('h', pcm[offset:offset + step])
            if sys.byteorder != 'little': samples.byteswap()
            if samples and (max(abs(s) for s in samples) >= 64 or sum(s*s for s in samples) >= len(samples)*16*16):
                if first is None: first = offset
                last = offset + len(samples) * 2
        if first is None: return data  # Full-silence handling remains deliberately conservative.
        margin = int(rate * .3) * 2
        begin = max(0, first - margin); end = min(len(pcm), last + margin)
        if begin + len(pcm) - end < rate: return data  # Less than 0.5s offers little benefit.
        output = io.BytesIO()
        with wave.open(output, 'wb') as stream:
            stream.setnchannels(1); stream.setsampwidth(2); stream.setframerate(rate)
            stream.writeframes(pcm[begin:end])
        return output.getvalue()
    except (ValueError, EOFError, wave.Error):
        return data


class JapaneseTranscriber:
    def __init__(self, http, database, economy=lambda: True, clock=time.monotonic):
        self.http, self.db = http, database
        self.economy = economy; self.clock = clock; self.retry_at = 0; self.failures = 0
        self.lock = asyncio.Lock()
        self.db.execute('CREATE TABLE IF NOT EXISTS transcriptions (sha256 TEXT PRIMARY KEY, text TEXT NOT NULL)')
        self.db.commit()

    async def transcribe(self, data):
        async with self.lock:
            return await self._transcribe(data)

    async def _transcribe(self, data):
        digest = hashlib.sha256(data).hexdigest()
        cached = self.db.execute('SELECT text FROM transcriptions WHERE sha256=?', (digest,)).fetchone()
        if cached: return cached[0]
        if digital_silence(data):
            text = ''
        else:
            if self.clock() < self.retry_at:
                raise RuntimeError('Transcription is waiting for provider recovery')
            key = os.environ.get('GROQ_API_KEY')
            if not key: raise RuntimeError('STT is not configured')
            form = FormData()
            form.add_field('file', trim_silent_edges(data) if self.economy() else data, filename='speech.wav', content_type='audio/wav')
            form.add_field('model', 'whisper-large-v3-turbo')
            form.add_field('language', 'ja'); form.add_field('temperature', '0')
            retry_after = 0
            try:
                async with self.http.post('https://api.groq.com/openai/v1/audio/transcriptions',
                        headers={'Authorization': 'Bearer ' + key}, data=form,
                        timeout=ClientTimeout(total=25)) as response:
                    if response.status != 200:
                        try: retry_after = min(3600, max(0, float(getattr(response, 'headers', {}).get('Retry-After', '0'))))
                        except ValueError: pass
                        raise RuntimeError('Transcription temporarily unavailable')
                    text = str((await response.json()).get('text', '')).strip()
                self.failures = 0; self.retry_at = 0
            except Exception:
                self.failures += 1
                self.retry_at = self.clock() + max(retry_after, min(900, 60 * 2 ** min(self.failures - 1, 4)))
                raise
        self.db.execute('INSERT OR IGNORE INTO transcriptions VALUES(?,?)', (digest, text)); self.db.commit()
        return text
