# SPDX-License-Identifier: MPL-2.0
"""Pinned route matching and a dependency-free guard for snapshot schema keywords.

This is not a general JSON Schema implementation. assert_supported checks the
vendored schema vocabulary, so a new assertion keyword fails rather than being
silently ignored. Formats/content encodings are annotations, not assertions.
"""
import copy
import json
import math
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = json.loads((ROOT / 'contracts/opencode-v2.0.25.openapi.json').read_text())
SCHEMAS = SPEC['components']['schemas']


class Invalid(ValueError):
    pass


def resolve(schema):
    if isinstance(schema, dict) and '$ref' in schema:
        return SPEC['components']['schemas'][schema['$ref'].split('/')[-1]]
    return schema


def validate(value, schema, path='$'):
    if schema is True:
        return
    if schema is False:
        raise Invalid(f'{path}: false schema')
    if '$ref' in schema:
        validate(value, resolve(schema), path)
    for mode in ('anyOf', 'oneOf', 'allOf'):
        if mode not in schema:
            continue
        count = 0
        for variant in schema[mode]:
            try:
                validate(value, variant, path)
                count += 1
            except Invalid:
                pass
        if (mode == 'anyOf' and not count) or (mode == 'oneOf' and count != 1) or (mode == 'allOf' and count != len(schema[mode])):
            raise Invalid(f'{path}: {mode} mismatch')
    if 'not' in schema:
        try:
            validate(value, schema['not'], path)
        except Invalid:
            pass
        else:
            raise Invalid(f'{path}: matches forbidden schema')
    types = {'object': lambda x: isinstance(x, dict), 'array': lambda x: isinstance(x, list),
             'string': lambda x: isinstance(x, str), 'boolean': lambda x: isinstance(x, bool),
             'null': lambda x: x is None,
             'number': lambda x: type(x) in (int, float) and math.isfinite(x),
             'integer': lambda x: type(x) in (int, float) and math.isfinite(x) and x == int(x)}
    if 'type' in schema:
        names = schema['type'] if isinstance(schema['type'], list) else [schema['type']]
        if not any(types[name](value) for name in names):
            raise Invalid(f'{path}: expected {names}')
    if 'enum' in schema and not any(type(value) is type(x) and value == x for x in schema['enum']):
        raise Invalid(f'{path}: invalid enum')
    if 'const' in schema and value != schema['const']:
        raise Invalid(f'{path}: invalid const')
    if isinstance(value, dict):
        if any(k not in value for k in schema.get('required', [])):
            raise Invalid(f'{path}: missing required field')
        props = schema.get('properties', {})
        for key, child in value.items():
            matched = False
            if key in props:
                validate(child, props[key], f'{path}.{key}')
                matched = True
            for pattern, sub in schema.get('patternProperties', {}).items():
                if re.search(pattern, key):
                    validate(child, sub, f'{path}.{key}')
                    matched = True
            if not matched:
                validate(child, schema.get('additionalProperties', True), f'{path}.{key}')
    if isinstance(value, list):
        if len(value) < schema.get('minItems', 0) or len(value) > schema.get('maxItems', math.inf):
            raise Invalid(f'{path}: array length')
        prefix = schema.get('prefixItems', [])
        for i, child in enumerate(value):
            validate(child, prefix[i] if i < len(prefix) else schema.get('items', True), f'{path}[{i}]')
        if schema.get('uniqueItems') and len({json.dumps(x, sort_keys=True) for x in value}) != len(value):
            raise Invalid(f'{path}: duplicate array item')
    if isinstance(value, str):
        if len(value) < schema.get('minLength', 0) or len(value) > schema.get('maxLength', math.inf):
            raise Invalid(f'{path}: string length')
        if 'pattern' in schema and not re.search(schema['pattern'], value):
            raise Invalid(f'{path}: pattern mismatch')
    if type(value) in (int, float):
        for key, invalid in [('minimum', lambda n: value < n), ('maximum', lambda n: value > n),
                             ('exclusiveMinimum', lambda n: value <= n), ('exclusiveMaximum', lambda n: value >= n)]:
            if key in schema and invalid(schema[key]):
                raise Invalid(f'{path}: {key}')


def assert_supported(schema):
    allowed = {'$ref', 'type', 'properties', 'patternProperties', 'required', 'additionalProperties', 'anyOf', 'oneOf', 'allOf',
               'not', 'enum', 'const', 'items', 'prefixItems', 'minItems', 'maxItems', 'uniqueItems',
               'minLength', 'maxLength', 'pattern', 'minimum', 'maximum', 'exclusiveMinimum', 'exclusiveMaximum',
               'description', 'title', 'default', 'format', 'contentMediaType', 'contentEncoding', 'examples', 'example',
               'readOnly', 'writeOnly', 'deprecated', '$schema'}
    if isinstance(schema, bool):
        return
    unknown = set(schema) - allowed
    if unknown:
        raise Invalid(f'Unsupported schema keywords: {sorted(unknown)}')
    for key in ('properties', 'patternProperties'):
        for child in schema.get(key, {}).values():
            assert_supported(child)
    for key in ('anyOf', 'oneOf', 'allOf', 'prefixItems'):
        for child in schema.get(key, []):
            assert_supported(child)
    for key in ('additionalProperties', 'items', 'not'):
        if key in schema:
            assert_supported(schema[key])


def sample(schema):
    schema = resolve(schema)
    if 'enum' in schema:
        return copy.deepcopy(schema['enum'][0])
    if 'anyOf' in schema or 'oneOf' in schema:
        return sample(schema.get('anyOf', schema.get('oneOf'))[0])
    kind = schema.get('type')
    if kind == 'object':
        return {k: sample(schema['properties'][k]) for k in schema.get('required', [])}
    if kind == 'array':
        return [sample(schema.get('prefixItems', [schema.get('items', {})])[0]) for _ in range(schema.get('minItems', 0))]
    if kind == 'string':
        pattern = schema.get('pattern', '')
        if pattern.startswith('^') and re.fullmatch(r'[A-Za-z_]+', pattern[1:]):
            return pattern[1:] + 'synthetic'
        return ''
    if kind in ('integer', 'number'):
        return max(0, schema.get('minimum', 0), schema.get('exclusiveMinimum', -1) + 1)
    if kind == 'boolean':
        return False
    if kind == 'null':
        return None
    return {}


OPERATIONS = {}
ROUTES = []
for template, methods in SPEC['paths'].items():
    for method, operation in methods.items():
        if method not in ('get', 'post', 'put', 'patch', 'delete'):
            continue
        operation = dict(operation, method=method.upper(), path=template)
        OPERATIONS[operation['operationId']] = operation
        pattern = re.escape(template)
        pattern = re.sub(r'\\\{(\w+)\\\}', r'(?P<\1>[^/]+)', pattern)
        pattern = pattern.replace(r'\*', '(?P<wildcard>.*)')
        ROUTES.append((re.compile('^' + pattern + '$'), operation))
ROUTES.sort(key=lambda item: ('{' in item[1]['path'] or '*' in item[1]['path'], -len(item[1]['path'])))


def match(method, path):
    for pattern, operation in ROUTES:
        result = pattern.fullmatch(path)
        if result and operation['method'] == method:
            return operation, result.groupdict()
    return None, {}


def response_schema(operation, status=200):
    return operation['responses'].get(str(status), {}).get('content', {}).get('application/json', {}).get('schema')


def validate_event(event):
    """Check the explicitly modelled event subset against pinned TS definitions.

    OpenAPI encodes V2Event as a JSON string and does not expose its decoded
    object union. This subset guard is derived from schema/event.ts,
    session-event.ts, session-status-event.ts, permission.ts, form.ts, config.ts.
    """
    kind = event['type']
    if not re.fullmatch(r'evt_.+', event['id']):
        raise Invalid('event ID')
    if kind == 'server.connected':
        validate(event['data'],{'type':'object','additionalProperties':False})
        return
    if type(event.get('created')) not in (int,float):
        raise Invalid('event created timestamp')
    ref = lambda name: {'$ref':'#/components/schemas/'+name}
    string = {'type':'string'}
    sid = {'sessionID':{'type':'string','pattern':'^ses'}}
    assistant = dict(sid, assistantMessageID={'type':'string','pattern':'^msg_'})
    ordinal = dict(assistant, ordinal={'type':'integer','minimum':0})
    data, durable, version = event['data'], False, 1
    if kind.startswith('rpc.'):
        validate(event.get('location'),ref('Location.PublicRef'))
        validate(data,{'type':'object'})
        return
    props = None
    if kind in ('session.execution.started','session.execution.succeeded'):
        props, durable = sid,True
    elif kind == 'session.execution.failed':
        props, durable = dict(sid,error=ref('Session.StructuredError')),True
    elif kind == 'session.execution.interrupted':
        props, durable = dict(sid,reason={'enum':['user','shutdown','superseded','inactivity']}),True
    elif kind == 'session.step.started':
        props, durable = dict(assistant,agent=string,model=ref('Model.Ref'),started={'type':'integer','minimum':0}),True
    elif kind == 'session.step.ended':
        props, durable = dict(assistant,finish=string,cost=ref('Money.USD'),tokens=ref('TokenUsage.Info')),True
    elif kind == 'session.step.failed':
        props, durable = dict(assistant,error=ref('Session.StructuredError')),True
    elif kind in ('session.text.started','session.reasoning.started'):
        props,durable = ordinal,True
    elif kind in ('session.text.delta','session.reasoning.delta'):
        props = dict(ordinal,delta=string)
    elif kind in ('session.text.ended','session.reasoning.ended'):
        props,durable = dict(ordinal,text=string),True
    elif kind == 'session.inbox.delivered':
        props,durable = dict(sid,inboxID={'type':'string','pattern':'^msg_'}),True
    elif kind == 'session.inbox.enqueued':
        props,durable = dict(sid,inboxID={'type':'string','pattern':'^msg_'},item=ref('Session.Inbox.User')),True
    elif kind == 'permission.asked':
        validate(data,ref('Permission.Request'))
        return
    elif kind == 'permission.replied':
        props = dict(sid,requestID=string,reply=ref('Permission.Reply'))
    elif kind == 'form.created':
        props = {'form':ref('Form.Info')}
    elif kind == 'form.replied':
        props = dict(sid,id={'type':'string','pattern':'^frm_'},answer=ref('Form.Answer'))
    elif kind == 'form.cancelled':
        props = dict(sid,id={'type':'string','pattern':'^frm_'})
    elif kind == 'config.updated':
        props = {}
    elif kind == 'session.status':
        props = dict(sid,status={'anyOf':[
            {'type':'object','properties':{'type':{'enum':['idle','busy']}},'required':['type'],'additionalProperties':False},
            {'type':'object','properties':{'type':{'enum':['retry']},'attempt':{'type':'integer','minimum':0},
             'message':string,'next':{'type':'integer','minimum':0}},'required':['type','attempt','message','next'],'additionalProperties':False}]})
    if props is None:
        raise Invalid('Event is outside the modelled subset: '+kind)
    validate(data,{'type':'object','properties':props,'required':list(props),'additionalProperties':False})
    if durable:
        validate(event.get('durable'),{'type':'object','properties':{
            'aggregateID':string,'seq':{'type':'integer','minimum':0},'version':{'enum':[version]}},
            'required':['aggregateID','seq','version'],'additionalProperties':False})
        if event['durable']['aggregateID'] != data['sessionID']:
            raise Invalid('Wrong aggregate ID')
    elif 'durable' in event:
        raise Invalid('Ephemeral event has a durable envelope')
