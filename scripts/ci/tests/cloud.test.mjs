// SPDX-License-Identifier: MPL-2.0
import assert from 'node:assert/strict';
import { generateKeyPairSync, verify } from 'node:crypto';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { AppleAPI, apiURL, collect, downloadArtifact, jwt, logSafe, main, matches, MAX_WAIT_SECONDS, waitForRun, waitSeconds, collectAnalysis, issueAnnotation } from '../xcode_cloud.mjs';

const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
const env = { ASC_KEY_ID: 'key', ASC_ISSUER_ID: 'issuer', ASC_PRIVATE_KEY: privateKey.export({ type: 'pkcs8', format: 'pem' }) };
const expected = { sha: 'a'.repeat(40), baseSha: '', workflow: 'workflow' };
const run = (overrides = {}) => ({ id: 'run', attributes: {
  sourceCommit: { commitSha: expected.sha }, isPullRequestBuild: false,
  executionProgress: 'COMPLETE', completionStatus: 'SUCCEEDED', ...overrides,
}, relationships: { workflow: { data: { id: 'workflow' } } } });

test('Apple JWT uses ES256/P1363 and a short, renewable lifetime', () => {
  const token = jwt(env, 1000);
  const [header, claims, signature] = token.split('.');
  assert.equal(JSON.parse(Buffer.from(header, 'base64url')).alg, 'ES256');
  assert.deepEqual(JSON.parse(Buffer.from(claims, 'base64url')), { iss: 'issuer', iat: 970, exp: 1600, aud: 'appstoreconnect-v1' });
  assert.equal(verify('sha256', Buffer.from(`${header}.${claims}`), { key: publicKey, dsaEncoding: 'ieee-p1363' }, Buffer.from(signature, 'base64url')), true);
});

test('API links cannot leak the JWT to another host', () => {
  assert.throws(() => apiURL('https://evil.example/v1/data'));
  assert.throws(() => apiURL('https://api.appstoreconnect.apple.com/other'));
});

test('pagination is complete and retries transient rate limits', async () => {
  let calls = 0;
  const api = new AppleAPI(env, async () => {
    calls++;
    if (calls === 1) return new Response('', { status: 429 });
    return Response.json({ data: [calls], links: { next: calls === 2 ? '/v1/next' : null } });
  }, async () => {});
  assert.deepEqual(await api.list('first'), [2, 3]);
});

test('pagination cycles are rejected', async () => {
  const api = new AppleAPI(env);
  api.get = async () => ({ data: [], links: { next: '/v1/first' } });
  await assert.rejects(api.list('first'), /Repeated/);
});

test('a different commit, PR mode or changed base never matches', () => {
  assert.equal(matches(run(), expected), true);
  assert.equal(matches(run(), { ...expected, sha: 'b'.repeat(40) }), false);
  assert.equal(matches(run(), { ...expected, baseSha: 'b'.repeat(40) }), false);
  const pr = run({ isPullRequestBuild: true, destinationCommit: { commitSha: 'b'.repeat(40) } });
  assert.equal(matches(pr, { ...expected, baseSha: 'b'.repeat(40) }), true);
  assert.equal(matches(pr, { ...expected, baseSha: 'c'.repeat(40) }), false);
});

test('waits for exact run then preserves failed/canceled terminal states', async () => {
  let polls = 0;
  const api = { list: async () => [run()], get: async () => ({ data: ++polls === 1 ? run({ executionProgress: 'RUNNING' }) : run({ completionStatus: 'CANCELED' }) }) };
  const result = await waitForRun(api, expected, { pause: async () => {}, timeout: 1 });
  assert.equal(result.attributes.completionStatus, 'CANCELED');
});

test('explicit run IDs must belong to configured workflow and exact SHA', async () => {
  const api = { get: async () => ({ data: run({ sourceCommit: { commitSha: 'b'.repeat(40) } }) }) };
  await assert.rejects(waitForRun(api, expected, { runId: 'other' }), /does not match/);
});

test('a missing build times out rather than reporting success', async () => {
  let now = 0;
  const api = { list: async () => [] };
  const lines = [];
  await assert.rejects(waitForRun(api, expected, {
    timeout: 1, clock: () => now, pause: async () => { now += 1000; }, emit: line => lines.push(line),
  }), /Timed out/);
  assert.match(lines.join('\n'), /newest none/);
});

test('timeouts explain which runs were seen and why they did not match', async () => {
  let now = 0;
  const wrongSha = run({ number: 12, sourceCommit: { commitSha: 'b'.repeat(40) } });
  const wrongMode = run({ number: 13, isPullRequestBuild: true });
  const api = { list: async () => [wrongSha, wrongMode] };
  const lines = [];
  await assert.rejects(waitForRun(api, expected, {
    timeout: 1, clock: () => now, pause: async () => { now += 1000; }, emit: line => lines.push(line),
  }), /Timed out/);
  const log = lines.join('\n');
  assert.match(log, /#12 b{40} source commit is b{40} but this GitHub run needs a{40}/);
  assert.match(log, /#13 a{40} pull-request build is true but this GitHub run expects false/);
});

test('a selected run that never finishes says so instead of reporting no candidates', async () => {
  let now = 0;
  const api = {
    list: async () => [run()],
    get: async () => ({ data: run({ completionStatus: 'RUNNING', executionProgress: 'RUNNING' }) }),
  };
  const lines = [];
  await assert.rejects(waitForRun(api, expected, {
    timeout: 1, clock: () => now, pause: async () => { now += 1000; }, emit: line => lines.push(line),
  }), /Timed out/);
  assert.match(lines.join('\n'), /still running; executionProgress never reached COMPLETE/);
});

test('the wait window can be tuned without editing the bridge', () => {
  assert.equal(waitSeconds({}), 4500);
  assert.equal(waitSeconds({ XCODE_CLOUD_WAIT_SECONDS: '120' }), 120);
  for (const value of ['0', '-1', 'soon']) assert.equal(waitSeconds({ XCODE_CLOUD_WAIT_SECONDS: value }), 4500);
  // An override can never outlive the 95-minute cloud job, which still needs
  // time for setup, result downloads and analysis after the wait.
  assert.equal(MAX_WAIT_SECONDS, 4800);
  assert.ok(MAX_WAIT_SECONDS < 95 * 60);
  assert.equal(waitSeconds({ XCODE_CLOUD_WAIT_SECONDS: '99999' }), MAX_WAIT_SECONDS);
});

test('logSafe flattens control characters so a value cannot forge a log line', () => {
  assert.equal(logSafe('build 17\r\n::error::forged'), 'build 17  ::error::forged');
  assert.equal(logSafe('plain'), 'plain');
  assert.equal(logSafe(17), '17');
  assert.equal(logSafe(null), '');
});

test('rejected candidates are reported as a bounded sample beside the totals', async () => {
  let now = 0;
  const stale = Array.from({ length: 25 }, (_, index) =>
    run({ number: index, sourceCommit: { commitSha: 'b'.repeat(40) } }));
  const api = { list: async () => stale };
  const lines = [];
  await assert.rejects(waitForRun(api, expected, {
    timeout: 1, clock: () => now, pause: async () => { now += 1000; }, emit: line => lines.push(line),
  }), /Timed out/);
  assert.ok(lines.length > 0);
  for (const line of lines) {
    assert.match(line, /25 of 25 scanned run\(s\) rejected/);
    assert.match(line, /and 5 older run\(s\) not listed/);
    // 20 sampled rejections plus, at most, the newest run repeated.
    const described = (line.match(/source commit is/g) || []).length;
    assert.ok(described >= 20 && described <= 21, `expected a bounded sample, got ${described}`);
  }
});

test('remote values cannot forge log lines or workflow commands', async () => {
  let now = 0;
  const hostile = run({ number: '17\r\n::error::forged', sourceCommit: { commitSha: 'b'.repeat(40) } });
  const api = { list: async () => [hostile] };
  const lines = [];
  await assert.rejects(waitForRun(api, expected, {
    timeout: 1, clock: () => now, pause: async () => { now += 1000; }, emit: line => lines.push(line),
  }), /Timed out/);
  assert.ok(lines.length > 0);
  for (const line of lines) {
    assert.equal(/[\r\n]/.test(line), false, `control characters leaked: ${JSON.stringify(line)}`);
    assert.equal(line.startsWith('::'), false, `forged workflow command: ${JSON.stringify(line)}`);
  }
});

test('all result bundles download together so collection fits the job timeout', async () => {
  const action = id => ({ id, attributes: { actionType: 'TEST', executionProgress: 'COMPLETE', completionStatus: 'SUCCEEDED' } });
  const api = {
    list: async path => path.includes('/actions?')
      ? [action('phone'), action('pad')]
      : [{ id: 'artifact', attributes: { fileType: 'RESULT_BUNDLE', downloadUrl: 'https://example.com/private' } }],
  };
  const started = [];
  let release;
  const gate = new Promise(resolve => { release = resolve; });
  const pending = collect(api, run(), '/tmp/report', (url, target) => { started.push(target); return gate; });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(started.length, 2, 'both downloads start before either finishes');
  release();
  const result = await pending;
  assert.deepEqual(result.map(entry => entry.file), ['result-0.zip', 'result-1.zip']);
  assert.equal(JSON.stringify(result).includes('private'), false);
});

test('collects all result bundles from all test actions', async () => {
  const action = id => ({ id, attributes: { actionType: 'TEST', executionProgress: 'COMPLETE', completionStatus: 'SUCCEEDED' } });
  const api = { list: async path => path.includes('/actions?') ? [action('phone'), action('pad')] : [{ id: 'artifact', attributes: { fileType: 'RESULT_BUNDLE', downloadUrl: 'https://example.com/private' } }] };
  const downloads = [];
  const result = await collect(api, run(), '/tmp/report', async (...args) => downloads.push(args));
  assert.equal(result.length, 2);
  assert.equal(downloads.length, 2);
  assert.equal(JSON.stringify(result).includes('private'), false);
});

test('successful workflow without tests or missing result bundles is rejected', async () => {
  await assert.rejects(collect({ list: async () => [] }, run(), '/tmp'), /no test actions/);
  const api = { list: async path => path.includes('/actions?') ? [{ id: 'test', attributes: { actionType: 'TEST', executionProgress: 'COMPLETE', completionStatus: 'SUCCEEDED' } }] : [] };
  await assert.rejects(collect(api, run(), '/tmp'), /no RESULT_BUNDLE/);
});

test('signed artifact download has no Apple Authorization header', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'cloud-test-'));
  try {
    await downloadArtifact('https://example.com/signed', join(directory, 'bundle.zip'), async (_url, options) => {
      assert.equal(options.headers, undefined);
      return new Response('bundle');
    });
    assert.equal(await readFile(join(directory, 'bundle.zip'), 'utf8'), 'bundle');
    await assert.rejects(downloadArtifact('http://example.com/insecure', join(directory, 'bad')), /HTTPS/);
  } finally { await rm(directory, { recursive: true }); }
});

test('failed Cloud runs retain available result bundles for diagnosis', async () => {
  const api = { list: async path => path.includes('/actions?')
    ? [{ id: 'failed-test', attributes: { actionType: 'TEST', executionProgress: 'COMPLETE', completionStatus: 'FAILED' } }]
    : [{ id: 'artifact', attributes: { fileType: 'RESULT_BUNDLE', downloadUrl: 'https://example.com/private' } }] };
  const result = await collect(api, run({ completionStatus: 'FAILED' }), '/tmp/report', async () => {});
  assert.equal(result.length, 1);
});

test('artifact redirects remain HTTPS and never receive Apple credentials', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'cloud-redirect-'));
  try {
    let calls = 0;
    await downloadArtifact('https://example.com/signed', join(directory, 'result.zip'), async (_url, options) => {
      assert.equal(options.headers, undefined);
      return ++calls === 1 ? new Response('', { status: 302, headers: { location: 'https://cdn.example.com/bundle' } }) : new Response('zip');
    });
    assert.equal(calls, 2);
    await assert.rejects(downloadArtifact('https://example.com/signed', join(directory, 'bad'), async () =>
      new Response('', { status: 302, headers: { location: 'http://example.com/bundle' } })), /HTTPS/);
  } finally { await rm(directory, { recursive: true }); }
});


test('complete bridge saves sanitized build metadata and downloaded test results', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'cloud-main-'));
  const originalFetch = globalThis.fetch;
  try {
    globalThis.fetch = async url => {
      const path = new URL(url).pathname;
      if (path.includes('/ciWorkflows/')) return Response.json({ data: [run()] });
      if (path.endsWith('/ciBuildRuns/run')) return Response.json({ data: run({ number: 17 }) });
      if (path.endsWith('/issues')) return Response.json({ data: [] });
      if (path.endsWith('/actions')) return Response.json({ data: [{ id: 'analyze', attributes: { actionType: 'ANALYZE', executionProgress: 'COMPLETE', completionStatus: 'SUCCEEDED' } }, { id: 'test', attributes: { actionType: 'TEST', executionProgress: 'COMPLETE', completionStatus: 'SUCCEEDED' } }] });
      if (path.endsWith('/artifacts')) return Response.json({ data: [{ id: 'bundle', attributes: { fileType: 'RESULT_BUNDLE', downloadUrl: 'https://example.com/signed-private-url' } }] });
      return new Response('bundle-data');
    };
    await main({ ...env, XCODE_CLOUD_WORKFLOW_ID: expected.workflow, EXPECTED_SHA: expected.sha, CLOUD_REPORTS_DIR: directory, GITHUB_STEP_SUMMARY: join(directory, 'summary.md') });
    const metadata = await readFile(join(directory, 'build.json'), 'utf8');
    assert.equal(JSON.parse(metadata).number, 17);
    assert.equal(metadata.includes('private-url'), false);
    assert.equal(await readFile(join(directory, 'result-0.zip'), 'utf8'), 'bundle-data');
    assert.match(await readFile(join(directory, 'summary.md'), 'utf8'), /SUCCEEDED/);
  } finally {
    globalThis.fetch = originalFetch;
    await rm(directory, { recursive: true });
  }
});

test('missing bridge credentials and invalid revisions fail before network calls', async () => {
  await assert.rejects(main({}), /Missing ASC_KEY_ID/);
  const configured = { ...env, XCODE_CLOUD_WORKFLOW_ID: expected.workflow, EXPECTED_SHA: 'wrong' };
  await assert.rejects(main(configured), /full Git commit/);
  await assert.rejects(main({ ...configured, EXPECTED_SHA: expected.sha, EXPECTED_BASE_SHA: 'wrong' }), /full PR base/);
});

test('a failed run names the action Apple blames while its checks look green', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'cloud-error-'));
  const originalFetch = globalThis.fetch;
  const originalLog = console.log;
  const lines = [];
  console.log = value => lines.push(String(value));
  try {
    globalThis.fetch = async url => {
      const path = new URL(url).pathname;
      if (path.includes('/ciWorkflows/')) return Response.json({ data: [run({ completionStatus: 'ERRORED' })] });
      if (path.endsWith('/ciBuildRuns/run')) return Response.json({ data: run({ number: 15, completionStatus: 'ERRORED' }) });
      if (path.endsWith('/issues')) return Response.json({ data: [] });
      if (path.endsWith('/actions')) return Response.json({ data: [
        { id: 'build', attributes: { name: 'Build - iOS', actionType: 'BUILD', executionProgress: 'COMPLETE', completionStatus: 'SUCCEEDED' } },
        { id: 'test', attributes: { name: 'Test - iOS', actionType: 'TEST', executionProgress: 'COMPLETE', completionStatus: 'SUCCEEDED' } },
        { id: 'analyze', attributes: { name: 'Analyze - iOS', actionType: 'ANALYZE', executionProgress: 'COMPLETE', completionStatus: 'SUCCEEDED' } },
        { id: 'notify', attributes: { name: 'Notify - iOS', actionType: 'NOTIFY', executionProgress: 'COMPLETE', completionStatus: 'FAILED' } },
        { id: 'forged', attributes: { name: 'Notify - iOS\r\n::error::forged', actionType: 'NOTIFY', executionProgress: 'COMPLETE', completionStatus: 'FAILED' } },
      ] });
      if (path.endsWith('/artifacts')) return Response.json({ data: [{ id: 'bundle', attributes: { fileType: 'RESULT_BUNDLE', downloadUrl: 'https://example.com/signed-private-url' } }] });
      return new Response('bundle-data');
    };
    await assert.rejects(main({
      ...env, XCODE_CLOUD_WORKFLOW_ID: expected.workflow, EXPECTED_SHA: expected.sha, CLOUD_REPORTS_DIR: directory,
    }), /ended with ERRORED/);
    assert.match(lines.join('\n'), /Actions: Build - iOS: SUCCEEDED; Test - iOS: SUCCEEDED; Analyze - iOS: SUCCEEDED; Notify - iOS: FAILED/);
    assert.equal(lines.some(line => /[\r\n]/.test(line)), false, `control characters leaked: ${JSON.stringify(lines)}`);
    assert.equal(JSON.parse(await readFile(join(directory, 'build.json'), 'utf8')).status, 'ERRORED');
  } finally {
    globalThis.fetch = originalFetch;
    console.log = originalLog;
    await rm(directory, { recursive: true });
  }
});

test('action statuses are reported before results are collected', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'cloud-order-'));
  const originalFetch = globalThis.fetch;
  const originalLog = console.log;
  const lines = [];
  console.log = value => lines.push(String(value));
  try {
    globalThis.fetch = async url => {
      const path = new URL(url).pathname;
      if (path.includes('/ciWorkflows/')) return Response.json({ data: [run({ completionStatus: 'ERRORED' })] });
      if (path.endsWith('/ciBuildRuns/run')) return Response.json({ data: run({ number: 16, completionStatus: 'ERRORED' }) });
      // Analysis collection fails, after the status line has already been written.
      if (path.endsWith('/issues')) return new Response('', { status: 404 });
      if (path.endsWith('/actions')) return Response.json({ data: [
        { id: 'analyze', attributes: { name: 'Analyze - iOS', actionType: 'ANALYZE', executionProgress: 'COMPLETE', completionStatus: 'FAILED' } },
      ] });
      return new Response('unused');
    };
    await assert.rejects(main({
      ...env, XCODE_CLOUD_WORKFLOW_ID: expected.workflow, EXPECTED_SHA: expected.sha, CLOUD_REPORTS_DIR: directory,
    }), /HTTP 404/);
    assert.match(lines.join('\n'), /run 16 ended with ERRORED\. Actions: Analyze - iOS: FAILED/);
  } finally {
    globalThis.fetch = originalFetch;
    console.log = originalLog;
    await rm(directory, { recursive: true });
  }
});

test('a failed action lookup is reported without replacing the terminal status', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'cloud-bestafter-'));
  const originalFetch = globalThis.fetch;
  const originalLog = console.log;
  const lines = [];
  console.log = value => lines.push(String(value));
  try {
    let actionLists = 0;
    globalThis.fetch = async url => {
      const path = new URL(url).pathname;
      if (path.includes('/ciWorkflows/')) return Response.json({ data: [run({ completionStatus: 'ERRORED' })] });
      if (path.endsWith('/ciBuildRuns/run')) return Response.json({ data: run({ number: 17, completionStatus: 'ERRORED' }) });
      if (path.endsWith('/issues')) return Response.json({ data: [] });
      if (path.endsWith('/actions')) {
        actionLists++;
        // The diagnostic lookup fails; collection and analysis still succeed.
        if (actionLists === 1) return new Response('', { status: 404 });
        return Response.json({ data: [
          { id: 'analyze', attributes: { name: 'Analyze - iOS', actionType: 'ANALYZE', executionProgress: 'COMPLETE', completionStatus: 'SUCCEEDED' } },
          { id: 'test', attributes: { name: 'Test - iOS', actionType: 'TEST', executionProgress: 'COMPLETE', completionStatus: 'SUCCEEDED' } },
        ] });
      }
      if (path.endsWith('/artifacts')) return Response.json({ data: [{ id: 'bundle', attributes: { fileType: 'RESULT_BUNDLE', downloadUrl: 'https://example.com/signed-private-url' } }] });
      return new Response('bundle-data');
    };
    await assert.rejects(main({
      ...env, XCODE_CLOUD_WORKFLOW_ID: expected.workflow, EXPECTED_SHA: expected.sha, CLOUD_REPORTS_DIR: directory,
    }), /ended with ERRORED/);
    assert.match(lines.join('\n'), /run 17 ended with ERRORED; action statuses unavailable \(App Store Connect HTTP 404/);
  } finally {
    globalThis.fetch = originalFetch;
    console.log = originalLog;
    await rm(directory, { recursive: true });
  }
});

test('Analyze issues annotate repo paths with escaped workflow-command data', () => {
  const annotation = issueAnnotation({ attributes: {
    issueType: 'ANALYZER_WARNING', message: 'bad%\n::error::injected',
    fileSource: { path: '/Volumes/workspace/repository/OpenCodeRemote/OpenCodeRemote/App.swift', lineNumber: 42 },
  } });
  assert.match(annotation, /file=OpenCodeRemote\/OpenCodeRemote\/App.swift,line=42/);
  assert.match(annotation, /bad%25%0A::error::injected$/);
  assert.equal(annotation.includes('\n'), false);
});

test('Cloud success requires an Analyze action; analyzer warnings fail after report persistence', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'cloud-analyze-'));
  try {
    await assert.rejects(collectAnalysis({ list: async () => [] }, run(), directory), /no ANALYZE/);
    const action = { id: 'analyze', attributes: { actionType: 'ANALYZE', executionProgress: 'COMPLETE', completionStatus: 'SUCCEEDED' } };
    const api = { list: async path => path.includes('/actions?') ? [action] : [{ attributes: { issueType: 'ANALYZER_WARNING', message: 'bad', fileSource: null } }] };
    const annotations = [];
    await assert.rejects(collectAnalysis(api, run(), directory, value => annotations.push(value)), /static analyzer warnings/);
    const report = JSON.parse(await readFile(join(directory, 'analysis.json'), 'utf8'));
    assert.equal(report.issues.length, 1);
    assert.equal(annotations.length, 1);
  } finally { await rm(directory, { recursive: true }); }
});
