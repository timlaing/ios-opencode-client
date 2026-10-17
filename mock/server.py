# SPDX-License-Identifier: MPL-2.0
"""Stateful, synthetic OpenCode reference mock. Python 3.11+, standard library only.

No provider calls, command execution, or writes to the host project filesystem.
Unmodelled upstream operations return an explicitly mock-only 501 response.
"""
import argparse
import base64
import copy
import hashlib
import hmac
import json
import mimetypes
import posixpath
import queue
import re
import secrets
import ssl
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlsplit

from .contract import Invalid, OPERATIONS, ROOT, SCHEMAS, match, response_schema, validate, validate_event
from .fixtures import BASE_TIME, DIRECTORY, MODEL, TOKENS, generate

SCENARIOS = {'normal', 'approval', 'question', 'failure', 'retry', 'timeout-after-commit', 'duplicate-events', 'unknown-event'}
MODELED = {
    'server.info', 'server.pair', 'server.connect', 'location.get', 'location.reload',
    'project.list', 'project.update', 'session.list', 'session.create', 'session.active',
    'session.get', 'session.remove', 'session.update', 'session.fork', 'session.switchAgent', 'session.switchModel',
    'session.prompt', 'session.command', 'experimental.session.skill', 'session.compact', 'session.interrupt', 'session.view',
    'session.message.list', 'session.message.get', 'session.context', 'session.diff',
    'session.inbox.list', 'session.inbox.cancel', 'session.inbox.update',
    'experimental.session.export', 'session.form.list', 'session.form.get', 'session.form.reply', 'session.form.cancel',
    'session.permission.list', 'session.permission.get', 'session.permission.reply',
    'permission.request.list', 'permission.saved.list', 'permission.saved.remove', 'form.list',
    'model.list', 'model.default', 'agent.list', 'agent.get', 'command.list', 'skill.list',
    'plugin.list', 'mcp.list', 'experimental.mcp.connect', 'experimental.mcp.disconnect',
    'config.get', 'fs.read', 'fs.list', 'fs.find', 'experimental.fs.write',
    'vcs.get', 'vcs.status', 'vcs.base', 'vcs.diff', 'event.subscribe',
}


class APIError(Exception):
    def __init__(self, status, tag, message, **fields):
        self.status = status
        self.body = dict(_tag=tag, message=message, **fields)


def jsonc(text):
    """Parse comments/trailing commas without modifying quoted URL/string content."""
    out, i, string, escape = [], 0, False, False
    while i < len(text):
        c = text[i]
        if string:
            out.append(c)
            if escape:
                escape = False
            elif c == '\\':
                escape = True
            elif c == '"':
                string = False
            i += 1
        elif c == '"':
            string = True
            out.append(c)
            i += 1
        elif text[i:i+2] == '//':
            end = text.find('\n', i)
            i = len(text) if end < 0 else end
        elif text[i:i+2] == '/*':
            end = text.find('*/', i+2)
            if end < 0:
                raise ValueError('Unclosed JSONC comment')
            out.append(' ')
            i = end+2
        else:
            out.append(c)
            i += 1
    text = ''.join(out)
    # Remove trailing commas only outside strings.
    out, string, escape = [], False, False
    for i, c in enumerate(text):
        if not string and c == ',' and text[i+1:].lstrip().startswith(('}', ']')):
            continue
        out.append(c)
        if escape:
            escape = False
        elif string and c == '\\':
            escape = True
        elif c == '"':
            string = not string
    return json.loads(''.join(out))


def valid_answer(form, answer):
    active, known = set(), set()
    for field in form['fields']:
        key = field['key']
        known.add(key)
        conditions = field.get('when', [])
        def satisfied(c):
            if c['key'] not in answer:
                return False
            v = answer[c['key']]
            equal = c['value'] in v if isinstance(v, list) else type(v) is type(c['value']) and v == c['value']
            return equal if c['op'] == 'eq' else not equal
        if field.get('hidden') or not all(satisfied(c) for c in conditions) or field['type'] == 'external':
            continue
        active.add(key)
        if key not in answer:
            if field.get('required'):
                return False
            continue
        v, kind = answer[key], field['type']
        if kind == 'string':
            if not isinstance(v, str) or not field.get('minLength', 0) <= len(v) <= field.get('maxLength', float('inf')):
                return False
            if 'pattern' in field and not re.search(field['pattern'], v):
                return False
            if field.get('options') and not field.get('custom') and v not in [o['value'] for o in field['options']]:
                return False
        if kind in ('integer', 'number'):
            if type(v) not in (int, float) or (kind == 'integer' and v != int(v)):
                return False
            if not field.get('minimum', -float('inf')) <= v <= field.get('maximum', float('inf')):
                return False
        if kind == 'boolean' and not isinstance(v, bool):
            return False
        if kind == 'multiselect':
            if not isinstance(v, list) or any(not isinstance(x, str) for x in v) or len(set(v)) != len(v):
                return False
            if not field.get('minItems', 0) <= len(v) <= field.get('maxItems', float('inf')):
                return False
            if not field.get('custom') and any(x not in [o['value'] for o in field['options']] for x in v):
                return False
    return set(answer) <= active and set(answer) <= known


class State:
    def __init__(self, seed=25, password='mock-password', clock=time.time):
        self.lock = threading.RLock()
        self.clock = clock
        self.password = password
        self.seed = seed
        self.subscribers = set()
        self.generation = 0
        self.reset()

    def reset(self):
        with self.lock:
            for subscriber in self.subscribers:
                subscriber.put_nowait(None)
            self.subscribers.clear()
            self.generation += 1
            self.fixture = generate(self.seed)
            self.sessions = self.fixture['sessions']
            self.messages = self.fixture['messages']
            self.files = {p: s.encode() for p, s in self.fixture['files'].items()}
            self.files.update({p: base64.b64decode(s) for p, s in self.fixture['binary'].items()})
            self.forms = {f['id']: dict(copy.deepcopy(f), state={'status': 'pending'}) for f in self.fixture['forms']}
            self.permissions = {p['id']: copy.deepcopy(p) for p in self.fixture['permissions']}
            self.active, self.inbox, self.runs, self.sequences = set(self.fixture['active']), {}, {}, {}
            self.events, self.codes = [], {}
            self.counter, self.next_scenario, self.latency_ms = 0, 'normal', 0
            self.request_log = []

    def new_id(self, prefix):
        self.counter += 1
        return f'{prefix}mock_{self.counter:08d}'

    def now(self):
        return int(self.clock()*1000)

    def location(self, directory):
        project = next((p for p in self.fixture['projects'] if directory == p['canonical'] or directory.startswith(p['canonical']+'/')), None)
        if project is None:
            project = {'id': 'project_'+hashlib.sha256(directory.encode()).hexdigest()[:10], 'canonical': directory,
                       'name': posixpath.basename(directory), 'time': {'created': self.now(), 'updated': self.now(), 'active': self.now()}, 'sandboxes': []}
            self.fixture['projects'].append(project)
        return {'directory': directory, 'project': {'id': project['id'], 'directory': project['canonical'], 'canonical': project['canonical']}}

    def token(self):
        expiry = str(int(self.clock())+30*24*60*60)
        key = hmac.digest(self.password.encode(), b'opencode-session-v1', 'sha256')
        sig = base64.urlsafe_b64encode(hmac.digest(key, expiry.encode(), 'sha256')).decode().rstrip('=')
        return expiry+'.'+sig

    def authorized(self, header, cookie=''):
        candidate = None
        try:
            if header.lower().startswith('basic '):
                username, candidate = base64.b64decode(header.split(' ', 1)[1], validate=True).decode().split(':', 1)
                if username != 'opencode':
                    return False
        except (ValueError, UnicodeError):
            return False
        if candidate is None:
            for part in cookie.split(';'):
                key, _, value = part.strip().partition('=')
                if key.startswith('opencode_session'):
                    candidate = value
        if candidate is None:
            return False
        if hmac.compare_digest(candidate, self.password):
            return True
        expiry, _, sig = candidate.partition('.')
        if not expiry.isdigit() or int(expiry) <= self.clock():
            return False
        key = hmac.digest(self.password.encode(), b'opencode-session-v1', 'sha256')
        expected = base64.urlsafe_b64encode(hmac.digest(key, expiry.encode(), 'sha256')).decode().rstrip('=')
        return hmac.compare_digest(sig, expected)

    def emit(self, kind, data, sid=None, durable=False, version=1):
        with self.lock:
            e = {'id': self.new_id('evt_'), 'created': self.now(), 'type': kind, 'data': data}
            if sid:
                e['location'] = self.sessions[sid]['location']
            elif kind.startswith('rpc.'):
                e['location'] = {'directory':DIRECTORY}
            if durable:
                self.sequences[sid] = self.sequences.get(sid, 0)+1
                e['durable'] = {'aggregateID': sid, 'seq': self.sequences[sid], 'version': version}
            validate_event(e)
            self.events.append(e)
            self.events = self.events[-10000:]
            for q in list(self.subscribers):
                try:
                    q.put_nowait(e)
                except queue.Full:
                    self.subscribers.remove(q)  # Tests use disconnect control for overflow-equivalent recovery.
            return e

    def session(self, sid):
        if sid not in self.sessions:
            raise APIError(404, 'SessionNotFoundError', 'Synthetic session not found', sessionID=sid)
        return self.sessions[sid]

    def start(self, sid, item, scenario):
        self.active.add(sid)
        self.runs[sid] = self.runs.get(sid, 0)+1
        run, generation = self.runs[sid], self.generation
        threading.Thread(target=self.execute, args=(sid, item, scenario, run, generation), daemon=True).start()

    def execute(self, sid, item, scenario, run, generation):
        def current():
            return generation == self.generation and sid in self.sessions and self.runs.get(sid) == run
        with self.lock:
            if not current():
                return
            payload = item['payload']
            self.inbox[sid] = [x for x in self.inbox.get(sid, []) if x['id'] != item['id']]
            self.messages[sid].append(dict({'id': item['id'], 'type': 'user', 'time': {'created': self.now()}}, **copy.deepcopy(payload)))
            self.emit('session.inbox.delivered', {'sessionID': sid, 'inboxID': item['id']}, sid, True)
            self.emit('session.execution.started', {'sessionID': sid}, sid, True)
            self.emit('session.status', {'sessionID': sid, 'status': {'type': 'busy'}}, sid)
            mid = self.new_id('msg_')
            assistant = {'id': mid, 'type': 'assistant', 'agent': self.sessions[sid].get('agent', 'build'),
                         'model': self.sessions[sid].get('model', MODEL), 'time': {'created': self.now()}, 'content': []}
            self.messages[sid].append(assistant)
            base = {'sessionID': sid, 'assistantMessageID': mid}
            self.emit('session.step.started', dict(base, agent=assistant['agent'], model=assistant['model'], started=self.now()), sid, True)
            if scenario == 'unknown-event':
                self.emit('rpc.demo.future', {'extra': {'new': True}}, sid)
            if scenario == 'retry':
                error = {'type': 'provider.synthetic', 'message': 'Generated transient failure'}
                self.emit('session.status', {'sessionID': sid, 'status': {'type': 'retry', 'attempt': 1, 'message': error['message'], 'next': self.now()+100}}, sid)
            if scenario in ('approval', 'question'):
                self.waiting(sid, scenario)
                return
        time.sleep(0.1)
        for ordinal, (part_type, text) in enumerate([('reasoning', 'Checking the generated project.'), ('text', '## Synthetic response\n\nThe mock completed this request.\n')]):
            with self.lock:
                if not current():
                    return
                assistant['content'].append({'type': part_type, 'text': ''})
                self.emit(f'session.{part_type}.started', dict(base, ordinal=ordinal), sid, True)
            for offset in range(0, len(text), 12):
                with self.lock:
                    if not current():
                        return
                    delta = text[offset:offset+12]
                    assistant['content'][-1]['text'] += delta
                    e = self.emit(f'session.{part_type}.delta', dict(base, ordinal=ordinal, delta=delta), sid)
                    if scenario == 'duplicate-events':
                        for q in self.subscribers:
                            q.put_nowait(e)
                time.sleep(0.02)
            with self.lock:
                self.emit(f'session.{part_type}.ended', dict(base, ordinal=ordinal, text=text), sid, True)
        with self.lock:
            if current():
                assistant.update(finish='error' if scenario == 'failure' else 'stop', tokens=copy.deepcopy(TOKENS), cost=0.01)
                assistant['time']['completed'] = self.now()
                if scenario == 'failure':
                    assistant['error'] = {'type': 'provider.synthetic', 'message': 'Generated terminal failure'}
                    self.emit('session.step.failed', dict(base, error=assistant['error']), sid, True)
                else:
                    self.emit('session.step.ended', dict(base, finish='stop', cost=0.01, tokens=TOKENS), sid, True)
                self.finish(sid, 'failed' if scenario == 'failure' else 'succeeded')

    def waiting(self, sid, scenario):
        if scenario == 'approval':
            p = dict(copy.deepcopy(self.fixture['permissions'][0]), id=self.new_id('per_'), sessionID=sid)
            self.permissions[p['id']] = p
            self.emit('permission.asked', p, sid)
        else:
            form = dict(copy.deepcopy(self.fixture['forms'][0]), id=self.new_id('frm_'), sessionID=sid)
            self.forms[form['id']] = dict(form, state={'status': 'pending'})
            self.emit('form.created', {'form': form}, sid)

    def finish(self, sid, outcome):
        self.active.discard(sid)
        for message in reversed(self.messages[sid]):
            if message['type'] == 'assistant':
                if 'finish' not in message:
                    message['finish'] = 'stop' if outcome == 'succeeded' else 'unknown'
                    message['time']['completed'] = self.now()
                break
        self.sessions[sid]['outcome'] = outcome
        self.sessions[sid]['time'].update(updated=self.now(), idle=self.now())
        self.messages[sid].append({'id': self.new_id('msg_'), 'type': 'idle', 'time': {'created': self.now()}, 'outcome': outcome})
        data = {'sessionID': sid}
        if outcome == 'failed':
            data['error'] = {'type': 'provider.synthetic', 'message': 'Generated terminal failure'}
        elif outcome == 'interrupted':
            data['reason'] = 'user'
        self.emit('session.execution.'+outcome, data, sid, True)
        self.emit('session.status', {'sessionID': sid, 'status': {'type': 'idle'}}, sid)
        if outcome == 'succeeded' and self.inbox.get(sid):
            self.start(sid, self.inbox[sid][0], 'normal')

    def page(self, items, query, name):
        limit = int(query.get('limit', 50))
        if not 1 <= limit <= 200:
            raise APIError(400, 'InvalidRequestError', 'Mock page limit must be 1..200')
        cursor = query.get('cursor')
        order, offset = query.get('order', 'desc'), 0
        if cursor:
            try:
                value = json.loads(base64.urlsafe_b64decode(cursor+'='*((-len(cursor))%4)))
                if value['name'] != name or 'order' in query or value['filter'] != {k:v for k,v in query.items() if k not in ('cursor','limit','order')}:
                    raise ValueError()
                order, offset = value['order'], value['offset']
            except (ValueError, KeyError, TypeError):
                raise APIError(400, 'InvalidCursorError', 'Invalid synthetic cursor')
        ordered = sorted(items, key=lambda x: (x['time']['created'], x['id']), reverse=order == 'desc')
        def make(pos):
            return base64.urlsafe_b64encode(json.dumps({'name': name, 'order': order, 'offset': pos,
                'filter': {k:v for k,v in query.items() if k not in ('cursor','limit','order')}}).encode()).decode().rstrip('=')
        cursors = {}
        if offset+limit < len(ordered):
            cursors['next'] = make(offset+limit)
        if offset:
            cursors['previous'] = make(max(0,offset-limit))
        return {'data': ordered[offset:offset+limit], 'cursor': cursors}

    def dispatch(self, op, params, query, body):
        """Return status, JSON value (None for 204). Called under lock."""
        sid = params.get('sessionID')
        session = self.session(sid) if sid else None
        directory = query.get('location[directory]', DIRECTORY)
        located = lambda data: {'location': {'directory': directory}, 'data': data}
        if op == 'server.info':
            return 200, {'version': '2.0.25', 'pid': 0, 'urls': [], 'paths': {'tmp': '/tmp/opencode-mock'}, 'capabilities': {'persistentPty': False}}
        if op == 'server.pair':
            code = secrets.token_urlsafe(16)
            self.codes[code] = self.clock()+300
            return 200, {'code': code, 'expires_in': 300}
        if op == 'server.connect':
            expiry = self.codes.pop(params['code'], 0)
            if expiry <= self.clock():
                raise APIError(401, 'UnauthorizedError', 'Pairing link expired or already used')
            return 200, {'token': self.token()}
        if op == 'location.get':
            return 200, self.location(directory)
        if op == 'location.reload':
            return 204, None
        if op == 'project.list':
            return 200, self.fixture['projects']
        if op == 'project.update':
            p = next((x for x in self.fixture['projects'] if x['id'] == params['projectID']), None)
            if not p:
                raise APIError(404, 'ProjectNotFoundError', 'Project not found', projectID=params['projectID'])
            p.update(body)
            return 200, p
        if op == 'session.list':
            items = list(self.sessions.values())
            for key, field in [('directory', 'location'), ('project', 'projectID'), ('parentID', 'parentID')]:
                if key in query:
                    target = None if query[key] == 'null' else query[key]
                    items = [s for s in items if (s['location']['directory'] if field == 'location' else s.get(field)) == target]
            if query.get('search'):
                items = [s for s in items if query['search'].casefold() in s.get('title','').casefold()]
            return 200, self.page(items, query, 'sessions')
        if op in ('session.create', 'session.fork'):
            loc = body.get('location', session['location'] if session else {'directory': DIRECTORY})
            info = self.location(loc['directory'])
            new = {'id': body.get('id') or self.new_id('ses_'), 'projectID': info['project']['id'], 'location': loc,
                   'title': body.get('title', 'New session'), 'agent': body.get('agent', 'build'), 'model': body.get('model', MODEL),
                   'tokens': {k: 0 for k in ('input','output','reasoning')}, 'cost': 0,
                   'time': {'created': self.now(), 'updated': self.now()}}
            new['tokens']['cache'] = {'read': 0, 'write': 0}
            if new['id'] in self.sessions:
                raise APIError(409, 'ConflictError', 'Synthetic session ID already exists')
            if body.get('parentID'):
                parent = self.session(body['parentID'])
                new.update(parentID=parent['id'], location=parent['location'], projectID=parent['projectID'])
            if op == 'session.fork':
                new['parentID'] = sid
                new['title'] = session.get('title','Session')+' (fork)'
            self.sessions[new['id']] = new
            copied = copy.deepcopy(self.messages[sid]) if op == 'session.fork' else []
            if body.get('before'):
                index = next((i for i,m in enumerate(copied) if m['id'] == body['before']), None)
                if index is None:
                    raise APIError(404, 'MessageNotFoundError', 'Message not found', messageID=body['before'])
                copied = copied[:index]
            self.messages[new['id']] = copied
            return 200, {'data': new}
        if op == 'session.active':
            return 200, {'data': {x: {'type':'running'} for x in self.active}}
        if op == 'session.get':
            return 200, {'data': session}
        if op == 'session.remove':
            removed = {sid}
            while True:
                children = {s['id'] for s in self.sessions.values() if s.get('parentID') in removed}
                if children <= removed:
                    break
                removed |= children
            for key in removed:
                self.sessions.pop(key, None)
                self.messages.pop(key, None)
                self.active.discard(key)
            return 204, None
        if op == 'session.update':
            session.update(body)
            return 204, None
        if op in ('session.switchAgent','session.switchModel'):
            session.update(body)
            return 204, None
        if op == 'session.view':
            session['time']['viewed'] = body['idle']
            return 204, None
        if op == 'session.message.list':
            items = self.messages[sid]
            if query.get('type'):
                items = [m for m in items if m['type'] == query['type']]
            return 200, self.page(items, query, sid)
        if op == 'session.context':
            return 200, {'data': self.messages[sid]}
        if op == 'session.message.get':
            message = next((m for m in self.messages[sid] if m['id'] == params['messageID']), None)
            if message is None:
                raise APIError(404, 'MessageNotFoundError', 'Message not found', messageID=params['messageID'])
            return 200, {'data': message}
        if op == 'experimental.session.export':
            return 200, {'data': {'info': session, 'messages': self.messages[sid]}}
        if op == 'session.prompt':
            mid = body.get('id') or self.new_id('msg_')
            if any(m['id'] == mid for m in self.messages[sid]) or any(m['id'] == mid for m in self.inbox.get(sid, [])):
                raise APIError(409, 'ConflictError', 'Input ID already admitted')
            item = {'id': mid, 'type': 'user', 'sessionID': sid, 'time': {'created': self.now()},
                    'payload': {k:v for k,v in body.items() if k in ('text','agents','metadata')}, 'delivery': body.get('delivery') or 'steer'}
            if body.get('files'):
                item['payload']['files'] = []
                for file in body['files']:
                    uri = file['uri']
                    if uri.startswith('data:') and ';base64,' in uri:
                        header, data = uri.split(';base64,',1)
                        mime = header[5:]
                        try:
                            base64.b64decode(data,validate=True)
                        except ValueError:
                            raise APIError(400,'InvalidRequestError','Invalid inline base64')
                        source = {'type':'inline'}
                    elif uri.startswith('file://'):
                        path = unquote(urlsplit(uri).path)
                        if path not in self.files:
                            raise APIError(400,'InvalidRequestError','Staged attachment not found')
                        data = base64.b64encode(self.files[path]).decode()
                        mime = mimetypes.guess_type(path)[0] or 'application/octet-stream'
                        source = {'type':'uri','uri':uri}
                    else:
                        raise APIError(400,'InvalidRequestError','Mock supports data: and staged file: attachments only')
                    item['payload']['files'].append(dict(data=data,mime=mime,source=source,**{k:v for k,v in file.items() if k != 'uri'}))
            self.inbox.setdefault(sid, []).append(item)
            scenario, self.next_scenario = self.next_scenario, 'normal'
            # The mock does not simulate every inbox boundary; real server remains authoritative for steering timing.
            self.emit('session.inbox.enqueued', {'sessionID': sid, 'inboxID': mid, 'item': item}, sid, True)
            if body.get('resume', True) and sid not in self.active:
                self.start(sid, item, scenario)
            return 200, {'data': item}
        if op == 'session.inbox.list':
            return 200, {'data': self.inbox.get(sid, [])}
        if op in ('session.inbox.cancel', 'session.inbox.update'):
            items = self.inbox.get(sid, [])
            item = next((x for x in items if x['id'] == params['inboxID']), None)
            if item and op.endswith('cancel'):
                items.remove(item)
            elif item:
                item['delivery'] = body['delivery']
            return 204, None
        if op == 'session.interrupt':
            interrupted = sid in self.active
            if interrupted:
                self.runs[sid] = self.runs.get(sid, 0)+1
                self.finish(sid, 'interrupted')
            return 200, {'interrupted': interrupted}
        if op in ('session.command', 'experimental.session.skill'):
            text = f'Synthetic {op}: '+body.get('name',body.get('id',''))+' '+body.get('text','')
            self.dispatch('session.prompt',{'sessionID':sid},{},{'text':text})
            return 204, None  # Synthetic transcript only; never execute real callbacks/tools.
        if op == 'session.compact':
            return 200, {'data': {'id': body.get('id') or self.new_id('msg_'), 'sessionID': sid, 'type': 'compaction',
                                 'time': {'created': self.now()}, 'payload': {}, 'delivery': body.get('delivery') or 'steer'}}
        if op in ('session.form.list', 'form.list'):
            forms = [f for f in self.forms.values() if f['state']['status'] == 'pending' and (not sid or f['sessionID'] == sid)]
            data = [{k:v for k,v in f.items() if k != 'state'} for f in forms]
            return 200, {'data': data} if sid else located(data)
        if op in ('session.form.get','session.form.reply','session.form.cancel'):
            fid = params['formID']
            form = self.forms.get(fid)
            if not form or form['sessionID'] != sid:
                raise APIError(404, 'FormNotFoundError', 'Form not found', id=fid)
            if op == 'session.form.get':
                return 200, {'data': form}
            if form['state']['status'] != 'pending':
                raise APIError(409, 'FormAlreadySettledError', 'Form already settled', id=fid)
            if op == 'session.form.reply':
                if not valid_answer(form, body['answer']):
                    raise APIError(400, 'FormInvalidAnswerError', 'Answer fails synthetic field validation', id=fid)
                form['state'] = {'status':'answered', 'answer': body['answer']}
                self.emit('form.replied', {'id': fid, 'sessionID': sid, 'answer': body['answer']}, sid)
            else:
                form['state'] = {'status':'cancelled', **({'message':query['message']} if 'message' in query else {})}
                self.emit('form.cancelled', {'id': fid, 'sessionID': sid}, sid)
            if sid in self.active:
                self.finish(sid, 'succeeded')
            return 204, None
        if op in ('session.permission.list', 'permission.request.list'):
            data = [p for p in self.permissions.values() if not sid or p['sessionID'] == sid]
            return 200, {'data':data} if sid else located(data)
        if op in ('session.permission.get', 'session.permission.reply'):
            rid = params['requestID']
            p = self.permissions.get(rid)
            if not p or p['sessionID'] != sid:
                raise APIError(404, 'PermissionNotFoundError', 'Permission not found', requestID=rid)
            if op.endswith('.get'):
                return 200, {'data':p}
            self.permissions.pop(rid)
            self.emit('permission.replied', {'sessionID': sid, 'requestID': rid, 'reply': body['decision']}, sid)
            if sid in self.active:
                self.finish(sid, 'interrupted' if body['decision'] == 'reject' else 'succeeded')
            return 204, None
        if op == 'permission.saved.list':
            return 200, {'data': []}
        if op == 'permission.saved.remove':
            return 204, None
        lists = {'model.list':'models','agent.list':'agents','command.list':'commands','skill.list':'skills','plugin.list':'plugins','mcp.list':'mcp'}
        if op in lists:
            data = copy.deepcopy(self.fixture[lists[op]])
            if op == 'plugin.list':
                cfg = jsonc(self.files.get(directory+'/opencode.jsonc', b'{}').decode())
                disabled = {x[1:] for x in cfg.get('plugins',[]) if isinstance(x,str) and x.startswith('-')}
                data = [p for p in data if p.get('id') not in disabled]
            return 200, located(data)
        if op == 'model.default':
            return 200, located(self.fixture['models'][0])
        if op == 'agent.get':
            agent = next((a for a in self.fixture['agents'] if a['id'] == params['agentID']), None)
            if not agent:
                raise APIError(404, 'AgentNotFoundError', 'Agent not found', agentID=params['agentID'])
            return 200, located(agent)
        if op in ('experimental.mcp.connect','experimental.mcp.disconnect'):
            server = next((m for m in self.fixture['mcp'] if m['name'] == params['server']), None)
            if not server:
                raise APIError(404, 'McpServerNotFoundError', 'MCP server not found', server=params['server'])
            server['status'] = {'status': 'connected' if op.endswith('.connect') else 'disabled'}
            return 204, None
        if op == 'config.get':
            path = directory+'/opencode.jsonc'
            return 200, [{'type':'document', 'path':path, 'info':jsonc(self.files.get(path,b'{}').decode())}]
        if op == 'fs.list':
            target = posixpath.normpath(posixpath.join(directory, query.get('path','.')))
            children = {}
            for path in self.files:
                if path.startswith(target.rstrip('/')+'/'):
                    rest = path[len(target.rstrip('/'))+1:]
                    child = rest.split('/')[0]
                    children[child] = {'path':posixpath.relpath(target+'/'+child,directory),'type':'directory' if '/' in rest else 'file'}
            return 200, located(list(children.values()))
        if op == 'fs.find':
            term = query.get('query','').casefold()
            data = [{'path':posixpath.relpath(p,directory),'type':'file'} for p in self.files if p.startswith(directory+'/') and term in p.casefold()]
            if query.get('type') == 'directory':
                data = []
            return 200, located(data[:int(query.get('limit', 50))])
        if op == 'experimental.fs.write':
            path = posixpath.normpath(posixpath.join(directory, query['path']))
            self.files[path] = body
            if path.endswith(('opencode.jsonc','opencode.json')):
                self.emit('config.updated', {})
            return 200, located({'path':path})
        if op in ('session.diff','vcs.diff'):
            return 200, {'data':self.fixture['diff']} if sid else located(self.fixture['diff'])
        if op == 'vcs.status':
            return 200, located([{k:v for k,v in d.items() if k != 'patch'} for d in self.fixture['diff']])
        if op == 'vcs.get':
            return 200, located({'provider':'git','branch':{'current':'demo-feature','default':'main'}})
        if op == 'vcs.base':
            return 200, located(None)
        raise APIError(501, 'MockNotImplemented', f'{op} is not behaviorally modelled')


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *_):
        pass  # Pairing URLs and credentials must not enter access logs.

    def send_data(self, status, data=None, headers=None, raw=None):
        payload = raw if raw is not None else (b'' if data is None else json.dumps(data, ensure_ascii=False, allow_nan=False).encode())
        self.send_response(status)
        self.send_header('Content-Type', 'application/json' if raw is None else 'application/octet-stream')
        self.send_header('Content-Length', str(len(payload)))
        self.send_header('X-OpenCode-Mock', 'synthetic-v2.0.25')
        for k,v in (headers or {}).items():
            self.send_header(k,v)
        self.end_headers()
        if payload:
            self.wfile.write(payload)

    def handle_api(self):
        state = self.server.state
        split = urlsplit(self.path)
        query = {k:v[0] for k,v in parse_qs(split.query, keep_blank_values=True).items()}
        try:
            length = int(self.headers.get('Content-Length','0'))
            if length < 0 or length > 64*1024*1024:
                self.close_connection = True
                raise APIError(400,'InvalidRequestError','Mock request limit is 64 MiB')
            raw = self.rfile.read(length)
            if split.path.startswith('/__mock/'):
                return self.control(split.path, raw)
            operation, params = match(self.command, split.path)
            params = {k:unquote(v) for k,v in params.items()}
            if not operation:
                raise APIError(404,'MockRouteNotFound','Not a pinned OpenCode route')
            op = operation['operationId']
            with state.lock:
                if op != 'server.connect' and not state.authorized(self.headers.get('Authorization',''), self.headers.get('Cookie','')):
                    self.send_data(401, {'_tag':'UnauthorizedError','message':'Authentication required'}, {'WWW-Authenticate':'Basic realm="Secure Area"'})
                    return
            if op not in MODELED:
                raise APIError(501,'MockNotImplemented',f'{op} is defined upstream but not behaviorally modelled')
            body = None
            content = operation.get('requestBody',{}).get('content',{})
            if 'application/json' in content:
                try:
                    body = json.loads(raw)
                except (ValueError, UnicodeError):
                    raise APIError(400,'InvalidRequestError','Invalid JSON body')
                validate(body, content['application/json']['schema'])
            elif content:
                body = raw
            for param in operation.get('parameters',[]):
                name, where = param['name'], param['in']
                value = params.get(name) if where == 'path' else query.get(name)
                if name == 'location':
                    value = {'directory':query['location[directory]']} if 'location[directory]' in query else None
                if value is None:
                    if param.get('required'):
                        raise Invalid(f'Missing {where} parameter {name}')
                    continue
                validate(value, param['schema'])
            if op == 'event.subscribe':
                return self.stream()
            if op == 'fs.read':
                return self.read_file(params['wildcard'], query)
            scenario = state.next_scenario
            if state.latency_ms:
                time.sleep(state.latency_ms/1000)
            with state.lock:
                status, result = state.dispatch(op, params, query, body)
                schema = response_schema(operation,status)
                if schema:
                    try:
                        validate(result,schema)
                    except Invalid as error:
                        raise APIError(500,'MockContractViolation',str(error))
                state.request_log.append({'operation':op,'status':status})
                snapshot = copy.deepcopy(result)
            if op == 'session.prompt' and scenario == 'timeout-after-commit':
                # Admission succeeded; close before a response to exercise uncertain-outcome reconciliation.
                self.close_connection = True
                return
            if op == 'server.connect' and 'text/html' in self.headers.get('Accept',''):
                self.send_data(302, headers={'Location':'/','Set-Cookie':f'opencode_session_{self.server.server_port}={snapshot["token"]}; Path=/; HttpOnly; SameSite=Lax; Max-Age=2592000'})
                return
            self.send_data(status,snapshot)
        except APIError as error:
            self.send_data(error.status,error.body)
        except Invalid as error:
            self.send_data(400,{'_tag':'InvalidRequestError','message':str(error)})
        except (ValueError, KeyError, TypeError) as error:
            self.send_data(500,{'_tag':'MockInvariantError','message':str(error)})
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True

    def control(self, path, raw):
        if self.headers.get('X-Mock-Control') != self.server.control_key:
            self.send_data(403,{'mockError':'Mock control key required'})
            return
        state = self.server.state
        if path == '/__mock/status' and self.command == 'GET':
            with state.lock:
                self.send_data(200,{'synthetic':True,'seed':state.seed,'scenario':state.next_scenario,'requests':state.request_log[-100:],
                                    'modeledOperations':sorted(MODELED),'events':copy.deepcopy(state.events[-100:])})
            return
        if self.command != 'POST':
            self.send_data(405,{'mockError':'POST required'})
            return
        body = json.loads(raw or b'{}')
        with state.lock:
            if path == '/__mock/reset':
                state.reset()
            elif path == '/__mock/scenario':
                if body.get('name') not in SCENARIOS:
                    self.send_data(400,{'mockError':'Unknown scenario','allowed':sorted(SCENARIOS)})
                    return
                state.next_scenario = body['name']
            elif path == '/__mock/latency':
                state.latency_ms = max(0,min(int(body.get('milliseconds',0)),5000))
            elif path == '/__mock/password':
                state.password = str(body['password'])
            elif path == '/__mock/disconnect':
                for q in state.subscribers:
                    q.put_nowait(None)
                state.subscribers.clear()
            elif path == '/__mock/emit':
                kind = body['type']
                if not kind.startswith('rpc.demo.'):
                    self.send_data(400,{'mockError':'Only synthetic rpc.demo.* injections permitted'})
                    return
                state.emit(kind,body.get('data',{}))
            else:
                self.send_data(404,{'mockError':'Unknown control'})
                return
        self.send_data(200,{'ok':True})

    def read_file(self, path, query):
        state = self.server.state
        directory = query.get('location[directory]',DIRECTORY)
        target = posixpath.normpath(posixpath.join(directory,path))
        with state.lock:
            data = state.files.get(target)
        if data is None:
            raise APIError(404,'FileNotFoundError','Synthetic file not found',path=target)
        etag = '"'+hashlib.sha256(data).hexdigest()+'"'
        headers = {'ETag':etag,'Accept-Ranges':'bytes'}
        if self.headers.get('If-None-Match') == etag:
            self.send_data(304,headers=headers)
            return
        value = self.headers.get('Range','')
        ranged = re.fullmatch(r'bytes=(\d*)-(\d*)',value)
        status = 200
        if ranged and any(ranged.groups()):
            a,b = ranged.groups()
            start = int(a) if a else max(0,len(data)-int(b))
            end = min(int(b),len(data)-1) if a and b else len(data)-1
            if start >= len(data) or start > end or (not a and int(b) == 0):
                self.send_data(416,headers=dict(headers,**{'Content-Range':f'bytes */{len(data)}'}))
                return
            headers['Content-Range'] = f'bytes {start}-{end}/{len(data)}'
            data, status = data[start:end+1],206
        self.send_data(status,headers=headers,raw=data)

    def stream(self):
        state = self.server.state
        q = queue.Queue(maxsize=4096)
        with state.lock:
            state.subscribers.add(q)
            connected = {'id':state.new_id('evt_'),'type':'server.connected','data':{}}
        self.send_response(200)
        self.send_header('Content-Type','text/event-stream')
        self.send_header('Cache-Control','no-cache, no-transform')
        self.send_header('Connection','close')
        self.end_headers()
        try:
            self.wfile.write(('data: '+json.dumps(connected)+'\n\n').encode())
            self.wfile.flush()
            while True:
                try:
                    event = q.get(timeout=15)
                    if event is None:
                        break
                    self.wfile.write(('data: '+json.dumps(event)+'\n\n').encode())
                except queue.Empty:
                    self.wfile.write(b': heartbeat\n\n')
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            with state.lock:
                state.subscribers.discard(q)
            self.close_connection = True

    do_GET = do_POST = do_PATCH = do_PUT = do_DELETE = handle_api


def make_server(host='127.0.0.1',port=4097,seed=25,password='mock-password',control_key='mock-control'):
    server = ThreadingHTTPServer((host,port),Handler)
    server.daemon_threads = True
    server.state = State(seed,password)
    server.control_key = control_key
    return server


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host',default='127.0.0.1')
    parser.add_argument('--port',type=int,default=4097)
    parser.add_argument('--seed',type=int,default=25)
    parser.add_argument('--password',default='mock-password')
    parser.add_argument('--control-key',default='mock-control')
    parser.add_argument('--tls-cert')
    parser.add_argument('--tls-key')
    args = parser.parse_args()
    if bool(args.tls_cert) != bool(args.tls_key):
        parser.error('Provide both --tls-cert and --tls-key')
    server = make_server(args.host,args.port,args.seed,args.password,args.control_key)
    if args.tls_cert:
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(args.tls_cert,args.tls_key)
        server.socket = ctx.wrap_socket(server.socket,server_side=True)
    print(f'Synthetic OpenCode v2.0.25 mock on {args.host}:{server.server_port}; no real tools/providers',flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == '__main__':
    main()
