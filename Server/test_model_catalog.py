import asyncio
import unittest
from types import SimpleNamespace
from unittest.mock import patch
import model_catalog


class CatalogTests(unittest.IsolatedAsyncioTestCase):
    async def test_concurrent_requests_share_discovery_and_no_inference_calls(self):
        calls=[]
        def subscription(provider):
            calls.append(provider)
            return {'id':provider,'title':provider,'ready':True,'models':[{'id':'fixture','title':'fixture'}]}
        catalog=model_catalog.ModelCatalog()
        with patch.object(model_catalog,'subscription_models',subscription), patch.object(model_catalog,'live_models',return_value={}), patch.object(model_catalog,'configured_model',return_value={}):
            first,second=await asyncio.gather(catalog.get(),catalog.get())
            self.assertEqual(first,second);self.assertEqual(sorted(calls),['nous','xai-oauth'])
            await catalog.get();self.assertEqual(len(calls),2)
            catalog.invalidate();await catalog.get();self.assertEqual(len(calls),4)
    async def test_provider_error_details_do_not_reach_catalog(self):
        def failed(_):raise RuntimeError('fixture-secret-credential')
        with patch.object(model_catalog,'subscription_models',failed), patch.object(model_catalog,'live_models',return_value={}), patch.object(model_catalog,'configured_model',return_value={}):
            catalog=await model_catalog.ModelCatalog().get()
        self.assertNotIn('fixture-secret',str(catalog))
        self.assertTrue(all(not value['ready'] for value in catalog['providers']))
    def test_only_valid_unique_model_ids_are_exposed_and_current_model_keeps_priority(self):
        models=model_catalog.model_rows(['b','a','b','bad\nmodel',None],preferred='b')
        self.assertEqual([value['id'] for value in models],['b','a'])
    def test_grok_oauth_uses_hermes_catalog_without_a_models_api_probe(self):
        adapter=SimpleNamespace(is_authenticated=lambda:True, get_credential=lambda:SimpleNamespace(base_url='https://api.x.ai/v1',bearer='fixture'))
        with patch.object(model_catalog,'subscription_adapter',return_value=adapter), \
             patch.object(model_catalog,'curated_subscription_ids',return_value=['grok-fixture']), \
             patch.object(model_catalog,'configured_model',return_value={}), \
             patch.object(model_catalog,'get_json',side_effect=AssertionError('OAuth has no models endpoint')) as probe:
            choice=model_catalog.subscription_models('xai-oauth')
        self.assertTrue(choice['ready']);self.assertEqual(choice['models'][0]['id'],'grok-fixture')
        self.assertIn('会話開始後',choice['message']);probe.assert_not_called()
    def test_unrecognized_credential_host_is_rejected_before_discovery(self):
        adapter=SimpleNamespace(is_authenticated=lambda:True,get_credential=lambda:SimpleNamespace(base_url='https://fixture.invalid/v1',bearer='fixture-secret'))
        with patch.object(model_catalog,'subscription_adapter',return_value=adapter), patch.object(model_catalog,'get_json') as probe:
            choice=model_catalog.subscription_models('nous')
        self.assertFalse(choice['ready']);probe.assert_not_called();self.assertNotIn('fixture-secret',str(choice))
