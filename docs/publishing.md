# Publishing the plugin and iOS app

GitHub releases publish the **server plugin only**. Native iOS beta and public
releases use **Xcode Cloud → TestFlight / App Store Connect**.

## Plugin: npm and GitHub Packages

| Registry | Package | Stable channel | Prerelease channel |
| --- | --- | --- | --- |
| npmjs.org | `opencode-push-relay` | `latest` | `next` |
| npm.pkg.github.com | `@timlaing/opencode-push-relay` | `latest` | `next` |

The npm package keeps its established unscoped name. GitHub requires an
owner-scoped name, so the build produces a second tarball with only the package
name changed. Exports, dependencies, version and tested source/build files stay
the same. Neither publisher runs lifecycle hooks or rebuilds downloaded artifacts.

1. Update the plugin version in `plugins/opencode-push-relay/package.json` and
   its lockfile, merge to `main`, and wait for Tests (Cloud/Sonar included),
   CodeQL and Lint checks on that exact commit.
2. Create a GitHub release tagged `plugin-vX.Y.Z`; for a preview, use
   `plugin-vX.Y.Z-beta.1` (and match the package version). Set the GitHub prerelease checkbox to match the version suffix; mismatches
   fail validation. Draft release notes now use the plugin prefix and include PRs labeled `component: push-relay`.
3. Publish the release, or manually run **Publish plugin packages** with an
   existing plugin tag. App tags and unrelated release events cannot upload
   an iOS binary. The parser explicitly rejects app tags on manual dispatch.
4. Approve the protected environment jobs. One build tests and packs the
   plugin, then npm and GitHub Packages independently publish hash-verified
   artifacts. Check both publishing jobs for completion.

### One-time service settings

- Keep required reviewers on the existing `npm` GitHub environment; it gates
  both package registries. The `release-preflight` environment needs its
  `RELEASE_PREFLIGHT_TOKEN` admin-read credential to verify reviewer protection.
- Configure npm trusted publishing for `timlaing/ios-opencode-client`, workflow
  file **publish.yml**, environment **npm**, and allow publishing. Bootstrap
  package ownership/trusted publishing on npm as required for a first release.
  No long-lived npm publish token is introduced. The GitHub-hosted Node 26 runner
  supplies the npm CLI/OIDC support; npm publishes provenance.
- GitHub Packages uses the workflow's `GITHUB_TOKEN` with `packages: write`.
  If the scoped package already exists, grant this repository Actions access.
  Verify package visibility after its first publication; linked repository
  permissions and package visibility are separate service settings.

An explicit registry URL is supplied for every registry query and publish.
An absent package/version (E404) permits initial publication; authentication
and other lookup failures stop the job. Existing versions are skipped only if
SHA-512 integrity proves that their tarball bytes are identical. Different
bytes at the same version fail; distribution tags never move backward.
This allows retrying one registry after the other already succeeded.

The npm install remains `npm install opencode-push-relay`. For the GitHub
mirror, configure `@timlaing:registry=https://npm.pkg.github.com`, authenticate
with a credential that has package read access, then install
`@timlaing/opencode-push-relay`. GitHub Packages npm downloads require
registry authentication, including public packages; npmjs.org remains the
simpler public installation path. Do not commit authentication tokens.

## iOS: TestFlight and App Store

The GitHub app publishing job, manual signing script and upload receipts have
been removed. App publication does not use GitHub releases or `app-v*` tags.
Cloud signing replaces the GitHub P12/profile upload path.

In App Store Connect → app → Xcode Cloud, configure separate workflows:

| Workflow | Start | Action and distribution |
| --- | --- | --- |
| CI | PR/maintained branch changes | Test + Analyze, no distribution |
| Beta | Manually select a tested commit/branch, or use a dedicated beta branch | Release Archive, TestFlight post-action to selected tester groups |
| Release candidate | Manual start from a commit whose GitHub checks passed | Release Archive, TestFlight and App Store eligibility; submit/release in App Store Connect |

For Beta and Release candidate, use **TestFlight and App Store** deployment
preparation if you want to test and later submit the *same binary*. The
**Internal Testing Only** option cannot later be submitted to the App Store.
Use clean builds and restrict distribution-workflow editing as Apple requires.
Choose the `OpenCodeRemote` scheme, keep numeric marketing versions such as
`1.2.0`, and let Cloud assign increasing build numbers. Use App Store Connect
for tester groups, external Beta App Review, App Review and public release.

Keep `XCODE_CLOUD_WORKFLOW_ID` pointed at **CI**, not an archive-only publishing
workflow. Distribution workflows are service-side settings and are not created
by the repository's test-result bridge. A manually started distribution build
does not automatically enforce the GitHub/Sonar gates: select the verified
commit before starting it. Automated gating of publication would require a
separate explicit Cloud-dispatch workflow; it is not performed by GitHub releases.

## Verification

Local packaging/tests establish artifact identity and workflow logic. They do
not establish registry permissions, npm trusted-publisher configuration, live
publication, TestFlight delivery, App Review or physical-device behavior.

## References

- [GitHub Packages npm registry](https://docs.github.com/en/packages/working-with-a-github-packages-registry/working-with-the-npm-registry)
- [npm trusted publishing](https://docs.npmjs.com/trusted-publishers/)
- [Apple distribution workflows](https://developer.apple.com/documentation/xcode/creating-a-workflow-that-builds-your-app-for-distribution)
