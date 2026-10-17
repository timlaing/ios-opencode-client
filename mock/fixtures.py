# SPDX-License-Identifier: MPL-2.0
"""Deterministic, fictional fixtures. No captured user/server data."""
import base64
import copy
import json
import random
from .contract import ROOT, SCHEMAS, sample

BASE_TIME = 1792195200000  # Fixed synthetic epoch milliseconds, not a live clock.
DIRECTORY = '/srv/demo/harbour'
MODEL = {'id': 'demo-code', 'providerID': 'synthetic'}
TOKENS = {'input': 1200, 'output': 350, 'reasoning': 100, 'cache': {'read': 200, 'write': 0}}
RICH_TEXT = '''# Review complete

**Generated test content** with *emphasis*, ~~removed text~~, and `inline code`.

| File | Result |
| --- | --- |
| `src/main.py` | Updated |
| `tests/test_main.py` | Passed |

- [x] Inspect the change (Markdown checkbox, not an agent todo)
- [ ] Run the device test

> This is synthetic data, safe for screenshots and review.

```python
def greet(name: str) -> str:
    return f"Hello, {name}!"
```

```mermaid
flowchart LR
  A[Prompt] --> B[Review] --> C[Complete]
```

[External link](https://example.com/docs)
![Tap to load external image](https://example.com/synthetic-diagram.png)

Unicode: café · 日本語 · مرحبا · 👩🏽‍💻
'''


def sample_pdf():
    stream = b'BT /F1 18 Tf 30 100 Td (Generated OpenCode demo PDF) Tj ET'
    objects = [b'<< /Type /Catalog /Pages 2 0 R >>',
               b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
               b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 360 180] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
               b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
               b'<< /Length '+str(len(stream)).encode()+b' >>\nstream\n'+stream+b'\nendstream']
    result, offsets = b'%PDF-1.4\n', [0]
    for i,obj in enumerate(objects,1):
        offsets.append(len(result))
        result += str(i).encode()+b' 0 obj\n'+obj+b'\nendobj\n'
    start = len(result)
    result += b'xref\n0 6\n0000000000 65535 f \n'
    result += b''.join(f'{offset:010d} 00000 n \n'.encode() for offset in offsets[1:])
    result += b'trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n'+str(start).encode()+b'\n%%EOF\n'
    return result


def generate(seed=25, long_count=120):
    rng = random.Random(seed)
    project = {'id': 'project_harbour', 'canonical': DIRECTORY, 'name': 'Harbour Demo',
               'time': {'created': BASE_TIME, 'updated': BASE_TIME, 'active': BASE_TIME}, 'sandboxes': []}
    other = dict(project, id='project_orbit', canonical='/srv/demo/orbit', name='Orbit Demo')
    sessions, messages = {}, {}
    for i, title in enumerate(['Review Markdown and changes', 'Waiting for approval', 'Choose a deployment target',
                               'Provider retry', 'Failed execution', 'Long conversation', 'Empty session', 'Queued prompts']):
        sid = f'ses_demo_{i+1:03d}'
        sessions[sid] = {'id': sid, 'projectID': project['id'], 'title': title, 'agent': 'build', 'model': MODEL,
                         'cost': 0.0125, 'tokens': copy.deepcopy(TOKENS),
                         'time': {'created': BASE_TIME + i*1000, 'updated': BASE_TIME+i*1000},
                         'location': {'directory': DIRECTORY}}
        messages[sid] = [] if i == 6 else [
            {'id': f'msg_user_{i}', 'type': 'user', 'time': {'created': BASE_TIME+i*1000},
             'text': 'Please review **this project** and explain the changes.'},
            {'id': f'msg_assistant_{i}', 'type': 'assistant', 'agent': 'build', 'model': MODEL,
             'time': {'created': BASE_TIME+i*1000+1, 'completed': BASE_TIME+i*1000+100},
             'content': [{'type': 'reasoning', 'text': 'Inspecting the supplied synthetic project.'},
                         {'type': 'tool', 'id': f'tool_{i}', 'name': 'read',
                          'time': {'created': BASE_TIME+i*1000+2, 'completed': BASE_TIME+i*1000+3},
                          'state': {'status': 'completed', 'input': {'path': 'src/main.py'},
                                    'content': [{'type': 'text', 'text': 'Synthetic file read.'}]}},
                         {'type': 'text', 'text': RICH_TEXT}], 'finish': 'stop', 'tokens': TOKENS, 'cost': 0.0125},
            {'id': f'msg_idle_{i}', 'type': 'idle', 'time': {'created': BASE_TIME+i*1000+101}, 'outcome': 'succeeded'}]
    messages['ses_demo_006'] = [
        {'id': f'msg_long_{i:04d}', 'type': 'user', 'time': {'created': BASE_TIME+i},
         'text': f'Generated message {i}: {rng.randrange(100000)}'} for i in range(long_count)]
    sessions['ses_demo_005']['outcome'] = 'failed'
    sessions['ses_demo_005']['time']['idle'] = BASE_TIME+5000
    messages['ses_demo_005'][-1]['outcome'] = 'failed'
    messages['ses_demo_005'][1]['error'] = {'type': 'provider.synthetic', 'message': 'Generated provider failure', 'status': 503}
    messages['ses_demo_004'][1].pop('finish', None)
    for sid in ('ses_demo_002','ses_demo_003','ses_demo_004'):
        if messages[sid][-1]['type'] == 'idle':
            messages[sid].pop()
        messages[sid][1].pop('finish',None)
        messages[sid][1]['time'].pop('completed',None)
    messages['ses_demo_004'][1]['retry'] = {'attempt': 1, 'at': BASE_TIME+60000, 'error': {'type': 'provider.synthetic', 'message': 'Generated retry'}}
    model = sample(SCHEMAS['Model.Info'])
    model.update(id='demo-code', modelID='demo-code', providerID='synthetic', name='Demo Code (synthetic)',
                 capabilities={'tools': True, 'input': ['text', 'image', 'pdf'], 'output': ['text']},
                 status='active', enabled=True, limit={'context': 128000, 'output': 8192},
                 cost=[{'input': 1, 'output': 2, 'cache': {'read': 0.1, 'write': 0.2}}])
    agent = sample(SCHEMAS['Agent.Info'])
    agent.update(id='build', name='Build', description='Synthetic development agent', mode='primary', hidden=False)
    permission = {'id': 'per_demo', 'sessionID': 'ses_demo_002', 'action': 'shell',
                  'resources': ['python3 -m unittest'], 'save': ['python3 -m unittest*'],
                  'message': 'Run the generated test suite?'}
    form = {'id': 'frm_demo', 'sessionID': 'ses_demo_003', 'title': 'Choose deployment options', 'fields': [
        {'key': 'environment', 'type': 'string', 'title': 'Environment', 'required': True,
         'options': [{'value': 'staging', 'label': 'Staging'}, {'value': 'production', 'label': 'Production'}]},
        {'key': 'checks', 'type': 'multiselect', 'title': 'Checks', 'minItems': 1,
         'options': [{'value': 'unit', 'label': 'Unit tests'}, {'value': 'device', 'label': 'Device tests'}]},
        {'key': 'confirm', 'type': 'boolean', 'required': True,
         'when': [{'key': 'environment', 'op': 'eq', 'value': 'production'}]},
        {'key': 'notes', 'type': 'string', 'maxLength': 200},
        {'key': 'replicas', 'type': 'integer', 'minimum': 1, 'maximum': 5, 'default': 1},
        {'key': 'reference', 'type': 'external', 'title': 'Deployment guide', 'url': 'https://example.com/deploy'}]}
    files = {DIRECTORY+'/README.md': RICH_TEXT, DIRECTORY+'/src/main.py': 'def greet(name):\n    return f"Hello, {name}!"\n',
             DIRECTORY+'/tests/test_main.py': 'assert True\n',
             DIRECTORY+'/opencode.jsonc': '// Preserve this comment\n{\n  "plugins": ["demo.audit"],\n  "mcp": {}\n}\n',
             DIRECTORY+'/large.txt': ''.join(f'Line {i}\n' for i in range(12000))}
    return {'seed': seed, 'projects': [project, other], 'sessions': sessions, 'messages': messages,
            'active': ['ses_demo_002','ses_demo_003','ses_demo_004'],
            'models': [model], 'agents': [agent], 'permissions': [permission], 'forms': [form],
            'mcp': [{'name': 'demo-docs', 'status': {'status': 'connected'}},
                    {'name': 'demo-auth', 'status': {'status': 'needs_auth', 'error': 'Synthetic sign-in required'}}],
            'plugins': [{'id': 'demo.audit', 'source': {'type': 'package', 'target': 'demo.audit', 'version': '1.0.0'},
                         'features': {'server': True}, 'state': {'status': 'active'}}],
            'diff': [{'file': 'src/main.py', 'patch': '--- a/src/main.py\n+++ b/src/main.py\n@@ -1 +1 @@\n-print("Hello")\n+print("Hello, world!")\n',
                      'additions': 1, 'deletions': 1, 'status': 'modified'}],
            'files': files,
            'binary': {DIRECTORY+'/sample.png': 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a3ioAAAAASUVORK5CYII=',
                       DIRECTORY+'/sample.pdf': base64.b64encode(sample_pdf()).decode()},
            'commands': [{'name': 'review', 'description': 'Synthetic review command'}],
            'skills': [{'id': 'demo-review', 'name': 'Demo review', 'path': DIRECTORY+'/.opencode/skills/review.md', 'content': 'Review generated files only.'}]}


if __name__ == '__main__':
    path = ROOT/'fixtures/generated/demo.json'
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(generate(), ensure_ascii=False, indent=2)+'\n')
    print(path)
