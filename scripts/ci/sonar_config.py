# SPDX-License-Identifier: MPL-2.0
"""Append validated CI identity to the checked-in Sonar scanner configuration."""
import os
from pathlib import Path
import re


def properties(env):
    key = env.get('SONAR_PROJECT_KEY', '')
    if not re.fullmatch(r'[\w.:-]+', key, flags=re.ASCII):
        raise ValueError('Set SONAR_PROJECT_KEY to a valid Sonar project key')
    sha = env.get('EXPECTED_SHA', '')
    if not re.fullmatch('[0-9a-f]{40}', sha):
        raise ValueError('A full analysis revision is required')
    values = {'sonar.projectKey': key, 'sonar.scm.revision': sha}
    if env.get('SONAR_HOST_URL'):
        values['sonar.host.url'] = env['SONAR_HOST_URL']
    if env.get('SONAR_ORGANIZATION'):
        values['sonar.organization'] = env['SONAR_ORGANIZATION']
    if env.get('PR_NUMBER'):
        if not env['PR_NUMBER'].isdigit() or not env.get('PR_BRANCH') or not env.get('BASE_BRANCH'):
            raise ValueError('Missing pull-request analysis context')
        values.update({
            'sonar.pullrequest.key': env['PR_NUMBER'],
            'sonar.pullrequest.branch': env['PR_BRANCH'],
            'sonar.pullrequest.base': env['BASE_BRANCH'],
        })
    else:
        if not env.get('BRANCH'):
            raise ValueError('Missing branch analysis context')
        values['sonar.branch.name'] = env['BRANCH']
    # Java properties escaping: never allow a branch name to inject properties.
    def escape(value):
        if any(ord(char) < 32 or ord(char) > 126 for char in value):
            raise ValueError('CI analysis identity must use printable ASCII')
        return ''.join('\\' + char if char in '\\:=#! ' else char for char in value)
    return '\n' + '\n'.join(f'{key}={escape(value)}' for key, value in values.items()) + '\n'


if __name__ == '__main__':
    with Path('sonar-project.properties').open('a') as config:
        config.write(properties(os.environ))
