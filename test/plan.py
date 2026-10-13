import copy
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import threading
import unittest
import urllib.error
import urllib.request


class PlanAPI(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.conf, self.state = root / 'conf', root / 'state'
        self.conf.mkdir()
        self.state.mkdir()
        (self.conf / 'plan.txt').write_text('every: Push-Ups x15 | Air Squats x10 | kettlebell back stretch 30s\n')
        self.old_env = os.environ.copy()
        os.environ.update(GTG_CONF_DIR=str(self.conf), GTG_STATE_DIR=str(self.state), GTG_NO_CALENDAR='1', GTG_NO_PAGE='1')
        self.addCleanup(self.restore_env)
        loader = importlib.machinery.SourceFileLoader('gtg_plan_server', str(Path(__file__).resolve().parents[1] / 'bin/gtg-server'))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        self.module = importlib.util.module_from_spec(spec)
        loader.exec_module(self.module)
        self.module.TOKEN = 'test-token'
        self.module._slot_now = lambda: '2026-10-13T12'
        self.http = self.module.ThreadingHTTPServer(('127.0.0.1', 0), self.module.Handler)
        self.thread = threading.Thread(target=self.http.serve_forever)
        self.thread.start()
        self.addCleanup(self.stop_server)
        self.base = 'http://127.0.0.1:%d' % self.http.server_port
        self.plan = {'date': '2026-10-13', 'readiness': 74, 'sleep': 70, 'band': 'moderate', 'note': 'Keep it easy',
                     'slots': [{'hour': 10, 'items': [{'movement': 'Push-Ups', 'reps': 15}]},
                               {'hour': 11, 'items': [{'movement': 'Air Squats', 'reps': 10}]},
                               {'hour': 12, 'items': [{'movement': 'kettlebell back stretch', 'seconds': 30}], 'why': 'Recover'},
                               {'hour': 13, 'items': [{'movement': 'Push-Ups', 'reps': 15}]}],
                     'targets': {'Push-Ups': 60, 'kettlebell back stretch': 60}}

    def restore_env(self):
        os.environ.clear()
        os.environ.update(self.old_env)

    def stop_server(self):
        self.http.shutdown()
        self.http.server_close()
        self.thread.join()

    def request(self, path='/api/plan', body=None, auth=True):
        headers = {'Content-Type': 'application/json'}
        if auth:
            headers['Authorization'] = 'Bearer test-token'
        req = urllib.request.Request(self.base + path, data=json.dumps(body).encode() if body is not None else None, headers=headers)
        try:
            response = urllib.request.urlopen(req)
        except urllib.error.HTTPError as exc:
            response = exc
        with response:
            return response.status, json.load(response)

    def test_auth_and_no_plan(self):
        for path in ('/api/plan', '/api/plan/next'):
            self.assertEqual(self.request(path, auth=False)[0], 401)
            self.assertEqual(self.request(path)[1]['plan'], None)
        self.assertEqual(self.request(body=self.plan, auth=False)[0], 401)

    def test_overwrite_history_and_prefix(self):
        self.assertEqual(self.request(body=self.plan)[0], 200)
        changed = copy.deepcopy(self.plan)
        changed['note'] = 'New note'
        self.assertEqual(self.request('/gtg/api/plan', changed)[0], 200)
        tomorrow = dict(self.plan, date='2026-10-14')
        self.assertEqual(self.request(body=tomorrow)[0], 200)
        self.assertEqual(self.request()[1]['plan']['note'], 'New note')
        self.assertEqual(self.request('/api/plan?date=2026-10-14')[1]['plan']['note'], 'Keep it easy')
        self.assertEqual(len(list((self.state / 'plans').glob('*.json'))), 2)

    def test_validation_and_unknown_names(self):
        mutations = [dict(date='2026-02-30'), dict(date='../secrets'), dict(readiness=True), dict(sleep=101),
                     dict(band='extreme'), dict(note=42), dict(slots='no'), dict(targets=[]),
                     dict(slots=[{'hour': 24, 'items': []}]),
                     dict(slots=[{'hour': 10, 'items': [{'movement': 'Push-Ups', 'reps': -1}]}]),
                     dict(slots=[{'hour': 10, 'items': [{'movement': 'Push-Ups', 'reps': 1, 'seconds': 2}]}]),
                     dict(slots=[{'hour': 10, 'items': [{'movement': 'Push-Ups', 'reps': True}]}]),
                     dict(slots=[self.plan['slots'][0], self.plan['slots'][0]]), dict(targets={'Push-Ups': 0})]
        for mutation in mutations:
            with self.subTest(mutation=mutation):
                self.assertEqual(self.request(body=dict(self.plan, **mutation))[0], 400)
        for mutation in (dict(targets={'Unknown': 60}), dict(slots=[{'hour': 12, 'items': [{'movement': 'Unknown', 'reps': 10}]}])):
            status, body = self.request(body=dict(self.plan, **mutation))
            self.assertEqual(status, 422)
            self.assertIn('Push-Ups', body['known'])
        self.assertEqual(self.request('/api/plan?date=2026-02-30')[0], 400)
        self.assertFalse((self.state / 'plans').exists())

    def test_live_progress_and_next(self):
        self.assertEqual(self.request(body=self.plan)[0], 200)
        (self.state / 'log.tsv').write_text('2026-10-12T10:00:00\tPush-Ups\t50\thome\n'
                                          '2026-10-13T10:00:00\tPush-Ups\t15\thome\n'
                                          '2026-10-13T10:01:00\tPush-Ups\t5\thome\n'
                                          '2026-10-13T11:00:00\tAir Squats\tskip\thome\n'
                                          '2026-10-13T09:00:00\tkettlebell back stretch\t\thome\t\t20\n')
        (self.state / 'slots.tsv').write_text('2026-10-13T10:00:00\t2026-10-13T10\tskip\tpaused\n'
                                            '2026-10-13T11:00:00\t2026-10-13T11\tanswered\tskip\n'
                                            '2026-10-13T12:00:00\t2026-10-13T12\tanswered\tsnooze\n')
        body = self.request()[1]
        self.assertEqual([s['status'] for s in body['plan']['slots']], ['done', 'skipped', 'pending', 'pending'])
        self.assertEqual(body['progress']['targets']['Push-Ups'], {'done': 20, 'target': 60, 'remaining': 40})
        self.assertEqual(body['progress']['targets']['kettlebell back stretch']['done'], 20)
        next_plan = self.request('/api/plan/next')[1]
        self.assertEqual(next_plan['slot'], '2026-10-13T12')
        self.assertEqual(next_plan['items'], [{'movement': 'kettlebell back stretch', 'seconds': 30}])
        self.assertEqual(next_plan['why'], 'Recover')
        self.assertEqual(next_plan['remaining_targets']['Push-Ups'], 40)
        with (self.state / 'slots.tsv').open('a') as fh:
            fh.write('2026-10-13T12:00:00\t2026-10-13T12\tanswered\telsewhere\n')
        self.assertEqual(self.request('/api/plan/next')[1]['slot'], '2026-10-13T13')
        with (self.state / 'slots.tsv').open('a') as fh:
            fh.write('2026-10-13T13:00:00\t2026-10-13T13\tanswered\toff\n')
        self.assertIsNone(self.request('/api/plan/next')[1]['slot'])

    def test_webhook_carries_same_suggestion(self):
        self.assertEqual(self.request(body=self.plan)[0], 200)
        captured = []
        self.module._webhook_creds = lambda: ('https://example.invalid', 'test-key')
        self.module._channel_context = lambda *args: ('away', 'Air Squats x10')
        self.module._post_webhook = lambda url, key, payload: captured.append(payload)
        self.module._send_channel('phone', '2026-10-13T12', False, 'away')
        self.assertEqual(captured[0]['plan'], self.request('/api/plan/next')[1])

    def test_early_plan_round_completes_selected_slot(self):
        self.assertEqual(self.request(body=self.plan)[0], 200)
        status, _ = self.request('/api/log', {'text': 'Push-Ups x15', 'plan_slot': '2026-10-13T13'})
        self.assertEqual(status, 200)
        self.assertEqual(self.request()[1]['plan']['slots'][3]['status'], 'done')
        self.assertEqual(self.request('/api/log', {'text': 'Push-Ups x15', 'plan_slot': '../bad'})[0], 400)


if __name__ == '__main__':
    unittest.main()
