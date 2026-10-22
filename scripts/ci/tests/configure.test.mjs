// SPDX-License-Identifier: MPL-2.0
import assert from 'node:assert/strict';
import { generateKeyPairSync } from 'node:crypto';
import test from 'node:test';
import { configure, main, planAnalyzeActions } from '../configure_analyze.mjs';

const desired = { name: 'Analyze iOS', actionType: 'ANALYZE', platform: 'IOS', scheme: 'OpenCodeRemote', destination: 'ANY_IOS_SIMULATOR', isRequiredToPass: true };
const current = [{ name: 'Test', actionType: 'TEST', testConfiguration: { testPlan: 'plan' } }];

test('Analyze plan preserves existing actions and only appends the required action', () => {
  const planned = planAnalyzeActions(current, desired);
  assert.deepEqual(planned, [...current, desired]);
  assert.equal(current.length, 1);
  assert.deepEqual(planAnalyzeActions(planned, desired), planned);
});

test('existing matching Analyze action is made required without duplication', () => {
  const actions = [...current, { ...desired, isRequiredToPass: false }];
  assert.deepEqual(planAnalyzeActions(actions, desired), [...current, desired]);
  assert.throws(() => planAnalyzeActions([...actions, desired], desired), /Multiple/);
  assert.throws(() => planAnalyzeActions(null, desired), /missing/);
});

test('configuration preview never writes to Apple', async () => {
  const api = { get: async () => ({ data: { attributes: { actions: current } } }), fetcher: () => assert.fail('unexpected mutation') };
  assert.match(await configure(api, 'workflow', desired), /plan:/);
  api.get = async () => ({ data: { attributes: { actions: [...current, desired] } } });
  assert.equal(await configure(api, 'workflow', desired, true), 'already configured');
});

test('configuration aborts when another editor changes the workflow actions', async () => {
  let reads = 0;
  const api = { get: async () => ({ data: { attributes: { actions: ++reads === 1 ? current : [] } } }), fetcher: () => assert.fail('unexpected mutation') };
  await assert.rejects(configure(api, 'workflow', desired, true), /changed/);
});

test('applied configuration patches only actions and verifies persistence', async () => {
  const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
  let reads = 0;
  let writes = 0;
  const api = {
    env: { ASC_KEY_ID: 'key', ASC_ISSUER_ID: 'issuer', ASC_PRIVATE_KEY: privateKey.export({ type: 'pkcs8', format: 'pem' }) },
    get: async () => ({ data: { attributes: { actions: ++reads <= 2 ? current : [...current, desired] } } }),
    fetcher: async (_url, options) => {
      writes++;
      assert.equal(options.method, 'PATCH');
      assert.deepEqual(JSON.parse(options.body), { data: { type: 'ciWorkflows', id: 'workflow', attributes: { actions: [...current, desired] } } });
      return new Response('{}');
    },
  };
  assert.match(await configure(api, 'workflow', desired, true), /verified by readback/);
  assert.equal(writes, 1);
});

test('configuration CLI rejects missing inputs and unknown flags before requests', async () => {
  await assert.rejects(main({}, []), /Missing ASC_KEY_ID/);
  await assert.rejects(main({}, ['--unknown']), /Usage/);
});
