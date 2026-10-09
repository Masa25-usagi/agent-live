"""Reduce provider input without touching the independently archived originals."""
import array
import base64
import hashlib
import json
import os
import sys
import time


class EconomySettings:
    def __init__(self, root):
        self.path = root / 'economy-settings.json'
        self.enabled = os.environ.get('AGENT_LIVE_ECONOMY', 'true').lower() != 'false'
        if self.path.exists():
            saved = json.loads(self.path.read_text())
            if type(saved.get('enabled')) is not bool:
                raise RuntimeError('Invalid economy settings')
            self.enabled = saved['enabled']

    def public(self):
        return {'enabled': self.enabled, 'monthly_target_yen': 1000,
                'is_spending_limit': False, 'scope': 'all_devices'}

    def save(self, enabled):
        if type(enabled) is not bool:
            raise ValueError('enabled must be a boolean')
        temp = self.path.with_suffix('.tmp')
        with temp.open('w') as stream:
            os.chmod(temp, 0o600)
            json.dump({'enabled': enabled}, stream)
            stream.flush(); os.fsync(stream.fileno())
        temp.replace(self.path)
        self.enabled = enabled


class SilenceGate:
    """Conservative PCM16 gate: 300ms lead-in and 1.2s trailing silence.

    This is an energy gate, not a speech classifier. Noise and quiet speech above
    the small threshold still reach the provider's normal automatic VAD.
    None denotes audioStreamEnd, in order between any emitted audio blocks.
    """
    frame_bytes = 640  # 20ms at 16kHz mono PCM16
    lead_bytes = 9600
    tail_bytes = 38400

    def __init__(self):
        self.reset()

    def reset(self):
        self.lead = bytearray()
        self.active = False
        self.quiet_bytes = 0

    @staticmethod
    def quiet(pcm):
        samples = array.array('h', pcm)
        if sys.byteorder != 'little': samples.byteswap()
        return (not samples or (max(abs(s) for s in samples) < 64 and
                sum(s * s for s in samples) < len(samples) * 16 * 16))

    def feed(self, pcm):
        output = []; pending = bytearray()
        for offset in range(0, len(pcm), self.frame_bytes):
            frame = pcm[offset:offset + self.frame_bytes]
            if not self.quiet(frame):
                if not self.active:
                    pending.extend(self.lead); self.lead.clear()
                self.active = True; self.quiet_bytes = 0
                pending.extend(frame)
            elif self.active:
                pending.extend(frame); self.quiet_bytes += len(frame)
                if self.quiet_bytes >= self.tail_bytes:
                    output.extend((bytes(pending), None)); pending.clear()
                    self.active = False; self.quiet_bytes = 0
            else:
                self.lead.extend(frame)
                if len(self.lead) > self.lead_bytes: del self.lead[:-self.lead_bytes]
        if pending: output.append(bytes(pending))
        return output


class LiveEconomy:
    def __init__(self, enabled=True, clock=time.monotonic):
        self.enabled = enabled
        self.clock = clock
        self.gate = SilenceGate()
        self.automatic_vad = True
        self.last_frame = float('-inf')
        self.frame_digest = None
        self.received_audio_bytes = 0
        self.sent_audio_bytes = 0

    def frame_allowed(self, data):
        if not self.enabled: return True
        now = self.clock(); elapsed = now - self.last_frame
        if elapsed < 2: return False
        digest = hashlib.sha256(data).digest()
        if digest == self.frame_digest and elapsed < 30: return False
        self.last_frame = now; self.frame_digest = digest
        return True

    def filter_gemini(self, wire):
        if not self.enabled: return [wire]
        try:
            message = json.loads(wire)
            if not isinstance(message, dict): return [wire]
            if isinstance(message.get('setup'), dict):
                setup = message['setup']
                config = setup.setdefault('generationConfig', {})
                config.setdefault('mediaResolution', 'MEDIA_RESOLUTION_LOW')
                activity = setup.setdefault('realtimeInputConfig', {})
                # Retain video between turns, but exclude silent audio from turn context.
                activity['turnCoverage'] = 'TURN_INCLUDES_AUDIO_ACTIVITY_AND_ALL_VIDEO'
                self.automatic_vad = not activity.get('automaticActivityDetection', {}).get('disabled', False)
                compression = setup.setdefault('contextWindowCompression', {})
                compression.setdefault('triggerTokens', 24000)
                compression.setdefault('slidingWindow', {}).setdefault('targetTokens', 12000)
                instruction = setup.setdefault('systemInstruction', {})
                instruction.setdefault('parts', []).append({'text': '通常の返答は日本語で1〜3文を目安に簡潔にしてください。詳しい説明を本人が求めた場合は必要な長さで答えてください。長い制作結果はまず要点を話してください。'})
                # Resumption, model choice, tools and the existing persona stay intact.
                return [json.dumps(message)]
            realtime = message.get('realtimeInput')
            if not isinstance(realtime, dict): return [wire]
            if realtime.get('audioStreamEnd'): self.gate.reset()
            audio = realtime.get('audio')
            pcm = None
            if self.automatic_vad and isinstance(audio, dict) and audio.get('mimeType') == 'audio/pcm;rate=16000':
                pcm = base64.b64decode(audio['data'], validate=True)
                if len(pcm) % 2: return [wire]
            outgoing = []
            if pcm is not None:
                self.received_audio_bytes += len(pcm)
                realtime.pop('audio')
            video = realtime.get('video')
            if isinstance(video, dict) and not self.frame_allowed(base64.b64decode(video['data'], validate=True)):
                realtime.pop('video')
            if realtime: outgoing.append(json.dumps(message))
            if pcm is not None:
                for block in self.gate.feed(pcm):
                    if block is None:
                        payload = {'audioStreamEnd': True}
                    else:
                        self.sent_audio_bytes += len(block)
                        payload = {'audio': {'mimeType': 'audio/pcm;rate=16000', 'data': base64.b64encode(block).decode()}}
                    outgoing.append(json.dumps({'realtimeInput': payload}))
            return outgoing
        except (ValueError, KeyError, TypeError, AttributeError):
            # Unsupported or malformed input follows the normal provider error path.
            return [wire]


class ProviderBackoff:
    """One shared cooldown prevents every device from retrying exhausted quotas."""
    def __init__(self, clock=time.monotonic):
        self.clock = clock; self.failures = {}; self.until = {}

    def remaining(self, provider):
        return max(0, self.until.get(provider, 0) - self.clock())

    def fail(self, provider, retry_after=0):
        failures = self.failures.get(provider, 0) + 1
        self.failures[provider] = failures
        self.until[provider] = self.clock() + min(3600, max(retry_after, min(900, 60 * 2 ** min(failures - 1, 4))))

    def clear(self, provider):
        self.failures.pop(provider, None); self.until.pop(provider, None)
