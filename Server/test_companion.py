import asyncio, copy, json, math, os, sqlite3, tempfile, unittest
from pathlib import Path
from unittest.mock import patch
from aiohttp import web
from action_policy import directive
from companion import CompanionJudge, QUESTIONS, scores_from_response
import host_policy


def payload():
    return {'session_id': 'fixture-session', 'event_id': 'final-1', 'text': '小さい時計の試作品を作りたい。',
            'policy': {'objective': '試作品の制作', 'persona': '短く話す相棒', 'speakCriteria': ['具体的な質問'],
                       'buildCriteria': ['入出力が明確な試作'], 'doNotBuildCriteria': ['送信・公開・購入']}}


class Reply:
    status = 200
    async def __aenter__(self): return self
    async def __aexit__(self, *args): pass
    async def json(self): return {'answers': {key: {'type': 'noul', 'noul': 0.9 if key == 'draft' else 0.1} for key in QUESTIONS}}


class HTTP:
    def __init__(self): self.calls = []; self.status = 200
    def post(self, url, **kwargs):
        self.calls.append((url, kwargs)); value = Reply(); value.status = self.status; return value


class JudgeTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.http = HTTP(); self.db = sqlite3.connect(':memory:'); self.judge = CompanionJudge(self.http, self.db)
        self.environment = patch.dict(os.environ, {'TYPESAFE_API_KEY': 'fixture-only'}); self.environment.start()
    async def asyncTearDown(self): self.environment.stop(); self.db.close()
    async def test_parallel_replay_calls_real_api_contract_once(self):
        results = await asyncio.gather(self.judge.judge(payload()), self.judge.judge(payload()))
        self.assertEqual(results[0], results[1]); self.assertEqual(len(self.http.calls), 1)
        url, args = self.http.calls[0]
        self.assertEqual(url, 'https://api.typesafe.ai/v1/systemone'); self.assertFalse(args['allow_redirects'])
        self.assertEqual(set(args['json']['questions']), set(QUESTIONS)); self.assertEqual(results[0]['judge'], 'jev')
    async def test_changed_final_turn_cannot_execute_again(self):
        await self.judge.judge(payload()); changed = payload(); changed['text'] = '別の依頼'
        with self.assertRaises(web.HTTPConflict): await self.judge.judge(changed)
        self.assertEqual(len(self.http.calls), 1)
    async def test_outage_backs_off_and_does_not_cache_a_fake_judgment(self):
        self.http.status = 429
        for number in range(2):
            value = payload(); value['event_id'] += str(number)
            with self.assertRaises(web.HTTPServiceUnavailable): await self.judge.judge(value)
        self.assertEqual(len(self.http.calls), 1); self.assertEqual(self.db.execute('SELECT COUNT(*) FROM companion_turns').fetchone()[0], 0)
    async def test_malformed_input_never_calls_provider(self):
        for value in ([], {}, {'policy': []}):
            with self.assertRaises(web.HTTPBadRequest): await self.judge.judge(value)
        self.assertFalse(self.http.calls)
    def test_invalid_score_types_fail_closed(self):
        valid = {'answers': {key: {'type': 'noul', 'noul': 0.5} for key in QUESTIONS}}
        for score in (True, '1', None, math.nan, math.inf, -1, 1.01):
            invalid = copy.deepcopy(valid); invalid['answers']['draft']['noul'] = score
            with self.assertRaises(ValueError): scores_from_response(invalid)
        invalid = copy.deepcopy(valid); del invalid['answers']['stop']
        with self.assertRaises(ValueError): scores_from_response(invalid)


class HostBoundaryTests(unittest.TestCase):
    def setUp(self): self.tmp = tempfile.TemporaryDirectory(); self.root = Path(self.tmp.name)
    def tearDown(self): self.tmp.cleanup()
    def policy(self, mode): (self.root / 'run-policy.json').write_text(json.dumps({'session': mode}))
    def test_main_pc_cannot_execute_or_escape_workspace(self):
        self.policy('draft'); folder = self.root / 'workspaces/session'; folder.mkdir(parents=True)
        outside = self.root / 'private'; outside.mkdir(); (folder / 'escape').symlink_to(outside)
        self.assertIsNone(directive(self.root, 'write_file', 'session', {'path': str(folder / 'index.html')}))
        for name, args in [('terminal', {'command': 'touch file'}), ('write_file', {'path': str(outside / 'file')}), ('write_file', {'path': str(folder / 'escape/file')}), ('send_message', {}), ('write_file', {'path': 'index.html'})]:
            self.assertEqual(directive(self.root, name, 'session', args)['action'], 'block')
    def test_dedicated_mode_is_host_specific_and_downgrade_applies_to_running_tasks(self):
        self.policy('dedicated_draft'); host_policy.save(self.root, 'dedicated')
        self.assertIsNone(directive(self.root, 'terminal', 'session', {'command': 'python -m pip install fixture-package'}))
        self.assertIsNone(directive(self.root, 'write_file', 'session', {'path': str(self.root / 'local-config')}))
        for name,args in [('send_message', {}), ('browser_click', {}), ('terminal', {'command': 'git push origin main'})]:
            self.assertEqual(directive(self.root, name, 'session', args)['action'], 'block')
        host_policy.save(self.root, 'main')
        self.assertEqual(directive(self.root, 'terminal', 'session', {'command': 'touch file'})['action'], 'block')
        self.assertEqual((self.root / 'host-policy.json').stat().st_mode & 0o777, 0o600)
        self.assertEqual(host_policy.mode(self.root / 'other-host'), 'main')
    def test_unmapped_or_voice_task_cannot_gain_automatic_execution(self):
        self.assertEqual(directive(self.root, 'terminal', 'unknown', {})['action'], 'block')
        self.policy('reply'); self.assertEqual(directive(self.root, 'web_search', 'session', {})['action'], 'block')
        self.policy('policy'); self.assertIsNone(directive(self.root, 'memory', 'session', {}))
        self.assertEqual(directive(self.root, 'terminal', 'session', {})['action'], 'block')

if __name__ == '__main__': unittest.main()
