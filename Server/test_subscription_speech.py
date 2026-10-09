import json
import unittest
from types import SimpleNamespace
from unittest.mock import patch
import subscription_speech


class SpeechTests(unittest.TestCase):
    def test_only_nous_token_and_managed_host_are_used_even_when_direct_api_credentials_exist(self):
        response=SimpleNamespace(headers={'Content-Type':'audio/mpeg'},read=lambda _:b'fixture-audio')
        class Response:
            def __enter__(self):return response
            def __exit__(self,*_):pass
        seen=[]
        class Opener:
            def open(self,request,timeout):seen.append(request);return Response()
        gateway=SimpleNamespace(gateway_origin='https://openai-audio-gateway.nousresearch.com',nous_user_token='fixture-nous-only')
        with patch.object(subscription_speech,'resolve_gateway',return_value=gateway),patch.object(subscription_speech,'build_opener',return_value=Opener()),patch.dict('os.environ',{'OPENAI_API_KEY':'fixture-direct-never-use'}):
            self.assertEqual(subscription_speech.synthesize('日本語の返答'),b'fixture-audio')
        request=seen[0]
        self.assertEqual(request.full_url,'https://openai-audio-gateway.nousresearch.com/v1/audio/speech')
        self.assertEqual(request.get_header('Authorization'),'Bearer fixture-nous-only')
        self.assertEqual(json.loads(request.data)['response_format'],'mp3')
        self.assertNotIn('fixture-direct',str(request.headers))
    def test_unavailable_subscription_fails_without_any_direct_api_request(self):
        with patch.object(subscription_speech,'resolve_gateway',side_effect=RuntimeError('unavailable')),patch.object(subscription_speech,'build_opener') as opener:
            with self.assertRaises(RuntimeError):subscription_speech.synthesize('返答')
            opener.assert_not_called()
