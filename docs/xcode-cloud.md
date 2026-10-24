# Xcode Cloud testing and coverage

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
[xcode-cloud.yml](../.github/workflows/xcode-cloud.yml) after Python/plugin tests
on pushes to `main`, `integration`, `opencode-plugin`, PR updates and manual dispatches.
Python and plugin/classifier coverage is retained in the same Sonar analysis. Xcode Cloud
starts independently from its own GitHub integration. Actions reads Apple's API;
it does not start a second Cloud build and needs no GitHub token in Xcode Cloud.

The workflow has four named checks (nested under Native Cloud and SonarQube):

| Check | Result |
| --- | --- |
| CI integration tests | Tests the Apple API bridge and coverage conversion without credentials |
| Xcode Cloud tests | Waits up to 60 minutes for the configured Cloud workflow and exact source commit/base, fails on unsuccessful/canceled/skipped builds, downloads every test action's result bundles |
| Coverage and SonarQube quality gate | Runs package tests, merges Cloud and package line coverage, submits analysis and waits for SonarQube's quality gate |
| Required CI | Passes only when all three stages succeed; skipped jobs cannot produce an overall pass |

The API wait runs on Linux; only coverage extraction, Swift package tests and
scanning use a macOS runner. Missing credentials, missing builds, expired
artifacts, missing tests, missing coverage and scanner failures cause a failed
check. `build.json` and the GitHub step summary record the Cloud build number,
commit and terminal status. No JWTs or signed artifact download URLs are saved.
Failed Cloud runs retain any available test-result bundles for diagnosis.

For PRs, Apple builds a temporary merge of the source and destination commits.
The bridge matches **both** commits and the workflow ID. Analysis checks out
GitHub's PR merge commit and verifies its two parents before importing coverage;
using the head-only checkout could assign coverage to the wrong source lines.
A base-branch advance requires an updated PR build. Branch analysis imports only
coverage whose commit equals the checked-out HEAD.

### Configure Apple and GitHub

1. In the Cloud workflow above, enable starts for pushes to `main`, `integration`, `opencode-plugin` and for PRs
   targeting maintained branches, including changes to existing PRs. Make the
   iOS Test action **Required to Pass**, with iPhone and iPad destinations and
   coverage enabled. Give Actions enough time for Cloud's queue and tests to
   complete (the default wait is 60 minutes). Use one workflow for both starts, or set the separate PR workflow ID below.
   A PR workflow must start automatically for new and updated pull requests.
2. Create an App Store Connect **team API key** with access to the app and
   Xcode Cloud build/artifact APIs. Save its issuer ID, key ID and `.p8` key
   directly as GitHub Actions secrets. Do not paste credentials into source,
   logs, PR comments or chat.
3. Create/import the Swift project in SonarQube, bind its GitHub repository and
   enable PR decoration. For SonarQube Cloud, disable automatic analysis so
   the scanner analysis can supply coverage. Use a plan/edition with Swift,
   branch analysis and PR analysis support. Create a project analysis token.
4. Configure the following repository settings:

   | Kind | Name | Value |
   | --- | --- | --- |
   | Secret | `ASC_KEY_ID` | Apple's API key ID |
   | Secret | `ASC_ISSUER_ID` | Team issuer UUID |
   | Secret | `ASC_PRIVATE_KEY` | Entire downloaded `.p8` PEM content |
   | Secret | `SONAR_TOKEN` | Project analysis token |
   | Variable | `XCODE_CLOUD_WORKFLOW_ID` | Branch workflow UUID, not the app ID or build number |
   | Variable | `XCODE_CLOUD_PR_WORKFLOW_ID` | Optional separate PR workflow UUID; defaults to the branch workflow when unset |
   | Variable | `SONAR_PROJECT_KEY` | Existing SonarQube project key (defaults to `timlaing_ios-opencode-client`) |
   | Variable | `SONAR_HOST_URL` | SonarQube Server URL, or `https://sonarcloud.io` for Cloud (default: `https://sonarcloud.io`) |
   | Variable | `SONAR_ORGANIZATION` | Optional override; existing Cloud organization is `timlaing` |

5. Use the existing `xcode-27` runner with `/Applications/Xcode_27.0.app`
   and select compatible Xcode tools in Cloud. The custom runner label is
   declared in `.github/actionlint.yaml`. If Cloud uses a newer/beta Xcode,
   update the runner and selected installation before enabling those builds.
   An incompatible result format must fail extraction.
6. Merge the workflow and scripts, push a branch and open a PR. In GitHub
   branch protection/rulesets, require **Native Cloud and SonarQube / Required CI** and keep branches up to
   date. Also require Apple's native Cloud check if desired. Avoid path filters
   on a required workflow: every PR needs a check result.

The SonarCloud project key, organization and URL already have repository defaults;
Apple API credentials and `XCODE_CLOUD_WORKFLOW_ID` were supplied to the
22 October main workflow run. Recheck configuration when moving repositories;
override Sonar settings only when changing projects or servers.

Secrets and service-side workflow/ruleset settings are not created by these
repository files. The first real Cloud → GitHub → SonarQube run is still needed
to validate authentication, artifact availability, runner compatibility and PR
decoration. SonarQube quality gates are configured in SonarQube; this workflow
waits for the configured gate, and does not set a new coverage threshold.

Fork PRs run only the credential-free integration tests. Cloud and analysis
jobs skip, and **Required CI fails**, rather than allowing a misleading pass.
Review the contribution, then test it on a maintainer-owned branch/PR to run
the full pipeline. No `pull_request_target` workflow exposes credentials to
fork code. Treat same-repository workflow edits as trusted maintainer code.

### Reports and retries

- `xcode-cloud-results` retains downloaded `.xcresult` ZIPs and sanitized build
  metadata as GitHub artifacts for seven days, including available results
  from failed Cloud runs.
- `swift-coverage` retains the Sonar generic `coverage.xml`, SwiftPM LLVM JSON,
  build metadata and scanner task metadata for 14 days. Coverage paths are
  repository-relative, and tests/dependency/generated sources are excluded.
- Phone/tablet hits and repeated records merge with logical OR per executable
  line, then combine with package coverage. Generic coverage counts unique
  source lines; Xcode's aggregated target percentages can differ. This pipeline
  imports line coverage, not branch coverage or Sonar's generic test-execution
  format. Test details remain in the downloadable `.xcresult` bundles.
- To retry a specific Cloud build, rerun the GitHub workflow or use manual
  dispatch with `cloud_run_id`. A supplied ID must belong to the configured
  workflow and the selected branch's commit. PR runs should be retried from the
  original PR workflow run to preserve both merge parents and PR context.
- For fork or Dependabot contributions, move reviewed changes to a trusted
  maintainer PR before expecting secret-backed analysis.

The standalone package suite runs once in the reusable workflow in GitHub because the post-clone
hook's generated coverage is not a downloadable Cloud artifact. Native app
unit/UI tests run only in Xcode Cloud in this pipeline. The retained bundles
can contain test logs/screenshots, so use the repository's normal artifact
access controls.

## SwiftLint and Xcode Analyze

The `SwiftLint` job in [linting.yml](../.github/workflows/linting.yml) runs on
pushes and PRs, including fork PRs, without secrets. It downloads SwiftLint
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

Add **SwiftLint** alongside **Native Cloud and SonarQube / Required CI** to
required GitHub checks. The exact-commit publishing gate also requires the
successful `Lint and documentation` workflow on `main`.

The scheme's Analyze configuration is explicit in `OpenCodeRemote/project.yml`.
Cloud additionally needs the **Analyze iOS** action, configured for iOS,
`OpenCodeRemote`, Any iOS Simulator, and **Required to Pass**. Its API definition
is [analyze-action.json](../OpenCodeRemote/ci_scripts/analyze-action.json).

After merging these files and configuring the Apple API secrets/workflow ID:

1. In GitHub Actions, run **Configure Xcode Cloud Analyze** on `main` with
   `apply` unchecked to preview the change.
2. Run it again with `apply` checked to add the action or make an existing
   matching action required. It preserves other actions and start conditions,
   checks for concurrent action edits, and verifies the result by readback.
3. Alternatively, add Analyze through App Store Connect → Xcode Cloud →
   your workflow → Actions, using the settings above.

The result bridge requires an Analyze action to exist and succeed. Static
analyzer warnings also fail the bridge, even if Apple's action returned a
successful status. Compiler warnings appear as annotations but do not by
themselves fail the check. Cloud issues are escaped before becoming GitHub
annotations, with repository-relative source locations when available.
`xcode-cloud-results` also retains `analysis.json` for diagnosis. Analyze is
Xcode's analysis action; SwiftLint and Sonar provide the Swift-specific lint
and quality rules.

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
