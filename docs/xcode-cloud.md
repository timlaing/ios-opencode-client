# Native tests, Xcode Cloud and coverage

The committed shared `OpenCodeRemote` scheme runs app unit tests and UI tests
with code coverage enabled. Edit `OpenCodeRemote/project.yml` and regenerate
with XcodeGen to change it. Cloud builds consume the committed project; they
do not need Homebrew or XcodeGen.

`OpenCodeRemote/ci_scripts/ci_post_clone.sh` additionally runs the standalone
OpenCodeKit package tests on the macOS build host with coverage enabled. Any
failure stops the Cloud action. Its source line coverage table appears in the
post-clone log, excluding test and dependency sources. This report is separate
from the app's simulator coverage; package tests are not in the app scheme.
The script runs once per Cloud action that clones the repository.

## Activate the workflow in Apple’s service

1. Commit and push the project, shared scheme, scripts and both
   `Package.resolved` files. When changing GRDB, update the package lock and
   `OpenCodeRemote/OpenCodeRemote.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
   together. Keep the exact pin in `Package.swift`.
2. Open `OpenCodeRemote/OpenCodeRemote.xcodeproj` in Xcode. Choose
   Product → Xcode Cloud → Create Workflow (or manage an existing workflow).
   Select team `4C8FWEBR8F` and the OpenCode Client app, and grant the service
   access to the Git repository when prompted.
3. Use the `OpenCodeRemote` shared scheme and a current stable Xcode version
   that supports the Swift 6.0 package manifest and the iOS 18 minimum.
4. Add a **Test** action for iOS, Debug configuration, with an iPhone and an
   iPad simulator destination. Select available models in the Cloud UI;
   local simulator names are not necessarily available there. The UI tests
   rotate within each run to exercise portrait and landscape.
5. Enable code coverage in the workflow Test action if the UI offers an
   override. Set branch-change and pull-request triggers for the branches
   you maintain. No TestFlight distribution is required for testing.
6. Start the first build. Check both simulator test results and coverage in
   the Xcode report navigator or App Store Connect Xcode Cloud build details.
   Check the post-clone log for the separate package results/coverage table.

Workflow triggers, destinations, repository authorization and activation are
service-side settings, not fields in the XcodeGen specification. These files
prepare the project; they do not prove that a Cloud workflow has been created
or that a remote build has passed. Custom-script output is logged, not a
separately downloadable Cloud coverage artifact.

## GitHub PR checks and SonarQube

The existing [Tests workflow](../.github/workflows/tests.yml) calls the reusable
[native-tests.yml](../.github/workflows/native-tests.yml) after Python/plugin tests
on pushes to `main`, `integration`, `opencode-plugin`, PR updates and manual dispatches.
Python and plugin/classifier coverage is retained in the same Sonar analysis. The
native stage runs on the repository's `xcode-27` self-hosted runner on the
maintainer's Mac; Actions no longer starts or waits for Apple Cloud builds. The
retained bridge (`scripts/ci/xcode_cloud.mjs`) and its tests remain as historical
tooling but no workflow invokes them.

The workflow has four named checks (nested under Native tests and SonarQube):

| Check                               | Result                                                                                                                                                                                                                                             |
| ----------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| CI integration tests                | Tests the Apple API bridge and coverage conversion without credentials                                                                                                                                                                             |
| Native iOS tests                    | Runs the shared scheme's unit and UI tests on the self-hosted `xcode-27` runner for one iPhone and one iPad simulator, packages both `.xcresult` bundles as `result-N.zip` with `build.json` for the coverage stage, and runs `xcodebuild analyze` |
| Coverage and SonarQube quality gate | Runs package tests, merges native app and package line coverage, submits analysis and waits for SonarQube's quality gate                                                                                                                           |
| Required CI                         | Passes only when all three stages succeed; skipped jobs cannot produce an overall pass                                                                                                                                                             |

The native test job runs on the self-hosted macOS runner; the integration-test
and required-gate stages run on Linux, and coverage extraction, Swift package
tests and scanning also use the macOS runner. Missing simulators, failing tests,
missing coverage and scanner failures cause a failed check. `build.json` records
the source/base commit and terminal status for the coverage stage. Failed runs
retain any available test-result bundles for diagnosis.

For PRs, GitHub checks out a temporary merge of the source and destination
commits, and the native tests run on that merge tree. Analysis checks out the
same PR merge commit and verifies its two parents before importing coverage;
using the head-only checkout could assign coverage to the wrong source lines.
A base-branch advance produces a new merge commit on the next push. Branch
analysis imports only coverage whose commit equals the checked-out HEAD.

### Configure Apple and GitHub

1. GitHub checks no longer read Apple's API: the native job builds and tests
   locally, so no Cloud wait, workflow ID or bridge credential is needed for
   the Tests workflow. The Xcode Cloud workflow remains service-side
   configuration for Archive/TestFlight distribution (see
   [publishing.md](publishing.md)); its Test and Analyze actions are optional
   there and are no longer required to pass for GitHub checks.
2. Create an App Store Connect **team API key** with access to the app and
   Xcode Cloud build/artifact APIs only if the optional Apple-side automation
   (such as [Configure Xcode Cloud Analyze](../.github/workflows/xcode-cloud-configure.yml))
   should run. Save its issuer ID, key ID and `.p8` key directly as GitHub
   Actions secrets. Do not paste credentials into source, logs, PR comments
   or chat.
3. Create/import the Swift project in SonarQube, bind its GitHub repository and
   enable PR decoration. For SonarQube Cloud, disable automatic analysis so
   the scanner analysis can supply coverage. Use a plan/edition with Swift,
   branch analysis and PR analysis support. Create a project analysis token.
4. Configure the following repository settings:

   | Kind     | Name                         | Value                                                                                                       |
   | -------- | ---------------------------- | ----------------------------------------------------------------------------------------------------------- |
   | Secret   | `SONAR_TOKEN`                | Project analysis token; used by the quality-gate job                                                        |
   | Variable | `SONAR_PROJECT_KEY`          | Existing SonarQube project key (defaults to `timlaing_ios-opencode-client`)                                 |
   | Variable | `SONAR_HOST_URL`             | SonarQube Server URL, or `https://sonarcloud.io` for Cloud (default: `https://sonarcloud.io`)               |
   | Variable | `SONAR_ORGANIZATION`         | Optional override; existing Cloud organization is `timlaing`                                                |
   | Secret   | `ASC_KEY_ID`                 | Optional, Apple-side automation only: Apple's API key ID                                                    |
   | Secret   | `ASC_ISSUER_ID`              | Optional, Apple-side automation only: team issuer UUID                                                      |
   | Secret   | `ASC_PRIVATE_KEY`            | Optional, Apple-side automation only: entire downloaded `.p8` PEM content                                   |
   | Variable | `XCODE_CLOUD_WORKFLOW_ID`    | Optional, Apple-side automation only: branch workflow UUID, not the app ID or build number                  |
   | Variable | `XCODE_CLOUD_PR_WORKFLOW_ID` | Optional, Apple-side automation only: separate PR workflow UUID; defaults to the branch workflow when unset |

5. Both runners use the existing `xcode-27` label (declared in
   `.github/actionlint.yaml`) with `/Applications/Xcode.app` — the
   installation selected by `xcode-select` — selected through `DEVELOPER_DIR`.
   They live in `~/actions-runner/<repository>` and are kept running by
   per-user LaunchAgents (`com.github.actions.runner.*`), so they start at
   login and stop at logout. When Xcode is upgraded, update `DEVELOPER_DIR`
   and the runner labels together. The converter skips archives with no
   `.xcresult` and bundles with no coverage, and fails unless at least one
   bundle yields Swift line coverage. Unsafe archive entries, unreadable
   bundles and coverage that matches no repository source still fail
   extraction.
6. Merge the workflow and scripts, push a branch and open a PR. In GitHub
   branch protection/rulesets, require **Native tests and SonarQube / Required CI** and keep branches up to
   date. Avoid path filters on a required workflow: every PR needs a check result.

The SonarCloud project key, organization and URL already have repository defaults;
Apple API credentials and `XCODE_CLOUD_WORKFLOW_ID` were supplied to the
22 October main workflow run. Recheck configuration when moving repositories;
override Sonar settings only when changing projects or servers.

Secrets and service-side workflow/ruleset settings are not created by these
repository files. The first native → GitHub → SonarQube run is still needed
to validate runner compatibility, artifact availability and PR decoration.
SonarQube quality gates are configured in SonarQube; this workflow waits for
the configured gate, and does not set a new coverage threshold.

## Coverage import failure on PR #6 — 24 October 2026

Apple Cloud build `0d4328f8-4158-4002-bf07-a69b17174e22` (build 10, PR #6)
succeeded on Apple's side — Build, Test across eight destinations and Analyze
all passed — and the bridge downloaded its result artifacts. The coverage
stage then failed: of the test action's `RESULT_BUNDLE` artifacts, eight were
crash-log bundles containing no `.xcresult`, and the `build-for-testing`
bundle carries no coverage data. The converter treated both as fatal, and
**Required CI** failed with them as its only failing dependency.

`scripts/ci/coverage.py` now skips archives without an `.xcresult`
(reporting the count) and result bundles without coverage data, and fails
unless at least one bundle contributes Swift line coverage. Unsafe archive
entries, unreadable bundles, and coverage paths that match no repository
source remain hard failures. A local run of the converter against those
exact 18 downloaded artifacts completes in about three minutes, skipping
eight archives and merging line coverage from the ten `.xcresult` bundles.
The hosted quality gate's outcome for this PR is whatever the rerun of
[the Tests workflow](../.github/workflows/tests.yml) reports; no hosted
success is claimed here in advance of that result.

Fork PRs run only the credential-free integration tests. Native, SwiftLint and
analysis jobs skip, and **Required CI fails**, rather than allowing a misleading pass.
Review the contribution, then test it on a maintainer-owned branch/PR to run
the full pipeline. No `pull_request_target` workflow exposes credentials to
fork code, and no fork code executes on the self-hosted runner. Treat
same-repository workflow edits as trusted maintainer code.

### Reports and retries

- `xcode-results` retains the packaged `.xcresult` ZIPs and `build.json`
  metadata as GitHub artifacts for seven days, including available results
  from failed runs. The coverage stage imports only the `.xcresult` bundles
  that carry coverage, reporting how many archives it skipped.
- `swift-coverage` retains the Sonar generic `coverage.xml`, SwiftPM LLVM JSON,
  build metadata and scanner task metadata for 14 days. Coverage paths are
  repository-relative, and tests/dependency/generated sources are excluded.
- Phone/tablet hits and repeated records merge with logical OR per executable
  line, then combine with package coverage. Generic coverage counts unique
  source lines; Xcode's aggregated target percentages can differ. This pipeline
  imports line coverage, not branch coverage or Sonar's generic test-execution
  format. Test details remain in the downloadable `.xcresult` bundles.
- To retry a run, rerun the GitHub workflow. PR runs should be retried from the
  original PR workflow run to preserve both merge parents and PR context.
- For fork or Dependabot contributions, move reviewed changes to a trusted
  maintainer PR before expecting secret-backed analysis.

The standalone package suite runs once in the reusable workflow in GitHub because the post-clone
hook's generated coverage is not a downloadable artifact. Native app
unit/UI tests run on the `xcode-27` self-hosted runner, once per device family
(iPhone and iPad), replacing the Xcode Cloud Test actions. The retained bundles
can contain test logs/screenshots, so use the repository's normal artifact
access controls.

## SwiftLint and Xcode Analyze

The `SwiftLint` job in [linting.yml](../.github/workflows/linting.yml) runs on
pushes and same-repository PRs, without secrets; fork PRs skip it so untrusted
code never executes on the self-hosted runner. It downloads SwiftLint
**0.65.1** from the official release and verifies its pinned SHA-256. The local
runner also enforces the version in `.swiftlint-version`.

Default SwiftLint rules cover app and package source and tests. The generated
`.swiftlint-baseline.json` records **745 existing violations** (617 warnings,
128 errors). They remain existing debt; this change does not fix or disable
those rules. The strict check fails new, unbaselined violations and emits
GitHub file/line annotations. `swiftlint-report` retains the unfiltered JSON
for 14 days, including baseline findings. Review baseline changes as source
changes; do not regenerate it merely to make a failing PR green. SwiftLint
matches baseline records by source text/rule, so this is an incremental gate,
not proof that the codebase is lint-clean.

Add **SwiftLint** alongside **Native tests and SonarQube / Required CI** to
required GitHub checks. The exact-commit publishing gate also requires the
successful `Lint and documentation` workflow on `main`.

The scheme's Analyze configuration is explicit in `OpenCodeRemote/project.yml`,
and the native workflow runs `xcodebuild analyze` after the tests. An **Analyze
iOS** Cloud action (configured for iOS, `OpenCodeRemote`, Any iOS Simulator)
is optional and only matters for the Apple-side workflow; its API definition
is [analyze-action.json](../OpenCodeRemote/ci_scripts/analyze-action.json).

After merging these files and configuring the Apple API secrets/workflow ID:

1. In GitHub Actions, run **Configure Xcode Cloud Analyze** on `main` with
   `apply` unchecked to preview the change.
2. Run it again with `apply` checked to add the action or make an existing
   matching action required. It preserves other actions and start conditions,
   checks for concurrent action edits, and verifies the result by readback.
3. Alternatively, add Analyze through App Store Connect → Xcode Cloud →
   your workflow → Actions, using the settings above.

The native `xcodebuild analyze` step fails on analyzer errors; compiler
warnings appear as annotations but do not by themselves fail the check.
SwiftLint and Sonar provide the Swift-specific lint and quality rules.

Run SwiftLint locally with `scripts/ci/lint_swift.sh`. To inspect all findings,
open `reports/swiftlint-all.json`. Existing-debt maintenance should use the
pinned version and a deliberate review of the changed baseline.

The Cloud action cannot be activated without Apple credentials. Merely
committing its JSON definition or generating the scheme does not create a
service-side action.

## Run locally

```sh
OpenCodeRemote/ci_scripts/ci_post_clone.sh
```

Run the shared scheme’s Test action in Xcode once on an iPhone simulator and
once on an iPad simulator. Coverage is enabled by the scheme and is available
in each test run’s `.xcresult` bundle. For a saved bundle:

```sh
xcrun xccov view --report /absolute/path/to/TestResults.xcresult
```

Passing these tests demonstrates synthetic unit/UI behavior, not real OpenCode
host compatibility, physical-device operation or iCloud sync. See
[verification.md](verification.md) for the evidence boundary.

## References

- [Apple: Writing custom build scripts](https://developer.apple.com/documentation/xcode/writing-custom-build-scripts)
- [Apple: Making dependencies available to Xcode Cloud](https://developer.apple.com/documentation/xcode/making-dependencies-available-to-xcode-cloud)
- [Apple: Xcode Cloud build runs](https://developer.apple.com/documentation/appstoreconnectapi/build-runs)
- [Apple: Configuring requirements for merging a PR](https://developer.apple.com/documentation/xcode/configuring-requirements-for-merging-a-pull-request)
- [SonarSource: Swift coverage](https://github.com/SonarSource/sonar-scanning-examples/tree/master/swift-coverage)
- [SonarSource: Scanner action](https://github.com/SonarSource/sonarqube-scan-action)

## Local verification — 22 October 2026

- Post-clone hook: 258 package tests passed; source line coverage
  2,600 / 3,354 (77.52%), excluding tests and dependencies.
- iPhone 18 Pro simulator (iOS 27.0): 419 app unit/UI tests passed;
  app target line coverage 6,431 / 21,874 (29.40%). Test-bundle coverage
  is excluded from this app percentage.
- iPad Pro 13-inch (M5) simulator (iOS 27.0): saved Xcode logs
  record 416 unit tests and 3 UI tests passing, coverage report generation
  and `TEST FINISHED`. The tool connection closed before returning the
  structured result bundle, so no iPad coverage percentage is reported.
- No remote Xcode Cloud run has been verified by these local checks.

## Integration verification — 22 October 2026

- 15 Node bridge tests passed, including JWT signature verification, API
  pagination/retries, commit/base matching, cancellation/timeout, multi-action
  results, failure artifacts and HTTPS artifact redirects without API tokens.
- The converter processed the previously recorded iPhone `.xcresult` and
  SwiftPM export, generating valid generic coverage XML for both source roots.
  This is local artifact processing, not a completed Cloud download or upload.
- GitHub secret-name inspection confirmed `SONAR_TOKEN` exists. Apple API
  secrets and repository variables were absent. Existing SonarCloud settings
  (`timlaing_ios-opencode-client` in organization `timlaing`) are preserved.
- Current-main Python/plugin coverage imports and exact-commit release gates
  remain part of the integrated workflow. Release gating now requires the
  successful, non-skipped nested `Required CI` check.

- SwiftLint baseline check passed locally; a temporary new `force_cast`
  violation correctly failed the strict check and was removed afterward.
- Analyze configuration/annotation behavior is covered by fake-service tests;
  service-side activation still requires credentials and a workflow UUID.
- Local `xcodebuild analyze` completed successfully on the regenerated project.
  Existing compiler warnings remain (including Swift 6 actor-isolation warnings);
  this is not a claim that the app is warning-free.

## Distribution boundary

GitHub releases publish only the server plugin to npm and GitHub Packages.
iOS archives and delivery use Xcode Cloud, TestFlight and App Store Connect.
See [publishing.md](publishing.md) for the independent beta/release workflows.

## Hosted status — checked 24 October 2026

For main commit `0a172d6798eba5704f595716b49bae9c20173d04`, Apple Cloud
Build, Test and Analyze checks passed, while Archive reported `action_required`.
The [GitHub bridge run](https://github.com/timlaing/ios-opencode-client/actions/runs/39854345815)
failed with `Xcode Cloud build ended with FAILED`; Required CI failed and
coverage/SonarQube was skipped. Result bundles were retained as artifacts.
The earlier integration notes above describe setup-time observations; they do
not describe the final hosted result. A successful end-to-end quality gate
remains outstanding.

## Hosted status — checked 25 October 2026

For main commit `6b3a3619be164b19a13d43f56bf5db050efdbbe7` (PR #6, merged
24 October), every action check Apple publishes — Build, Test, Analyze and now
Archive — reports success, yet the [push run](https://github.com/timlaing/ios-opencode-client/actions/runs/40143654070)
still failed: the bridge exhausted its 60-minute wait before the run reported
`executionProgress: COMPLETE`, so Required CI failed with coverage skipped.

Re-selecting that same build with the workflow's `cloud_run_id` retry input
([run 40195284145](https://github.com/timlaing/ios-opencode-client/actions/runs/40195284145),
25 October) matched immediately and exposed the second, independent problem:
the run-level `completionStatus` for build 15 is `ERRORED` while each of its
actions reports `SUCCEEDED`, and the bridge treats any non-success run status
as a failure. Its Analyze action recorded no issues and all 18 test result
bundles downloaded, so the run status — not the tests — is what blocks the
gate. The action responsible has not been identified yet.

The repository-side response is diagnosis, not relaxation: while waiting, the
bridge reports what the workflow contains — a bounded sample of the runs it
rejected with the reason for each, beside the total scanned — and prints every
action's status as soon as a run ends other than `SUCCEEDED`, before results
are collected. That status line shows what Apple reported; it cannot identify
the cause of a run whose actions all succeed, which is what build 15 looks
like. The default wait rose from 60 to 75 minutes, and any override through the
`wait_seconds` input or the `XCODE_CLOUD_WAIT_SECONDS` variable is capped so it
cannot outlive the job timeout. None of this changes which statuses count as
success. Until a full Cloud → SonarQube run succeeds, Required CI remains
failing and this document claims no hosted pass.

## Self-hosted runner migration — 11 November 2026

Native builds and tests moved off Xcode Cloud onto two repository-scoped
self-hosted runners on the maintainer's Mac (Actions runner v2.338.2,
installed under `~/actions-runner/<repository>` and kept alive by the
per-user LaunchAgents `com.github.actions.runner.*`, so they start at login
and stop at logout). Both register the `xcode-27` label that `linting.yml`
and the reusable workflow already expected, plus `xcode`, `macOS` and
`ARM64`, and select `/Applications/Xcode.app` (Xcode 27.2) through
`DEVELOPER_DIR`.

- `.github/workflows/xcode-cloud.yml` was replaced by
  [native-tests.yml](../.github/workflows/native-tests.yml). The `cloud`
  job's Apple-API wait became a native `xcodebuild test` job — one iPhone and
  one iPad simulator selected by `scripts/ci/select_simulator.py` — that
  packages both `.xcresult` bundles as `result-N.zip` with a `build.json`
  the existing converter accepts, then runs `xcodebuild analyze`. The
  `validate`, `sonar` and `required` jobs are unchanged apart from artifact
  naming, and the Tests workflow dispatches the new file without the
  `cloud_run_id`/`wait_seconds` inputs.
- The `SwiftLint` job gained the same-repository guard the native jobs
  already carried: fork PR code no longer executes on the self-hosted runner.
- The bridge script (`scripts/ci/xcode_cloud.mjs`) and its tests remain in
  the repository but no workflow invokes them. Apple API secrets and
  `XCODE_CLOUD_*` variables are now only relevant to the optional
  Configure Xcode Cloud Analyze workflow and to distribution.
- The runner machine must be logged in for CI to run; each repository has
  its own runner, so both can execute at once without queueing behind the
  other repository's jobs.
