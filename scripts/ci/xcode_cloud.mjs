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

// Every line this bridge writes to the CI log passes through logSafe. Apple
// responses (commit SHAs, action names, statuses) and workflow inputs such as
// XCODE_CLOUD_RUN_ID are remote-controlled: without this, a value carrying CR,
// LF or other control characters could forge a second log line or a GitHub
// workflow command.
export function logSafe(value) {
  return String(value ?? '').replace(/[\u0000-\u001f\u007f]/g, ' ');
}

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
    return this.request(apiURL(path), 0);
  }
  // At most five attempts, the first four retrying 429/5xx with backoff.
  // Recursive rather than a `for` loop so each backoff waits on its own frame.
  async request(url, attempt) {
    const response = await this.fetcher(url, {
      headers: { Authorization: `Bearer ${jwt(this.env)}`, Accept: 'application/json' },
      redirect: 'error', signal: AbortSignal.timeout(60_000),
    });
    if (response.ok) return response.json();
    const retryable = response.status === 429 || response.status >= 500;
    if (!retryable || attempt === 4) {
      // Do not print response bodies, JWTs or signed artifact URLs.
      throw new Error(`App Store Connect HTTP ${response.status} at ${url.pathname}`);
    }
    const retry = Number(response.headers.get('retry-after'));
    await this.pause(Math.min(60, Math.max(2 ** attempt, Number.isFinite(retry) ? retry : 0)) * 1000);
    return this.request(url, attempt + 1);
  }
  async list(path) {
    const data = [];
    const seen = new Set();
    // Pagination follows `links.next` recursively: the pages are inherently
    // sequential, so they are awaited one page per frame, not inside a loop.
    const walk = async link => {
      if (!link) return;
      const url = apiURL(link).href;
      if (seen.has(url)) throw new Error('Repeated App Store Connect pagination link');
      seen.add(url);
      const page = await this.get(url);
      if (!Array.isArray(page.data)) throw new Error('Expected an API resource list');
      data.push(...page.data);
      await walk(page.links?.next);
    };
    await walk(path);
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
// The `cloud` job times out after 95 minutes (.github/workflows/xcode-cloud.yml),
// which allows ~15 minutes for checkout, result downloads and analysis once the
// wait is done. Capping the override there keeps a configured wait inside the
// job budget, so GitHub cannot cancel the job before results are collected.
export const MAX_WAIT_SECONDS = 4800;

export function waitSeconds(env) {
  const value = Number(env.XCODE_CLOUD_WAIT_SECONDS);
  if (!Number.isFinite(value) || value <= 0) return DEFAULT_WAIT_SECONDS;
  return Math.min(value, MAX_WAIT_SECONDS);
}

// A wait is never silent: updates go out at the first poll and then roughly
// every two minutes (four 30-second polls).
function due(polls) {
  return polls === 1 || polls % 4 === 1;
}

// A workflow accumulates stale runs, so rejections are reported as a bounded
// sample next to the totals instead of one line per run.
const REJECTION_SAMPLE = 20;

function rejectionSummary(expected, scanned) {
  const rejected = scanned.filter(candidate => !matches(candidate, expected));
  const listed = rejected.slice(0, REJECTION_SAMPLE).map(candidate => describe(candidate, expected));
  const omitted = rejected.length - listed.length;
  if (omitted > 0) listed.push(`and ${omitted} older run(s) not listed`);
  return `${rejected.length} of ${scanned.length} scanned run(s) rejected: ${listed.join('; ') || 'none'}`;
}

function scanUpdate(expected, state) {
  if (state.selected || !due(state.polls)) return '';
  const newest = state.scanned.length ? describe(state.scanned[0], expected) : 'none';
  return `Waiting for Xcode Cloud: ${state.scanned.length} build run(s) in the configured workflow; `
    + `newest ${newest}. ${rejectionSummary(expected, state.scanned)}.`;
}

// Same fallbacks as describe(): Apple does not require either attribute, so
// an absent value must not render as "undefined" in one log path and
// "unknown" in the other.
function progressUpdate(polls, run, selected) {
  if (!due(polls)) return '';
  return `Waiting for Xcode Cloud: build ${run.attributes.number ?? selected} is `
    + `${run.attributes.completionStatus || 'pending'}/${run.attributes.executionProgress || 'unknown'}.`;
}

function timeoutUpdate(expected, state) {
  if (state.selected) {
    return `Timed out while build ${state.selected} was still running; executionProgress never reached COMPLETE.`;
  }
  const newest = state.scanned.length ? describe(state.scanned[0], expected) : 'none';
  return `Timed out without a match; scanned ${state.scanned.length} run(s), newest ${newest}. `
    + `${rejectionSummary(expected, state.scanned)}.`;
}

// The single logging path: sanitize remote-controlled values and drop the
// off-cadence empty updates.
function logUpdate(emit, update) {
  if (update) emit(logSafe(update));
}

// One poll cycle: find the matching run and check its progress in the same
// cycle, then wait for the next one. Keeping the cadence here leaves the wait
// loop flat.
async function pollOnce(api, expected, state, emit, pause) {
  if (!state.selected) {
    state.scanned = await api.list(`ciWorkflows/${encodeURIComponent(expected.workflow)}/buildRuns?sort=-number&limit=200`);
    // Apple returns newest first; once selected, keep polling the same run.
    state.selected = state.scanned.find(candidate => matches(candidate, expected))?.id;
    logUpdate(emit, scanUpdate(expected, state));
  }
  if (state.selected) {
    const { data: run } = await api.get(`ciBuildRuns/${encodeURIComponent(state.selected)}?include=workflow`);
    if (!matches(run, expected) || run.relationships?.workflow?.data?.id !== expected.workflow) {
      throw new Error('Cloud build workflow, commit or PR base does not match this GitHub run');
    }
    if (run.attributes.executionProgress === 'COMPLETE') return run;
    logUpdate(emit, progressUpdate(state.polls, run, state.selected));
  }
  await pause(30_000);
  return null;
}

export async function waitForRun(api, expected, {
  timeout = DEFAULT_WAIT_SECONDS, pause = sleep, clock = Date.now, runId = '', emit = () => {},
} = {}) {
  const deadline = clock() + timeout * 1000;
  const state = { selected: runId, scanned: [], polls: 0 };
  while (clock() < deadline) {
    state.polls++;
    const complete = await pollOnce(api, expected, state, emit, pause);
    if (complete) return complete;
  }
  logUpdate(emit, timeoutUpdate(expected, state));
  throw new Error('Timed out waiting for the matching Xcode Cloud build');
}

// The options object keeps the test-only fetcher override explicit and makes
// the cancellation channel (signal) self-documenting at every call site.
export async function downloadArtifact(url, destination, { fetcher = fetch, signal } = {}) {
  let response;
  for (let redirects = 0; redirects <= 5; redirects++) {
    if (new URL(url).protocol !== 'https:') throw new Error('Artifact download requires HTTPS');
    // Signed URLs and redirects are intentionally fetched WITHOUT the Apple
    // JWT. The per-download timeout is linked to the collection's signal so
    // one failed bundle cancels its siblings instead of outliving the failure.
    const timeout = AbortSignal.timeout(600_000);
    response = await fetcher(url, {
      redirect: 'manual',
      signal: signal ? AbortSignal.any([timeout, signal]) : timeout,
    });
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
  const successful = run.attributes.completionStatus === 'SUCCEEDED';
  const tests = actions.filter(action => action.attributes.actionType === 'TEST');
  if (successful && !tests.length) throw new Error('Cloud workflow has no test actions');
  if (successful && tests.some(action => action.attributes.executionProgress !== 'COMPLETE' || action.attributes.completionStatus !== 'SUCCEEDED')) {
    throw new Error('A Cloud test action did not succeed');
  }
  const listings = await Promise.all(tests.map(action =>
    api.list(`ciBuildActions/${encodeURIComponent(action.id)}/artifacts?limit=200`)));
  if (successful && listings.some(files => !files.some(file => file.attributes.fileType === 'RESULT_BUNDLE'))) {
    throw new Error('A Cloud test action has no RESULT_BUNDLE artifact');
  }
  const targets = listings
    .flatMap((files, index) => files
      .filter(file => file.attributes.fileType === 'RESULT_BUNDLE')
      .map(file => ({ action: tests[index].id, artifact: file.id, url: file.attributes.downloadUrl })))
    .map((bundle, index) => ({ ...bundle, target: resolve(directory, `result-${index}.zip`) }));
  // Bundles download together: a run that publishes many result files would
  // otherwise spend more time downloading sequentially than the job has left.
  // One shared controller ties them together: when a download fails, the
  // survivors are aborted at once, so the rejection reaches the top-level
  // handler and the process exits promptly — `process.exitCode` alone does
  // not terminate a process whose event loop still holds in-flight fetches,
  // and lingering downloads would delay `Save Cloud result bundles` past the
  // headroom the job timeout leaves.
  const cancelled = new AbortController();
  try {
    await Promise.all(targets.map(bundle => download(bundle.url, bundle.target, { signal: cancelled.signal })));
  } catch (error) {
    cancelled.abort(error);
    throw error;
  }
  return targets.map(({ action, artifact, target }) => ({ action, artifact, file: target.split('/').pop() }));
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
    const relative = repoRelative(path, prefix);
    if (relative && !relative.split('/').includes('..') && relative.endsWith('.swift')) {
      params.push(`file=${property(relative)}`);
      if (Number.isInteger(source.lineNumber) && source.lineNumber > 0) params.push(`line=${source.lineNumber}`);
      break;
    }
  }
  return `::${level} ${params.join(',')}::${escape(a.message)}`;
}

// Cloud reports absolute workspace paths; keep the repository-relative part.
function repoRelative(path, prefix) {
  if (path.startsWith(prefix)) return path;
  const index = path.indexOf('/' + prefix);
  return index >= 0 ? path.slice(index + 1) : '';
}

export async function collectAnalysis(api, run, directory, emit = console.log) {
  const actions = (await api.list(`ciBuildRuns/${encodeURIComponent(run.id)}/actions?limit=200`))
    .filter(action => action.attributes.actionType === 'ANALYZE');
  // Analyze issues are fetched together so no await sits inside a loop; the
  // report and its annotations still follow action order.
  const issues = await Promise.all(actions.map(action =>
    api.list(`ciBuildActions/${encodeURIComponent(action.id)}/issues?limit=200`)));
  const report = { actions: [], issues: [] };
  actions.forEach((action, index) => {
    report.actions.push({ id: action.id, status: action.attributes.completionStatus });
    issues[index].forEach(issue => {
      report.issues.push({ action: action.id, ...issue.attributes });
      emit(issueAnnotation(issue));
    });
  });
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
  const timeout = waitSeconds(env);
  const requested = Number(env.XCODE_CLOUD_WAIT_SECONDS);
  if (requested > MAX_WAIT_SECONDS) {
    logUpdate(console.log, `XCODE_CLOUD_WAIT_SECONDS ${requested} is longer than the cloud job budget; `
      + `waiting ${timeout} seconds so results are still collected.`);
  }
  const run = await waitForRun(api, {
    sha: env.EXPECTED_SHA, baseSha: env.EXPECTED_BASE_SHA || '', workflow: env.XCODE_CLOUD_WORKFLOW_ID,
  }, {
    runId: env.XCODE_CLOUD_RUN_ID || '',
    timeout,
    emit: console.log,
  });
  const status = run.attributes.completionStatus;
  const metadata = { run: run.id, number: run.attributes.number, sha: env.EXPECTED_SHA, baseSha: env.EXPECTED_BASE_SHA || '', status, artifacts: [] };
  // Persist failure metadata as well; never persist signed URLs or API responses.
  await writeFile(resolve(directory, 'build.json'), JSON.stringify(metadata, null, 2) + '\n');
  if (env.GITHUB_STEP_SUMMARY) {
    await appendFile(env.GITHUB_STEP_SUMMARY, `## Xcode Cloud\nBuild ${metadata.number}: **${status}**\n\nCommit: \`${metadata.sha}\`\n`);
  }
  // Action statuses are reported before results are collected, so a failing
  // download or analysis step cannot hide the only clue a failed run leaves.
  if (status !== 'SUCCEEDED') await reportActions(api, run, console.log);
  metadata.artifacts = await collect(api, run, directory);
  await writeFile(resolve(directory, 'build.json'), JSON.stringify(metadata, null, 2) + '\n');
  await collectAnalysis(api, run, directory);
  if (status !== 'SUCCEEDED') throw new Error(`Xcode Cloud build ended with ${status}`);
  logUpdate(console.log, `Downloaded ${metadata.artifacts.length} result bundle(s) for ${metadata.sha}`);
}

// Report each action's status for a run that did not succeed. The lookup is
// best effort: a failure here is reported as unavailable rather than replacing
// the run's terminal status, which is what fails the job. The statuses show
// what Apple reported, but cannot explain a run whose actions all succeeded.
async function reportActions(api, run, emit) {
  const label = `Xcode Cloud run ${run.attributes.number ?? run.id} ended with ${run.attributes.completionStatus}`;
  try {
    const actions = await api.list(`ciBuildRuns/${encodeURIComponent(run.id)}/actions?limit=200`);
    const detail = actions
      .map(action => `${action.attributes.name || action.attributes.actionType}: ${action.attributes.completionStatus || action.attributes.executionProgress}`)
      .join('; ');
    logUpdate(emit, `${label}. Actions: ${detail || 'none'}`);
  } catch (error) {
    const reason = error instanceof TypeError ? 'network or credential error' : error.message;
    logUpdate(emit, `${label}; action statuses unavailable (${reason}).`);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  try {
    await main();
  } catch (error) {
    // Network errors can contain signed URLs; only our fixed diagnostics are safe.
    console.error(error instanceof TypeError ? 'Xcode Cloud network or credential parsing error' : logSafe(error.message));
    process.exitCode = 1;
  }
}
