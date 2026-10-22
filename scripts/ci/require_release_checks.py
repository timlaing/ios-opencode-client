# SPDX-License-Identifier: MPL-2.0
"""Release gate: successful trusted push runs and a non-skipped Sonar job."""
import json
import os
import re
import subprocess
import sys

def api(url):
    return json.loads(subprocess.check_output(['gh', 'api', url]))

def require_checks(repository, sha):
    if not re.fullmatch('[0-9a-f]{40}', sha):
        raise ValueError('Invalid release SHA')
    for workflow in ['tests.yml', 'codeql.yml']:
        url = f'repos/{repository}/actions/workflows/{workflow}/runs?head_sha={sha}&event=push&per_page=100'
        runs = [run for run in api(url)['workflow_runs'] if run['head_branch'] == 'main' and run['head_sha'] == sha]
        if not runs:
            raise ValueError(f'Release blocked: no main push run of {workflow} for {sha}')
        latest = max(runs, key=lambda run: run['id'])
        if latest['conclusion'] != 'success':
            raise ValueError(f'Release blocked: latest main push run of {workflow} must succeed for {sha}')
        if workflow == 'tests.yml':
            jobs = api(f"repos/{repository}/actions/runs/{latest['id']}/jobs?per_page=100")['jobs']
            if not any(job['name'] == 'sonar' and job['conclusion'] == 'success' for job in jobs):
                raise ValueError('Release blocked: Sonar analysis must succeed, not be skipped')

def require_environment(repository, kind):
    if kind not in {'app', 'plugin'}:
        raise ValueError('Invalid release kind')
    environment = 'app-store' if kind == 'app' else 'npm'
    data = api(f'repos/{repository}/environments/{environment}')
    if not any(rule.get('type') == 'required_reviewers' and rule.get('reviewers')
               for rule in data.get('protection_rules', [])):
        raise ValueError(f'Release blocked: {environment} must have required reviewers configured')

if __name__ == '__main__':
    try:
        require_checks(os.environ['GITHUB_REPOSITORY'], sys.argv[1])
        require_environment(os.environ['GITHUB_REPOSITORY'], os.environ['RELEASE_KIND'])
    except ValueError as error:
        raise SystemExit(str(error)) from error
    print('Exact release commit passed Tests, Sonar and CodeQL on main')
