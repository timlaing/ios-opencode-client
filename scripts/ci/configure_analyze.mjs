// SPDX-License-Identifier: MPL-2.0
// Explicit service-side configuration, separate from the read-only result bridge.
import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { AppleAPI, apiURL, jwt } from './xcode_cloud.mjs';

export function planAnalyzeActions(actions, desired) {
  if (!Array.isArray(actions)) throw new Error('Workflow response is missing its actions');
  const updated = structuredClone(actions);
  const matches = updated.filter(action => action.actionType === 'ANALYZE'
    && action.platform === desired.platform && action.scheme === desired.scheme);
  if (matches.length > 1) throw new Error('Multiple matching Analyze actions require manual configuration');
  if (matches.length) matches[0].isRequiredToPass = true;
  else updated.push(desired);
  return updated;
}

export async function configure(api, id, desired, apply = false) {
  const path = `ciWorkflows/${encodeURIComponent(id)}`;
  const original = (await api.get(path)).data.attributes.actions;
  const actions = planAnalyzeActions(original, desired);
  if (JSON.stringify(original) === JSON.stringify(actions)) return 'already configured';
  if (!apply) return 'plan: add or require Analyze iOS; existing actions and triggers are preserved';
  // Abort if another editor changed the action list since we read it.
  const latest = (await api.get(path)).data.attributes.actions;
  if (JSON.stringify(original) !== JSON.stringify(latest)) throw new Error('Workflow actions changed; rerun to re-plan');
  const response = await api.fetcher(apiURL(path), {
    method: 'PATCH', redirect: 'error', signal: AbortSignal.timeout(60_000),
    headers: { Authorization: `Bearer ${jwt(api.env)}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ data: { type: 'ciWorkflows', id, attributes: { actions } } }),
  });
  if (!response.ok) throw new Error(`Workflow update HTTP ${response.status}`);
  const readback = (await api.get(path)).data.attributes.actions;
  if (JSON.stringify(planAnalyzeActions(readback, desired)) !== JSON.stringify(readback)) {
    throw new Error('Analyze action configuration did not persist');
  }
  return 'Analyze iOS is required to pass (verified by readback)';
}

export async function main(env = process.env, args = process.argv.slice(2)) {
  if (args.some(arg => arg !== '--apply')) throw new Error('Usage: configure_analyze.mjs [--apply]');
  for (const name of ['ASC_KEY_ID', 'ASC_ISSUER_ID', 'ASC_PRIVATE_KEY', 'XCODE_CLOUD_WORKFLOW_ID']) {
    if (!env[name]) throw new Error(`Missing ${name}`);
  }
  const desired = JSON.parse(await readFile(new URL('../../OpenCodeRemote/ci_scripts/analyze-action.json', import.meta.url), 'utf8'));
  console.log(await configure(new AppleAPI(env), env.XCODE_CLOUD_WORKFLOW_ID, desired, args.includes('--apply')));
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  main().catch(error => {
    console.error(error instanceof TypeError ? 'Workflow configuration network or credential error' : error.message);
    process.exitCode = 1;
  });
}
