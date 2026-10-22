import importlib.machinery
import importlib.util
import json
from pathlib import Path
import subprocess
import threading
import unittest
from unittest.mock import patch
import urllib.request
import urllib.error

loader=importlib.machinery.SourceFileLoader('gtg_fleet_test',str(Path(__file__).parents[1]/'bin/gtg-server'))
spec=importlib.util.spec_from_loader(loader.name,loader)
m=importlib.util.module_from_spec(spec);loader.exec_module(m)

class FleetTests(unittest.TestCase):
    def test_fixed_executable_and_json_stdin(self):
        def run(argv,**kw):
            self.assertEqual(argv,[str(Path.home()/'bin/fleet-delegate'),'api'])
            self.assertFalse(kw.get('shell',False))
            self.assertEqual(json.loads(kw['input']),{'op':'answer','repo':'booty-pirates','id':'a'*16,'choice':1})
            return subprocess.CompletedProcess(argv,0,json.dumps({'ok':True,'status':'forwarded_unconfirmed'}),'')
        with patch.object(m.subprocess,'run',run):
            status,result=m.fleet_call('answer',{'repo':'booty-pirates','id':'a'*16,'choice':1})
        self.assertEqual(status,200);self.assertIn('forwarded_unconfirmed',result['output'])
    def test_refuses_override_and_timeout_is_not_success(self):
        with patch.object(m.subprocess,'run',side_effect=AssertionError('must not execute')):
            self.assertEqual(m.fleet_call('answer',{'op':'list'})[0],400)
        with patch.object(m.subprocess,'run',side_effect=subprocess.TimeoutExpired('test',45)):
            self.assertFalse(m.fleet_call('list',{})[1]['ok'])
    def test_http_requires_auth_and_mcp_preserves_result(self):
        m.TOKEN='test-only-token'
        server=m.Server(('127.0.0.1',0),m.Handler)
        worker=threading.Thread(target=server.serve_forever);worker.start()
        try:
            url='http://127.0.0.1:%s/api/fleet/decisions'%server.server_port
            with self.assertRaises(urllib.error.HTTPError) as err:urllib.request.urlopen(url)
            self.assertEqual(err.exception.code,401)
            with patch.object(m,'fleet_call',return_value=(200,{'ok':True,'output':'{"decisions":[]}','error':None})) as call:
                req=urllib.request.Request(url+'?repo=booty-pirates',headers={'Authorization':'Bearer test-only-token'})
                with urllib.request.urlopen(req) as response:self.assertTrue(json.load(response)['ok'])
                self.assertEqual(call.call_args.args,('list',{'repo':'booty-pirates'}))
                result=m.rpc_tools_call(1,{'name':'fleet_decisions','arguments':{'repo':'booty-pirates'}})
                self.assertFalse(result['result']['isError']);self.assertIn('decisions',result['result']['content'][0]['text'])
        finally:server.shutdown();server.server_close();worker.join(3)

if __name__=='__main__':unittest.main()
