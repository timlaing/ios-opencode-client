// SPDX-License-Identifier: MPL-2.0
// Read-only App Store Connect bridge. No GitHub token or third-party modules.
import { createPrivateKey, sign } from 'node:crypto';
import { createWriteStream } from 'node:fs';
import { appendFile, mkdir, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { pathToFileURL } from 'node:url';

const API = 'https://api.appstoreconnect.apple.com/v1/';
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

export function jwt(env, now = Math.floor(Date.now() / 1000)) {
  const encode = value => Buffer.from(JSON.stringify(value)).toString('base64url');
  const header = encode({ alg: 'ES256', kid: env.ASC_KEY_ID, typ: 'JWT' });
  const claims = encode({ iss: env.ASC_ISSUER_ID, iat: now - 30, exp: now + 600, aud: 'appstoreconnect-v1' });
  const key = createPrivateKey(env.ASC_PRIVATE_KEY);
  if (key.asymmetricKeyType !== 'ec' || key.asymmetricKeyDetails?.namedCurve !== 'prime256v1') {
    throw new Error('ASC_PRIVATE_KEY must be an EC P-256 App Store Connect key');
  }
  const signature = sign('sha256', Buffer.from(`${header}.${claims}`), { key, dsaEncoding: 'ieee-p1363' });
  return `${header}.${claims}.${signature.toString('base64url')}`;
}

export function apiURL(path) {
  const url = new URL(path, API);
  if (url.origin !== new URL(API).origin || !url.pathname.startsWith('/v1/')) {
    throw new Error('Refusing an App Store Connect link outside the API');
  }
  return url;
}

export class AppleAPI {
  constructor(env, fetcher = fetch, pause = sleep) {
    this.env = env;
    this.fetcher = fetcher;
    this.pause = pause;
  }
  async get(path) {
    const url = apiURL(path);
    for (let attempt = 0; attempt < 5; attempt++) {
      const response = await this.fetcher(url, {
        headers: { Authorization: `Bearer ${jwt(this.env)}`, Accept: 'application/json' },
        redirect: 'error', signal: AbortSignal.timeout(60_000),
      });
      if (response.ok) return response.json();
      if ((response.status === 429 || response.status >= 500) && attempt < 4) {
        const retry = Number(response.headers.get('retry-after'));
        await this.pause(Math.min(60, Math.max(2 ** attempt, Number.isFinite(retry) ? retry : 0)) * 1000);
        continue;
      }
      // Do not print response bodies, JWTs or signed artifact URLs.
      throw new Error(`App Store Connect HTTP ${response.status} at ${url.pathname}`);
    }
  }
  async list(path) {
    const data = [];
    const seen = new Set();
    while (path) {
      const url = apiURL(path).href;
      if (seen.has(url)) throw new Error('Repeated App Store Connect pagination link');
      seen.add(url);
      const page = await this.get(url);
      if (!Array.isArray(page.data)) throw new Error('Expected an API resource list');
      data.push(...page.data);
      path = page.links?.next;
    }
    return data;
  }
}

export function mismatch(run, expected) {
  const a = run.attributes;
  if (a?.sourceCommit?.commitSha !== expected.sha) {
    return `source commit is ${a?.sourceCommit?.commitSha || 'unknown'} but this GitHub run needs ${expected.sha}`;
  }
  if (a.isPullRequestBuild !== Boolean(expected.baseSha)) {
    return `pull-request build is ${Boolean(a.isPullRequestBuild)} but this GitHub run expects ${Boolean(expected.baseSha)}`;
  }
  if (expected.baseSha && a.destinationCommit?.commitSha !== expected.baseSha) {
    return `base commit is ${a.destinationCommit?.commitSha || 'unknown'} but this GitHub run needs ${expected.baseSha}`;
  }
  return '';
}

export function matches(run, expected) {
  return mismatch(run, expected) === '';
}

export function describe(run, expected) {
  const a = run.attributes;
  const reason = mismatch(run, expected);
  return `#${a?.number ?? '?'} ${a?.sourceCommit?.commitSha || 'no-commit'} ${reason || 'eligible'} `
    + `(${a?.isPullRequestBuild ? 'PR' : 'branch'} build, ${a?.completionStatus || 'pending'}/${a?.executionProgress || 'unknown'})`;
}

// 75 minutes covers the observed Cloud queue plus a full iPhone/iPad test
// matrix, while leaving headroom for result downloads inside the job timeout.
export const DEFAULT_WAIT_SECONDS = 4500;

export function waitSeconds(env) {
  const value = Number(env.XCODE_CLOUD_WAIT_SECONDS);
  return Number.isFinite(value) && value > 0 ? value : DEFAULT_WAIT_SECONDS;
}

export async function waitForRun(api, expected, {
  timeout = DEFAULT_WAIT_SECONDS, pause = sleep, clock = Date.now, runId = '', emit = () => {},
} = {}) {
  const deadline = clock() + timeout * 1000;
  let selected = runId;
  let scanned = [];
  let polls = 0;
  while (clock() < deadline) {
    polls++;
    if (!selected) {
      scanned = await api.list(`ciWorkflows/${encodeURIComponent(expected.workflow)}/buildRuns?sort=-number&limit=200`);
      // Apple returns newest first; once selected, keep polling the same run.
      selected = scanned.find(candidate => matches(candidate, expected))?.id;
      // A wait is never silent: report what the workflow actually contains,
      // at the first poll and then roughly every two minutes.
      if (!selected && (polls === 1 || polls % 4 === 1)) {
        emit(`Waiting for Xcode Cloud: ${scanned.length} build run(s) in the configured workflow; `
          + `newest ${scanned.length ? describe(scanned[0], expected) : 'none'}.`);
      }
    }
    if (selected) {
      const { data: run } = await api.get(`ciBuildRuns/${encodeURIComponent(selected)}?include=workflow`);
      if (!matches(run, expected) || run.relationships?.workflow?.data?.id !== expected.workflow) {
        throw new Error('Cloud build workflow, commit or PR base does not match this GitHub run');
      }
      if (run.attributes.executionProgress === 'COMPLETE') return run;
      if (polls === 1 || polls % 4 === 1) {
        emit(`Waiting for Xcode Cloud: build ${run.attributes.number ?? selected} is `
          + `${run.attributes.completionStatus || 'pending'}/${run.attributes.executionProgress}.`);
      }
    }
    await pause(30_000);
  }
  if (selected) {
    emit(`Timed out while build ${selected} was still running; executionProgress never reached COMPLETE.`);
  } else {
    emit(`Timed out without a match. Newest build runs: ${scanned.length ? scanned.slice(0, 5).map(run => describe(run, expected)).join('; ') : 'none'}.`);
  }
  throw new Error('Timed out waiting for the matching Xcode Cloud build');
}

export async function downloadArtifact(url, destination, fetcher = fetch) {
  let response;
  for (let redirects = 0; redirects <= 5; redirects++) {
    if (new URL(url).protocol !== 'https:') throw new Error('Artifact download requires HTTPS');
    // Signed URLs and redirects are intentionally fetched WITHOUT the Apple JWT.
    response = await fetcher(url, { redirect: 'manual', signal: AbortSignal.timeout(600_000) });
    if ([301, 302, 303, 307, 308].includes(response.status)) {
      const location = response.headers.get('location');
      if (!location || redirects === 5) throw new Error('Invalid artifact redirect chain');
      await response.body?.cancel();
      url = new URL(location, url).href;
      continue;
    }
    break;
  }
  if (!response.ok || !response.body) throw new Error(`Artifact download HTTP ${response.status}`);
  await pipeline(Readable.fromWeb(response.body), createWriteStream(destination, { flags: 'wx' }));
}

export async function collect(api, run, directory, download = downloadArtifact) {
  const actions = await api.list(`ciBuildRuns/${encodeURIComponent(run.id)}/actions?limit=200`);
  const artifacts = [];
  const successful = run.attributes.completionStatus === 'SUCCEEDED';
  let testActions = 0;
  for (const action of actions) {
    if (action.attributes.actionType !== 'TEST') continue;
    testActions++;
    if (successful && (action.attributes.executionProgress !== 'COMPLETE' || action.attributes.completionStatus !== 'SUCCEEDED')) {
      throw new Error('A Cloud test action did not succeed');
    }
    const files = await api.list(`ciBuildActions/${encodeURIComponent(action.id)}/artifacts?limit=200`);
    const bundles = files.filter(file => file.attributes.fileType === 'RESULT_BUNDLE');
    if (successful && !bundles.length) throw new Error('A Cloud test action has no RESULT_BUNDLE artifact');
    for (const file of bundles) {
      const target = resolve(directory, `result-${artifacts.length}.zip`);
      await download(file.attributes.downloadUrl, target);
      artifacts.push({ action: action.id, artifact: file.id, file: target.split('/').pop() });
    }
  }
  if (successful && !testActions) throw new Error('Cloud workflow has no test actions');
  return artifacts;
}

export function issueAnnotation(issue) {
  const a = issue.attributes;
  const escape = value => String(value ?? '').replaceAll('%', '%25').replaceAll('\r', '%0D').replaceAll('\n', '%0A');
  const property = value => escape(value).replaceAll(':', '%3A').replaceAll(',', '%2C');
  const level = a.issueType === 'ERROR' || a.issueType === 'TEST_FAILURE' ? 'error' : 'warning';
  const params = ['title=Xcode Analyze'];
  const source = a.fileSource;
  const path = source?.path || '';
  for (const prefix of ['OpenCodeRemote/OpenCodeRemote/', 'Packages/OpenCodeKit/Sources/']) {
    const index = path.indexOf('/' + prefix);
    const relative = path.startsWith(prefix) ? path : index >= 0 ? path.slice(index + 1) : '';
    if (relative && !relative.split('/').includes('..') && relative.endsWith('.swift')) {
      params.push(`file=${property(relative)}`);
      if (Number.isInteger(source.lineNumber) && source.lineNumber > 0) params.push(`line=${source.lineNumber}`);
      break;
    }
  }
  return `::${level} ${params.join(',')}::${escape(a.message)}`;
}

export async function collectAnalysis(api, run, directory, emit = console.log) {
  const actions = (await api.list(`ciBuildRuns/${encodeURIComponent(run.id)}/actions?limit=200`))
    .filter(action => action.attributes.actionType === 'ANALYZE');
  const report = { actions: [], issues: [] };
  for (const action of actions) {
    report.actions.push({ id: action.id, status: action.attributes.completionStatus });
    const issues = await api.list(`ciBuildActions/${encodeURIComponent(action.id)}/issues?limit=200`);
    for (const issue of issues) {
      report.issues.push({ action: action.id, ...issue.attributes });
      emit(issueAnnotation(issue));
    }
  }
  await writeFile(resolve(directory, 'analysis.json'), JSON.stringify(report, null, 2) + '\n');
  if (run.attributes.completionStatus === 'SUCCEEDED') {
    if (!actions.length) throw new Error('Cloud workflow has no ANALYZE action; enable the required Analyze iOS action');
    if (actions.some(action => action.attributes.executionProgress !== 'COMPLETE' || action.attributes.completionStatus !== 'SUCCEEDED')) {
      throw new Error('A Cloud Analyze action did not succeed');
    }
    if (report.issues.some(issue => issue.issueType === 'ANALYZER_WARNING')) {
      throw new Error('Xcode Analyze reported static analyzer warnings; see PR annotations and analysis.json');
    }
  }
  return report;
}

export async function main(env = process.env) {
  for (const name of ['ASC_KEY_ID', 'ASC_ISSUER_ID', 'ASC_PRIVATE_KEY', 'XCODE_CLOUD_WORKFLOW_ID', 'EXPECTED_SHA']) {
    if (!env[name]) throw new Error(`Missing ${name}`);
  }
  if (!/^[a-f0-9]{40}$/.test(env.EXPECTED_SHA)) throw new Error('Expected a full Git commit SHA');
  if (env.EXPECTED_BASE_SHA && !/^[a-f0-9]{40}$/.test(env.EXPECTED_BASE_SHA)) throw new Error('Expected a full PR base SHA');
  const directory = resolve(env.CLOUD_REPORTS_DIR || 'reports/cloud');
  await mkdir(directory, { recursive: true });
  const api = new AppleAPI(env);
  const run = await waitForRun(api, {
    sha: env.EXPECTED_SHA, baseSha: env.EXPECTED_BASE_SHA || '', workflow: env.XCODE_CLOUD_WORKFLOW_ID,
  }, {
    runId: env.XCODE_CLOUD_RUN_ID || '',
    timeout: waitSeconds(env),
    emit: console.log,
  });
  const status = run.attributes.completionStatus;
  const metadata = { run: run.id, number: run.attributes.number, sha: env.EXPECTED_SHA, baseSha: env.EXPECTED_BASE_SHA || '', status, artifacts: [] };
  // Persist failure metadata as well; never persist signed URLs or API responses.
  await writeFile(resolve(directory, 'build.json'), JSON.stringify(metadata, null, 2) + '\n');
  if (env.GITHUB_STEP_SUMMARY) {
    await appendFile(env.GITHUB_STEP_SUMMARY, `## Xcode Cloud\nBuild ${metadata.number}: **${status}**\n\nCommit: \`${metadata.sha}\`\n`);
  }
  metadata.artifacts = await collect(api, run, directory);
  await writeFile(resolve(directory, 'build.json'), JSON.stringify(metadata, null, 2) + '\n');
  await collectAnalysis(api, run, directory);
  if (status !== 'SUCCEEDED') {
    // The run-level status can disagree with the individual action checks
    // GitHub already shows, so name the action Apple blames.
    const actions = await api.list(`ciBuildRuns/${encodeURIComponent(run.id)}/actions?limit=200`);
    const detail = actions
      .map(action => `${action.attributes.name || action.attributes.actionType}: ${action.attributes.completionStatus || action.attributes.executionProgress}`)
      .join('; ');
    console.log(`Xcode Cloud run ${run.attributes.number ?? run.id} ended with ${status}. Actions: ${detail || 'none'}`);
    throw new Error(`Xcode Cloud build ended with ${status}`);
  }
  console.log(`Downloaded ${metadata.artifacts.length} result bundle(s) for ${metadata.sha}`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().catch(error => {
    // Network errors can contain signed URLs; only our fixed diagnostics are safe.
    console.error(error instanceof TypeError ? 'Xcode Cloud network or credential parsing error' : error.message);
    process.exitCode = 1;
  });
}
