import asyncio
import base64
import io
import json
import os
from pathlib import Path
import sqlite3
import tempfile
import unittest
import wave
from unittest.mock import patch
from economy import EconomySettings, LiveEconomy, SilenceGate, ProviderBackoff
from speech import JapaneseTranscriber, trim_silent_edges


def pcm(value, seconds):
    return int(value).to_bytes(2, 'little', signed=True) * int(16000 * seconds)


def wav(data):
    output = io.BytesIO()
    with wave.open(output, 'wb') as stream:
        stream.setnchannels(1); stream.setsampwidth(2); stream.setframerate(16000)
        stream.writeframes(data)
    return output.getvalue()


def audio(data):
    return json.dumps({'realtimeInput': {'audio': {'mimeType': 'audio/pcm;rate=16000', 'data': base64.b64encode(data).decode()}}})


class EconomyTests(unittest.TestCase):
    def test_quota_backoff_is_shared_and_increases_until_success_or_a_new_key(self):
        now = [0]; backoff = ProviderBackoff(clock=lambda: now[0])
        backoff.fail('gemini'); self.assertEqual(backoff.remaining('gemini'),60)
        self.assertEqual(backoff.remaining('grok'),0)
        now[0] = 60; self.assertEqual(backoff.remaining('gemini'),0)
        backoff.fail('gemini'); self.assertEqual(backoff.remaining('gemini'),120)
        backoff.clear('gemini'); self.assertEqual(backoff.remaining('gemini'),0)
        backoff.fail('gemini',600); self.assertEqual(backoff.remaining('gemini'),600)
    def test_idle_silence_stays_local_and_lead_tail_and_second_utterance_are_preserved(self):
        gate = SilenceGate()
        self.assertEqual(gate.feed(pcm(0, 60)), [])
        first = gate.feed(pcm(1000, .5))
        self.assertEqual(b''.join(first), pcm(0, .3) + pcm(1000, .5))
        quiet = gate.feed(pcm(0, 4))
        self.assertEqual(quiet, [pcm(0, 1.2), None])
        # The second utterance includes its quiet onset. Negative PCM also stays intact.
        self.assertEqual(gate.feed(pcm(-30, .1)), [pcm(0, .3) + pcm(-30, .1)])

    def test_speech_after_pause_in_one_large_callback_keeps_stream_end_order(self):
        gate = SilenceGate()
        out = gate.feed(pcm(800, .1) + pcm(0, 1.6) + pcm(700, .1))
        self.assertEqual(out, [pcm(800, .1) + pcm(0, 1.2), None, pcm(0, .3) + pcm(700, .1)])

    def test_setup_preserves_model_memory_tools_and_resume_credentials(self):
        policy = LiveEconomy()
        original = {'setup': {'model': 'models/gemini-3.8-live', 'systemInstruction': {'parts': [{'text': 'fixture persona'}]},
                    'tools': [{'fixture': True}], 'sessionResumption': {'handle': 'fixture-handle'}, 'contextWindowCompression': {'slidingWindow': {}}}}
        result = json.loads(policy.filter_gemini(json.dumps(original))[0])['setup']
        for field in ('model', 'tools', 'sessionResumption'): self.assertEqual(result[field], original['setup'][field])
        self.assertEqual(result['systemInstruction']['parts'][0]['text'], 'fixture persona')
        self.assertEqual(result['contextWindowCompression'], {'triggerTokens': 24000, 'slidingWindow': {'targetTokens': 12000}})
        self.assertEqual(result['realtimeInputConfig']['turnCoverage'], 'TURN_INCLUDES_AUDIO_ACTIVITY_AND_ALL_VIDEO')

    def test_manual_vad_and_disabled_mode_pass_through_original_audio(self):
        policy = LiveEconomy(); policy.filter_gemini(json.dumps({'setup': {'realtimeInputConfig': {'automaticActivityDetection': {'disabled': True}}}}))
        data = audio(pcm(0, 2))
        self.assertEqual(policy.filter_gemini(data), [data])
        self.assertEqual(LiveEconomy(False).filter_gemini(data), [data])
        self.assertEqual(policy.filter_gemini('unsupported'), ['unsupported'])

    def test_no_repeated_stream_end_and_text_tools_are_not_blocked(self):
        policy = LiveEconomy()
        policy.filter_gemini(audio(pcm(1000, .2)))
        result = policy.filter_gemini(audio(pcm(0, 30)))
        self.assertEqual(sum(json.loads(v)['realtimeInput'].get('audioStreamEnd', False) for v in result), 1)
        self.assertEqual(policy.filter_gemini(audio(pcm(0, 30))), [])
        for value in ({'realtimeInput': {'text': 'fixture'}}, {'toolResponse': {'functionResponses': []}}):
            self.assertEqual(json.loads(policy.filter_gemini(json.dumps(value))[0]), value)
        self.assertLess(policy.sent_audio_bytes, policy.received_audio_bytes / 20)

    def test_visual_sampling_and_static_refresh_do_not_affect_audio(self):
        now = [0]; policy = LiveEconomy(clock=lambda: now[0])
        self.assertTrue(policy.frame_allowed(b'frame-a'))
        now[0] = 1; self.assertFalse(policy.frame_allowed(b'frame-b'))
        now[0] = 2; self.assertTrue(policy.frame_allowed(b'frame-b'))
        now[0] = 10; self.assertFalse(policy.frame_allowed(b'frame-b'))
        now[0] = 32; self.assertTrue(policy.frame_allowed(b'frame-b'))
        self.assertTrue(LiveEconomy(False).frame_allowed(b'frame-b'))

    def test_settings_survive_restart_without_becoming_a_recording_limit(self):
        with tempfile.TemporaryDirectory() as directory:
            settings = EconomySettings(Path(directory)); self.assertTrue(settings.enabled)
            settings.save(False); self.assertFalse(EconomySettings(Path(directory)).enabled)
            self.assertEqual(settings.path.stat().st_mode & 0o777, 0o600)
            self.assertFalse(settings.public()['is_spending_limit'])
            with self.assertRaises(ValueError): settings.save(1)

    def test_stt_trims_only_silent_edges_and_preserves_quiet_speech_and_original(self):
        original = wav(pcm(0, 8) + pcm(30, 2) + pcm(0, 10))
        trimmed = trim_silent_edges(original)
        with wave.open(io.BytesIO(trimmed)) as stream:
            self.assertAlmostEqual(stream.getnframes() / stream.getframerate(), 2.6)
            self.assertEqual(stream.readframes(stream.getnframes()), pcm(0, .3) + pcm(30, 2) + pcm(0, .3))
        self.assertEqual(len(original), len(wav(pcm(0, 8) + pcm(30, 2) + pcm(0, 10))))
        self.assertEqual(trim_silent_edges(b'unsupported'), b'unsupported')


class RetryTests(unittest.IsolatedAsyncioTestCase):
    async def test_shared_rate_limit_waits_keeps_cached_text_and_does_not_lose_failed_audio(self):
        now = [0]
        class Response:
            status = 429; headers = {'Retry-After': '120'}
            async def __aenter__(self): return self
            async def __aexit__(self, *args): pass
            async def json(self): return {'text': 'fixture transcript'}
        class HTTP:
            calls = 0; response = Response()
            def post(self, *args, **kwargs): self.calls += 1; return self.response
        http = HTTP(); database = sqlite3.connect(':memory:')
        recognizer = JapaneseTranscriber(http, database, clock=lambda: now[0])
        sample = wav(pcm(1000, .2))
        with patch.dict(os.environ, {'GROQ_API_KEY': 'fixture-only'}):
            with self.assertRaises(RuntimeError): await recognizer.transcribe(sample)
            self.assertEqual(await recognizer.transcribe(wav(pcm(0, .1))), '')
            for _ in range(3):
                with self.assertRaises(RuntimeError): await recognizer.transcribe(sample)
            self.assertEqual(http.calls, 1)
            now[0] = 120; http.response.status = 200
            self.assertEqual(await recognizer.transcribe(sample), 'fixture transcript')
            self.assertEqual(await recognizer.transcribe(sample), 'fixture transcript')
            self.assertEqual(http.calls, 2)
        database.close()


if __name__ == '__main__': unittest.main()
