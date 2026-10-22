# GitHub automation

The workflows adapt the contributor and CI patterns from `timlaing/pyicloud` to
this repository. They do not update the pinned OpenCode contract baseline.

## Checks

`Tests` runs dependency-free Python unittest checks on 3.11 and 3.14, regenerates
fixtures/contracts and rejects drift, builds/tests the plugin on Node 26.12.0,
runs Swift package tests separately, and runs app unit/UI tests once per device
family. The existing UI suite rotates both orientations. Swift jobs use the
`xcode-27` hosted image with Xcode 27.0 explicitly selected and iOS 27.0 simulators.
Runner images are serviced by GitHub; the job logs record the installed toolchain.

Coverage is collected separately: coverage.py (a CI-only tool) produces Python
Cobertura XML, Node produces LCOV, Swift package LCOV and each iOS xcresult are
converted to Sonar generic XML with repository-relative Swift source paths.
Dependencies and generated output are excluded from Swift reports. Test artifacts
are retained for seven days. Simulator results do not verify signed-device iCloud
sync, real OpenCode hosts, physical devices, a live relay or APNs delivery.

`Workflow validation` checks action references, actionlint syntax, classifier tests
and CI helper tests. `Lint and documentation` validates JSON, local Markdown file
links, Python compilation, and formatting of automation files. Existing app/source
formatting is not rewritten by this migration. CodeQL scans Actions, Python,
JavaScript/TypeScript and the manually built Swift app using security-extended
queries on PRs, integration/default-branch pushes and a weekly schedule.
Dependency security review rejects PRs introducing high/critical advisories. Enable
GitHub secret scanning and push protection in repository security settings as well.

## Sonar setup

Configure the existing SonarCloud project `timlaing_ios-opencode-client` in the
`timlaing` organization for CI analysis (disable automatic analysis if enabled).
Add repository Actions secret `SONAR_TOKEN`. `Tests / sonar` downloads reports from
its own run, analyzes the exact checked-out revision and waits for the quality gate.
Missing credentials fail trusted runs explicitly. Fork and Dependabot PRs run the
unprivileged tests/security scans but skip secret-bearing Sonar analysis; their
changes are scanned again on a trusted push. There is no privileged `workflow_run`
checkout of untrusted fork code. Do not require the skipped Sonar job alone for fork
PRs; select the always-running test/security checks in branch protection.

## Labels, templates and dependency updates

Issue forms and additive PR labelling share `.github/component-labels.json`.
Selections in the Affected component field override text inference. PR changed
and previous paths support renamed files. Labelling always executes default-branch
code, never PR code. It becomes active when merged into the default branch.

Run `Sync repository labels` manually after merging, before enabling issue forms,
Release Drafter and stale processing. It creates/updates the configured component
and lifecycle labels. It does not delete unrelated labels. Issue forms cover bugs, compatibility
reports and feature requests, with version/device/mock-versus-host evidence and redaction
reminders. Discussions is not currently enabled, so no broken help link is added.
Enable GitHub private vulnerability reporting under repository security settings;
`SECURITY.md` describes the private reporting route and fallback.

Dependabot checks Actions, plugin npm and Swift dependencies weekly. GRDB remains
exactly pinned; a reviewed update must commit both manifest and resolved changes.
`@opencode/plugin` is excluded from automatic updates because it must track the
installed server version. No pip dependencies are added to the reference mock.

## Releases and publishing

App and plugin releases are independent: use `app-vX.Y.Z` and `plugin-vX.Y.Z` tags,
optionally with a prerelease suffix. Release Drafter maintains the next app release
notes on main. Plugin releases are created separately; review/filter the draft notes
for the chosen component. Drafting never publishes a package or uploads an app.

`Publish app or plugin` runs on a published GitHub release or manually with an
existing release tag. It rejects arbitrary refs, requires the tagged commit to be
contained in main, and requires successful Tests (including Sonar) and CodeQL main
push runs on that exact commit. If still running, wait and rerun publishing. This
also prevents publishing an old commit that never had the new checks. No publication
has been performed or verified by adding these workflows.

Before the first release, create GitHub environments `npm` and `app-store` with
required reviewers and restrict deployment refs to the intended main release tags.
The release gate refuses to publish unless the target environment already has
required reviewers configured; it then waits for their approval. Environments and their reviewer
rules are repository settings; YAML alone does not create protection rules.

### npm plugin

Set the package version and lockfile before tagging. Configure npm trusted
publishing for `timlaing/ios-opencode-client`, workflow `publish.yml`, environment
`npm`. The workflow uses OIDC and provenance, without an npm token. An npm package
owner must establish the package/trusted-publisher configuration before its first
OIDC publication. Stable tags publish to `latest`, prerelease tags to `next`.
Typecheck, build, tests and package validation run again before publishing.

### TestFlight and App Store Connect

Create the App Store Connect app for
`uk.co.laingcorp.opencode-client.OpenCodeRemote`, team `4C8FWEBR8F`. In the
`app-store` environment configure:

- `BUILD_CERTIFICATE_BASE64`: base64 Apple Distribution certificate/private key P12.
- `P12_PASSWORD`: password protecting that P12.
- `PROVISIONING_PROFILE_BASE64`: base64 App Store distribution profile for this app.
- `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_PRIVATE_KEY`: App Store Connect API key inputs.

The profile must include the existing iCloud key-value entitlement. Signing material
uses a temporary keychain and files, removed on exit. App version comes from the tag;
CFBundleVersion is `run_number.run_attempt`. Ensure this is higher than any previously
uploaded build for that app version. Upload uses Xcode archive/export to App Store
Connect. Processing, TestFlight groups/external review, store metadata and submission
for App Review remain in App Store Connect; this workflow does not automatically
submit or release an app to customers. Run physical-device and real-host acceptance
checks from `docs/verification.md` before approving a distribution upload.

## Issue lifecycle

The daily stale workflow warns after 60 inactive days and closes after another 14,
with reason `not_planned`. `pinned`, `security` and `roadmap` are exempt. PR staling
and auto-closure are disabled. New activity removes the stale label. Apply exemptions
to tracked roadmap/device-verification work before enabling the scheduled workflow.
