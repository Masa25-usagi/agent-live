"""Offline checks. No Discord login, voice join, or channel message is performed."""
import asyncio
import importlib
import json
import sys
import tempfile
import threading
import types
import unittest
import wave
from pathlib import Path
from unittest.mock import patch

package = types.ModuleType('agent_live_fixture')
package.__path__ = [str(Path(__file__).parent)]
sys.modules[package.__name__] = package
journal_module = importlib.import_module(package.__name__ + '.journal')
voice = importlib.import_module(package.__name__ + '.voice')
Journal = journal_module.Journal


class JournalTests(unittest.TestCase):
    def test_rotation_preserves_every_sample_and_restart_identity(self):
        with tempfile.TemporaryDirectory() as root:
            journal = Journal(root); journal.start('discord-test')
            audio = b'\x01\x00' * (16000 * 45)
            journal.audio(audio); journal.text('元の記録を残します'); journal.finish()
            rebuilt = Journal(root)
            self.assertEqual({i['id'] for i in journal.pending()}, {i['id'] for i in rebuilt.pending()})
            audio_items = [item for item in rebuilt.pending() if item['kind'] == 'audio']
            self.assertEqual(len(audio_items), 3)
            total = 0
            for item in audio_items:
                with wave.open(str(Path(root) / item['filename'])) as stream:
                    self.assertEqual(stream.getframerate(), 16000)
                    total += stream.getnframes()
            self.assertEqual(total, 16000 * 45)

    def test_mismatch_keeps_original_and_verified_receipt_evicts(self):
        with tempfile.TemporaryDirectory() as root:
            journal = Journal(root); journal.start('test'); journal.audio(b'\0\0' * 100); journal.finish()
            item = journal.pending()[0]; path = Path(root) / item['filename']
            self.assertFalse(journal.verify(item, {'cloud_verified': True, 'sha256': 'wrong', 'cloud_file_id': 'file'}))
            self.assertTrue(path.exists())
            self.assertTrue(journal.verify(item, {'cloud_verified': True, 'sha256': item['sha256'], 'cloud_file_id': 'file'}))
            self.assertFalse(path.exists()); self.assertEqual(Journal(root).pending(), [])

    def test_unsealed_audio_and_text_recover_after_process_loss(self):
        with tempfile.TemporaryDirectory() as root:
            root = Path(root)
            info = {'id': 'crash', 'sessionID': 'original', 'source': 'discord', 'rate': 16000, 'startedAt': 100}
            journal_module.atomic_json(root / 'crash.recovery.json', info)
            with wave.open(str(root / 'crash.wav.part'), 'wb') as stream:
                stream.setnchannels(1); stream.setsampwidth(2); stream.setframerate(16000); stream.writeframes(b'\0\0' * 80)
            text = {'id': 'text', 'sessionID': 'original', 'source': 'user', 'startedAt': 100}
            journal_module.atomic_json(root / 'text.text-recovery.json', text)
            (root / 'text.jsonl.part').write_text('{"text":"保存前の文字"}\n')
            recovered = Journal(root)
            self.assertEqual(len(recovered.pending()), 2)
            self.assertEqual({i['sessionID'] for i in recovered.pending()}, {'original'})
            self.assertEqual(recovered.used(), sum(i['bytes'] for i in recovered.pending()))

    def test_header_counts_toward_capacity(self):
        with tempfile.TemporaryDirectory() as root:
            journal = Journal(root, maximum=100); journal.start('test')
            with self.assertRaises(RuntimeError): journal.audio(b'\0\0' * 40)
            self.assertEqual(journal.used(), 0)


class VoiceTests(unittest.IsolatedAsyncioTestCase):
    async def test_stt_failure_still_uploads_the_original(self):
        class Response:
            def __init__(self,status,data):self.status=status;self.data=data
            async def __aenter__(self):return self
            async def __aexit__(self,*args):pass
            async def json(self):return self.data
        class HTTP:
            uploads=0
            def post(self,*args,**kwargs):return Response(503,{})
            def get(self,*args,**kwargs):return Response(200,{'exists':False})
            def put(self,*args,**kwargs):self.uploads+=1;return Response(201,{'cloud_verified':False})
        with tempfile.TemporaryDirectory() as root:
            journal=Journal(root);journal.start('fixture');journal.audio(b'\x01\x00'*320);journal.finish()
            http=HTTP();await voice.sync_journal(http,'http://fixture',{},journal)
            self.assertEqual(http.uploads,1);self.assertEqual(len(journal.pending()),1)
            self.assertTrue((Path(root)/journal.pending()[0]['filename']).exists())
    async def test_send_failure_does_not_stop_recording(self):
        class Socket:
            closed = False
            async def send_json(self, _): raise ConnectionError()
            async def close(self): self.closed = True
        class Source:
            def clear(self): pass
        class JournalFixture:
            def __init__(self): self.markers = []
            def text(self, text, source): self.markers.append(text)
        room = voice.LiveRoom.__new__(voice.LiveRoom)
        room.running = True; room.socket = Socket(); room.audio_queue = asyncio.Queue()
        room.source = Source(); room.journal = JournalFixture(); room.link_reported = False
        task = asyncio.create_task(room.send_audio()); room.audio_queue.put_nowait(b'\0\0' * 320)
        await asyncio.sleep(0.01)
        self.assertTrue(room.running); self.assertIsNone(room.socket)
        self.assertEqual(len(room.journal.markers), 1)
        task.cancel()
        with self.assertRaises(asyncio.CancelledError): await task

    async def test_speaker_output_has_fixed_twenty_ms_duration(self):
        source = voice.PCMSource(); source.write(b'\0\0' * 2400)
        self.assertEqual(len(source.read()), 3840)
        source.clear(); self.assertEqual(source.read(), b'\0' * 3840)
        source.cleanup(); self.assertEqual(source.read(), b'')

if __name__ == '__main__': unittest.main(verbosity=2)
