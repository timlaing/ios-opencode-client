# SPDX-License-Identifier: MPL-2.0
import base64
import copy
import http.client
import json
import threading
import time
import unittest
from mock.contract import Invalid, OPERATIONS, ROOT, SCHEMAS, SPEC, assert_supported, match, response_schema, validate, validate_event
from mock.fixtures import generate
from mock.server import MODELED, State, jsonc, make_server, valid_answer


class ContractTests(unittest.TestCase):
    def test_schema_vocabulary_is_explicit(self):
        for schema in SCHEMAS.values():
            assert_supported(schema)
        for methods in SPEC['paths'].values():
            for operation in methods.values():
                for p in operation.get('parameters',[]):
                    assert_supported(p['schema'])
                for media in operation.get('requestBody',{}).get('content',{}).values():
                    assert_supported(media['schema'])
                for response in operation['responses'].values():
                    for media in response.get('content',{}).values():
                        assert_supported(media['schema'])
        with self.assertRaises(Invalid):
            assert_supported({'minProperties':1})

    def test_generated_fixtures_match_exact_snapshot(self):
        f = generate()
        for key, name in [('sessions','Session.Info'),('models','Model.Info'),('agents','Agent.Info'),
                          ('projects','Project'),('permissions','Permission.Request'),('forms','Form.Info'),
                          ('mcp','Mcp.Server'),('plugins','Plugin.Info'),('diff','FileDiff.Info')]:
            for value in f[key].values() if isinstance(f[key],dict) else f[key]:
                validate(value,SCHEMAS[name])
        for messages in f['messages'].values():
            for value in messages:
                validate(value,SCHEMAS['Session.Message.Info'])
        self.assertEqual(generate(),generate())
        self.assertNotEqual(generate()['messages']['ses_demo_006'],generate(26)['messages']['ses_demo_006'])

    def test_modeled_routes_exist(self):
        self.assertEqual(len(OPERATIONS),141)
        self.assertTrue(MODELED <= OPERATIONS.keys())
        self.assertEqual(match('GET','/api/session/active')[0]['operationId'],'session.active')
        self.assertEqual(match('GET','/api/fs/read/src/a%20b.py')[1]['wildcard'],'src/a%20b.py')
        scope = json.loads((ROOT/'contracts/mobile-scope.json').read_text())
        initial = {op for w in scope['workflows'] if w['stage'].startswith('initial') for op in w['operations']}
        self.assertTrue(initial <= MODELED)
        self.assertEqual(len(MODELED),61)

    def test_offline_event_trace_and_provenance(self):
        import hashlib
        manifest = json.loads((ROOT/'contracts/source-manifest.json').read_text())
        self.assertEqual(hashlib.sha256((ROOT/'contracts/opencode-v2.0.25.openapi.json').read_bytes()).hexdigest(),manifest['sha256'])
        self.assertEqual(manifest['bytes'],550766)
        trace = [json.loads(line) for line in (ROOT/'fixtures/generated/events.jsonl').read_text().splitlines()]
        for event in trace:
            validate_event(event)
        framed = [json.loads(frame[6:]) for frame in (ROOT/'fixtures/generated/events.sse').read_text().split('\n\n') if frame.startswith('data: ')]
        self.assertEqual(trace,framed)
        self.assertEqual(len({e['id'] for e in trace}),len(trace))
        self.assertIn('session.execution.succeeded',[e['type'] for e in trace])

    def test_guard_rejects_bad_shapes(self):
        for data,schema in [(True,{'type':'integer'}),({'x':1},{'type':'object','additionalProperties':False}),
                            ('invalid',{'type':'string','pattern':'^ses'}),([],{'type':'array','minItems':1})]:
            with self.assertRaises(Invalid):
                validate(data,schema)
        validate(3,{'anyOf':[{'type':'integer'},{'type':'string'}]})

    def test_token_expiry_and_password_rotation(self):
        now = [100000.0]
        state = State(clock=lambda:now[0])
        token = state.token()
        header = 'Basic '+base64.b64encode(('opencode:'+token).encode()).decode()
        self.assertTrue(state.authorized(header))
        state.password = 'different'
        self.assertFalse(state.authorized(header))
        state.password = 'mock-password'
        now[0] += 30*24*60*60
        self.assertFalse(state.authorized(header))

    def test_jsonc_keeps_string_semantics(self):
        self.assertEqual(jsonc('// comment\n{"url":"https://example.com/a,b}", /* c */ "x":[1,],}'),
                         {'url':'https://example.com/a,b}','x':[1]})

    def test_conditional_form_semantics(self):
        form = generate()['forms'][0]
        self.assertTrue(valid_answer(form,{'environment':'staging','checks':['unit']}))
        self.assertFalse(valid_answer(form,{'environment':'production','checks':['unit']}))
        self.assertTrue(valid_answer(form,{'environment':'production','confirm':True,'checks':['unit']}))
        self.assertFalse(valid_answer(form,{'environment':'staging','confirm':True}))
        self.assertFalse(valid_answer(form,{'environment':'staging','checks':['made-up']}))
        self.assertFalse(valid_answer(form,{'environment':'staging','replicas':9}))


class HTTPTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = make_server(port=0)
        cls.worker = threading.Thread(target=cls.server.serve_forever,daemon=True)
        cls.worker.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.worker.join(timeout=2)

    def setUp(self):
        self.server.state.reset()

    def request(self,method,path,body=None,auth=True,raw=None,headers=None):
        conn = http.client.HTTPConnection('127.0.0.1',self.server.server_port,timeout=3)
        hdr = {'Accept':'application/json'}
        if auth:
            hdr['Authorization'] = 'Basic '+base64.b64encode(b'opencode:mock-password').decode()
        if body is not None:
            raw = json.dumps(body).encode()
            hdr['Content-Type'] = 'application/json'
        if headers:
            hdr.update(headers)
        conn.request(method,path,body=raw,headers=hdr)
        resp = conn.getresponse()
        data = resp.read()
        status, response_headers = resp.status, dict(resp.getheaders())
        conn.close()
        if data and 'application/json' in response_headers.get('Content-Type',''):
            data = json.loads(data)
        operation,_ = match(method,path.split('?')[0])
        if operation:
            schema = response_schema(operation,status)
            if schema:
                validate(data,schema)
        return status,data,response_headers

    def test_auth_required_pair_single_use_and_json_token(self):
        self.assertEqual(self.request('GET','/api/info',auth=False)[0],401)
        status,code,_ = self.request('POST','/api/pair')
        self.assertEqual(status,200)
        path = '/auth/connect/'+code['code']
        status,session,_ = self.request('GET',path,auth=False)
        self.assertEqual(status,200)
        hdr = {'Authorization':'Basic '+base64.b64encode(('opencode:'+session['token']).encode()).decode()}
        self.assertEqual(self.request('GET','/api/info',auth=False,headers=hdr)[0],200)
        self.assertEqual(self.request('GET',path,auth=False)[0],401)

    def test_browser_pair_cookie_and_expired_code(self):
        _,code,_ = self.request('POST','/api/pair')
        status,_,hdr = self.request('GET','/auth/connect/'+code['code'],auth=False,headers={'Accept':'text/html'})
        self.assertEqual(status,302)
        self.assertIn('HttpOnly',hdr['Set-Cookie'])
        self.assertEqual(self.request('GET','/auth/connect/no-longer-valid',auth=False)[0],401)

    def test_creation_rename_switch_and_export(self):
        path = '/api/session'
        status,data,_ = self.request('POST',path,{'id':'ses_test','title':'New project chat','location':{'directory':'/srv/demo/new'}})
        self.assertEqual(status,200)
        self.assertEqual(data['data']['location']['directory'],'/srv/demo/new')
        self.assertEqual(self.request('PATCH',path+'/ses_test',{'title':'Renamed'})[0],204)
        self.assertEqual(self.request('POST',path+'/ses_test/model',{'model':{'id':'demo-code','providerID':'synthetic'}})[0],204)
        self.assertEqual(self.request('GET','/api/experimental/session/ses_test/export')[0],200)
        self.assertEqual(self.request('GET',path+'/ses_test')[1]['data']['title'],'Renamed')

    def test_message_pagination_is_opaque_and_type_scoped(self):
        path = '/api/session/ses_demo_006/message'
        status,page,_ = self.request('GET',path+'?limit=10&order=asc&type=user')
        self.assertEqual(status,200)
        cursor = page['cursor']['next']
        next_page = self.request('GET',path+'?limit=10&type=user&cursor='+cursor)[1]
        self.assertFalse({m['id'] for m in page['data']} & {m['id'] for m in next_page['data']})
        self.assertEqual(self.request('GET',path+'?cursor=broken')[0],400)
        self.assertEqual(self.request('GET',path+'?cursor='+cursor+'&type=assistant')[0],400)

    def test_admission_id_conflict_and_recovery(self):
        path = '/api/session/ses_demo_007/prompt'
        prompt = {'id':'msg_once','text':'Keep queued','resume':False,'delivery':'queue'}
        self.assertEqual(self.request('POST',path,prompt)[0],200)
        self.assertEqual(self.request('POST',path,prompt)[0],409)
        inbox = self.request('GET','/api/session/ses_demo_007/inbox')[1]['data']
        self.assertEqual([x['id'] for x in inbox],['msg_once'])
        self.assertEqual(self.request('PATCH','/api/session/ses_demo_007/inbox/msg_once',{'delivery':'steer'})[0],204)
        self.assertEqual(self.request('DELETE','/api/session/ses_demo_007/inbox/msg_once')[0],204)

    def test_unknown_fields_do_not_silently_succeed(self):
        self.assertEqual(self.request('POST','/api/session/ses_demo_007/prompt',{'text':'hello','unexpected':True})[0],400)
        self.assertEqual(self.request('GET','/api/session/ses_missing')[0],404)
        self.assertEqual(self.request('POST','/api/session/ses_demo_007/archive',{})[0],404)
        self.assertEqual(self.request('POST','/api/worktree',{})[0],501)

    def test_raw_files_range_conditional_and_configuration(self):
        location = 'location%5Bdirectory%5D=%2Fsrv%2Fdemo%2Fnew'
        content = b'// keep\n{"plugins":["-demo.audit"],"mcp":{}}\n'
        path = '/api/experimental/fs/write?'+location+'&path=opencode.jsonc'
        self.assertEqual(self.request('POST',path,raw=content,headers={'Content-Type':'application/octet-stream'})[0],200)
        read = '/api/fs/read/opencode.jsonc?'+location
        status,data,hdr = self.request('GET',read)
        self.assertEqual((status,data),(200,content))
        self.assertEqual(self.request('GET',read,headers={'If-None-Match':hdr['ETag']})[0],304)
        self.assertEqual(self.request('GET',read,headers={'Range':'bytes=0-6'})[:2],(206,content[:7]))
        self.assertEqual(self.request('GET',read,headers={'Range':'bytes=99999-'})[0],416)
        self.assertEqual(self.request('GET','/api/plugin?'+location)[1]['data'],[])
        self.assertEqual(self.request('GET','/api/config?'+location)[1][0]['info']['plugins'],['-demo.audit'])

    def test_mcp_runtime_toggle_does_not_edit_config(self):
        before = self.request('GET','/api/config')[1]
        self.assertEqual(self.request('POST','/api/experimental/mcp/demo-docs/disconnect')[0],204)
        self.assertEqual(self.request('GET','/api/mcp')[1]['data'][0]['status']['status'],'disabled')
        self.assertEqual(self.request('POST','/api/experimental/mcp/demo-docs/connect')[0],204)
        self.assertEqual(self.request('GET','/api/config')[1],before)

    def test_approval_reply_and_stale_reply(self):
        path = '/api/session/ses_demo_002/permission/per_demo/reply'
        self.assertEqual(self.request('POST',path,{'decision':'once'})[0],204)
        self.assertEqual(self.request('POST',path,{'decision':'once'})[0],404)

    def test_form_reply_validation_and_already_settled(self):
        path = '/api/session/ses_demo_003/form/frm_demo/reply'
        self.assertEqual(self.request('POST',path,{'answer':{'environment':'production'}})[0],400)
        answer = {'answer':{'environment':'production','confirm':True,'checks':['unit']}}
        self.assertEqual(self.request('POST',path,answer)[0],204)
        self.assertEqual(self.request('POST',path,answer)[0],409)

    def test_read_model_routes(self):
        for path in ['/api/info','/api/location','/api/project','/api/model','/api/model/default','/api/agent','/api/agent/build',
                     '/api/command','/api/skill','/api/config','/api/fs/list','/api/fs/find?query=main&type=file',
                     '/api/vcs','/api/vcs/status','/api/vcs/base','/api/vcs/diff?mode=working',
                     '/api/session/ses_demo_001/diff','/api/session/ses_demo_001/context',
                     '/api/session/ses_demo_003/form','/api/session/ses_demo_003/form/frm_demo',
                     '/api/form','/api/permission/request','/api/permission/saved','/api/session/active']:
            with self.subTest(path=path):
                self.assertEqual(self.request('GET',path)[0],200)

    def test_generated_http_examples(self):
        examples = json.loads((ROOT/'fixtures/generated/http-cases.json').read_text())
        for case in examples:
            self.server.state.reset()
            with self.subTest(operation=case['operationId']):
                status,data,_ = self.request(case['method'],case['path'],case.get('body'))
                self.assertEqual(status,case['expectedStatus'])
                if 'expected' in case:
                    self.assertEqual(data,case['expected'])

    def test_attachment_data_and_staged_uri_roundtrip(self):
        self.request('POST','/api/experimental/fs/write?path=%2Ftmp%2Fopencode-mock%2Fuploads%2Fdemo%2Fnotes.txt',raw=b'Generated attachment')
        body = {'id':'msg_files','text':'Read files','resume':False,'files':[
            {'uri':'data:image/png;base64,aGVsbG8=','name':'synthetic.png'},
            {'uri':'file:///tmp/opencode-mock/uploads/demo/notes.txt','name':'notes.txt'}]}
        status,data,_ = self.request('POST','/api/session/ses_demo_007/prompt',body)
        self.assertEqual(status,200)
        self.assertEqual(data['data']['payload']['files'][0]['source'],{'type':'inline'})
        self.assertEqual(base64.b64decode(data['data']['payload']['files'][1]['data']),b'Generated attachment')
        self.assertEqual(self.request('POST','/api/session/ses_demo_007/prompt',{'text':'missing','files':[{'uri':'file:///missing'}]})[0],400)

    def test_remaining_initial_mutations_and_later_helpers(self):
        self.assertEqual(self.request('PATCH','/api/project/project_harbour',{'name':'New display name'})[0],200)
        self.assertEqual(self.request('POST','/api/location/reload')[0],204)
        self.assertEqual(self.request('POST','/api/session/ses_demo_007/agent',{'agent':'build'})[0],204)
        self.assertEqual(self.request('POST','/api/session/ses_demo_007/view',{'idle':123})[0],204)
        self.assertEqual(self.request('POST','/api/session/ses_demo_007/compact',{})[0],200)
        self.assertEqual(self.request('GET','/api/session/ses_demo_002/permission/per_demo')[0],200)
        self.assertEqual(self.request('DELETE','/api/session/ses_demo_003/form/frm_demo')[0],204)
        self.assertEqual(self.request('GET','/api/session/ses_demo_001/message/msg_user_0')[0],200)
        self.assertEqual(self.request('POST','/api/session/ses_demo_001/fork',{})[0],200)
        self.assertEqual(self.request('POST','/api/session/ses_demo_007/interrupt?resume=false')[1],{'interrupted':False})
        self.assertEqual(self.request('DELETE','/api/session/ses_demo_007')[0],204)
        self.assertEqual(self.request('DELETE','/api/permission/saved/absent')[0],204)

    def test_failure_retry_waiting_and_unknown_event_scenarios(self):
        for name in ('failure','retry','approval','question','duplicate-events','unknown-event'):
            with self.subTest(scenario=name):
                self.server.state.reset()
                self.request('POST','/__mock/scenario',{'name':name},auth=False,headers={'X-Mock-Control':'mock-control'})
                self.assertEqual(self.request('POST','/api/session/ses_demo_007/prompt',{'text':'scenario'})[0],200)
                deadline = time.monotonic()+3
                while time.monotonic() < deadline:
                    with self.server.state.lock:
                        events = copy.deepcopy(self.server.state.events)
                        waiting = name in ('approval','question')
                        terminal = 'permission.asked' if name == 'approval' else 'form.created' if name == 'question' else 'session.execution.failed' if name == 'failure' else 'session.execution.succeeded'
                        done = any(e['type'] == terminal for e in events)
                    if done:
                        break
                    time.sleep(0.01)
                self.assertTrue(done)
                for event in events:
                    validate_event(event)

    def test_synthetic_command_and_skill_invocation(self):
        self.assertEqual(self.request('POST','/api/session/ses_demo_007/command',{'name':'review','text':'Review synthetic files'})[0],204)
        self.assertEqual(self.request('POST','/api/experimental/session/ses_demo_007/skill',{'id':'demo-review','resume':False})[0],204)

    def test_sse_uses_real_data_frame_and_reconciles_after_disconnect(self):
        conn = http.client.HTTPConnection('127.0.0.1',self.server.server_port,timeout=3)
        conn.request('GET','/api/event',headers={'Authorization':'Basic '+base64.b64encode(b'opencode:mock-password').decode()})
        response = conn.getresponse()
        self.assertEqual(response.status,200)
        first = json.loads(response.readline().decode().removeprefix('data: '))
        self.assertEqual(first['type'],'server.connected')
        self.request('POST','/api/session/ses_demo_007/prompt',{'text':'stream','id':'msg_stream'})
        observed = set()
        for _ in range(150):
            line = response.readline().decode().strip()
            if line.startswith('data: '):
                event = json.loads(line[6:])
                observed.add(event['type'])
                if event['type'] == 'session.execution.succeeded':
                    break
        self.assertTrue({'session.reasoning.delta','session.text.delta','session.execution.succeeded'} <= observed)
        self.request('POST','/__mock/disconnect',{},auth=False,headers={'X-Mock-Control':'mock-control'})
        conn.close()
        messages = self.request('GET','/api/session/ses_demo_007/message')[1]['data']
        self.assertTrue(any(m['type'] == 'assistant' and m.get('finish') == 'stop' for m in messages))

    def test_uncertain_submission_keeps_exactly_one_admission(self):
        headers = {'X-Mock-Control':'mock-control'}
        self.request('POST','/__mock/scenario',{'name':'timeout-after-commit'},auth=False,headers=headers)
        with self.assertRaises(http.client.RemoteDisconnected):
            self.request('POST','/api/session/ses_demo_007/prompt',{'id':'msg_uncertain','text':'uncertain','resume':False})
        self.assertEqual(len(self.request('GET','/api/session/ses_demo_007/inbox')[1]['data']),1)
        self.assertEqual(self.request('POST','/api/session/ses_demo_007/prompt',{'id':'msg_uncertain','text':'uncertain'})[0],409)


if __name__ == '__main__':
    unittest.main()
