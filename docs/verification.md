# Implementation and release verification

This report was first written on 17 October 2026 and is updated as later work is verified: the contract/mock rows date from 17 October 2026, the Home Assistant local-push row from 21 October 2026, and the push-relay server plugin row from 22 October 2026. The repository now contains a native Swift app and supporting packages. Source presence, simulator tests, hosted checks and real-host/device acceptance are separate evidence categories; none establishes successful real-host or physical-device delivery by itself.

| Check                               | Result                                                                                                                                                                                                                                                                                                                                                                  |
| ----------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Pinned API snapshot                 | v2.0.25 commit `b44eea9e204024db2b480a136ece29d790d5f593`; 550,766 bytes; SHA-256 in source-manifest.json                                                                                                                                                                                                                                                               |
| API coverage                        | All 141 operations and 256 component schemas vendored; generated route catalog and initial/later scope supplied                                                                                                                                                                                                                                                         |
| Initial mapping                     | 17 workflows; all 57 distinct initial operation IDs have a synthetic handler                                                                                                                                                                                                                                                                                            |
| Mock breadth                        | 61 operation IDs modelled in total; includes four helpers/later operations beyond initial scope                                                                                                                                                                                                                                                                         |
| Screen contract                     | S01–S20 specified; all workflow screen IDs resolve to the screen inventory                                                                                                                                                                                                                                                                                              |
| Generated fixtures                  | Seed-based projects/sessions/models/agents/integrations/Markdown/files/diffs; PNG/PDF; example HTTP cases and JSONL/SSE trace                                                                                                                                                                                                                                           |
| Automated suite                     | `python3 -m unittest discover -s tests -v`: 26 tests passed                                                                                                                                                                                                                                                                                                             |
| Regeneration                        | Seven generated outputs compared by SHA-256 across repeated generation; byte-for-byte reproducible                                                                                                                                                                                                                                                                      |
| Documentation                       | Markdown fences, local file links, heading anchors, and screen bindings checked                                                                                                                                                                                                                                                                                         |
| Licensing                           | Original mock/test/generator code marked MPL-2.0; upstream OpenAPI retains MIT licence notice                                                                                                                                                                                                                                                                           |
| Home Assistant local-push reference | RETIRED — local push removed 21 October 2026; its adaptation guide (docs/local-push-implementation.md) was deleted in the same change                                                                                                                                                                                                                                   |
| Push-relay server plugin            | 98 unit tests green (golden signing fixture, classifier, config, grants, store, engine, events pump, handlers, commands, real-loopback-HTTP relay client); loads in a real OpenCode v2.0.30 `serve` via the `.opencode/plugins/` shim — inert, with the `push` RPC and all three `/push` commands registered. Not verified against a live relay, real APNs, or a device |

Tests include schema vocabulary/fixtures, route/scope coverage, token expiry/password rotation, one-time pairing, browser/JSON redemption, project/session creation and readback, message pagination, inbox edits/conflicts, forms/approvals/stale replies, files/ranges/ETags, JSONC handling/plugin readback, MCP runtime state, attachments, SSE/recovery, generated examples, and failure/retry/waiting/unknown/duplicate scenarios. Passing these tests proves properties of the synthetic reference mock, not complete fidelity for each of 61 operations. Known simplifications are listed in the [mock guide](testing-mock.md#fidelity-and-limits).

## Remaining implementation/release evidence

- Validate the implemented Swift transport/domain/storage packages and native screens against real hosts and signed devices. Source includes session/event handling, attachments, persistence, scene coordination, iCloud preferences and notification components; implementation presence does not establish acceptance.
- Validate experimental filesystem/configuration mutations, real inbox scheduling, compaction, plugin policy/reload, attachments and reconnect behavior against disposable macOS/Linux OpenCode hosts.
- Keep native dependency locks consistent and validate rendering and dependencies on supported devices. GRDB is pinned exactly in the Swift package; package and simulator test evidence is recorded in [Xcode Cloud testing](xcode-cloud.md#local-verification--22-october-2026).
- Validate provisioning and signed-device notifications/Live Activities. The app already declares its team, bundle identifier and iCloud key-value entitlement; configuration alone does not prove device signing or delivery.
- Verify native UI/accessibility, multi-window editing ownership, retention/backup restoration, diagnostic redaction and production HTTPS trust.
- Verify release privacy disclosures and reviewer/demo arrangements. Public repository/support links already exist in the README; confirm their release suitability.

No further routine initial-version preference questions are needed. Discovery that requires a changed feature/privacy/cost/release decision must still be surfaced. The confirmed baseline archive/restore limitation is documented in the API and screen contracts. Future relay enrollment/security/funding remain separately staged.

## Xcode warning cleanup (22 October 2026)

With Xcode 27.1 (27A9275), the app and test targets build without Swift
source diagnostics after the warning cleanup. The Swift package suite passes
258 tests with no warnings. The OpenCodeRemote scheme passes all 419 tests
on each of the iPhone 18 Pro and iPad (A16) simulators running iOS 27.0,
including the UI suite's portrait/landscape rotation checks. These results do not
verify a real OpenCode host, signed-device behavior, or iCloud delivery. The
simulators have no iCloud account and log the corresponding SyncedDefaults
"No account" message; this is not evidence of successful cloud synchronization.

Remaining build-tool diagnostics are kept visible:

- The build-for-testing dependency scanner reports that `OpenCodeDomain` lacks
  `OpenCodeTransport`, although that edge is declared in `Package.swift`. This
  matches [Swift Build issue 1801](https://github.com/swiftlang/swift-build/issues/1801)
  for dynamically selected package variants in hosted test builds.
- Package framework link tasks report a macOS 27.0 sysroot while targeting the
  iOS simulator, including the unchanged pinned GRDB dependency. The logged
  Swift linker commands specify the iPhoneSimulator27.1 SDK; the origin of the
  conflicting macOS sysroot diagnostic remains unresolved.
- App Intents metadata extraction is skipped because these targets have no
  AppIntents framework dependency. No App Intents are implemented.

No warning suppression, dependency upgrade, or package linkage change was added.

## Repository and hosted evidence — checked 24 October 2026

- Current GitHub `main` was `0a172d6798eba5704f595716b49bae9c20173d04`.
  The native app and Swift packages are implemented in source, alongside the
  contract/mock package and optional server push-relay plugin.
- The recorded 22 October local run passed 258 Swift package tests and 419
  app/unit UI tests on iPhone; iPad logs recorded 416 unit and 3 UI passes.
  These are historical results, not tests rerun for this documentation update.
- GitHub checks for that exact main commit report successful Apple Cloud
  Build, Test and Analyze actions. Archive reports `action_required`.
- [GitHub workflow run 39854345815](https://github.com/timlaing/ios-opencode-client/actions/runs/39854345815)
  failed its Cloud bridge and aggregate Required CI checks; coverage/SonarQube
  was skipped. The bridge log reports `Xcode Cloud build ended with FAILED`
  and retained result artifacts. Successful individual Apple checks therefore
  do not establish a successful overall workflow or SonarQube quality gate.
- Python 3.11/3.14, plugin, SwiftLint, lint and CodeQL checks passed for that
  commit. These checks do not establish real-host or physical-device behavior.
- [PR #6](https://github.com/timlaing/ios-opencode-client/pull/6) was open
  when this section was written; it merged as `6b3a361` on 24 October 2026,
  so its warning-fix validation now belongs to `main`.

Remaining release evidence includes disposable macOS/Linux host acceptance,
physical-device operation, actual iCloud propagation, live relay/APNs delivery,
accessibility acceptance and a successful full Cloud/SonarQube workflow.

## Hosted CI — checked 25 October 2026

- Current `main` is `6b3a3619be164b19a13d43f56bf5db050efdbbe7` (PR #6, merged
  24 October 2026). Its push run
  [40143654070](https://github.com/timlaing/ios-opencode-client/actions/runs/40143654070)
  passed Python 3.11/3.14, the plugin suite, SwiftLint, lint, CodeQL and the
  Apple Build, Test, Analyze and Archive checks for that commit, but failed:
  the Cloud bridge waited 60 minutes and gave up with
  `Timed out waiting for the matching Xcode Cloud build`, so
  coverage/SonarQube was skipped and Required CI failed.
- A manual dispatch of the same workflow with the documented `cloud_run_id`
  retry input
  ([40195284145](https://github.com/timlaing/ios-opencode-client/actions/runs/40195284145),
  25 October 2026) selected that identical Cloud build (run `61e2115d…`,
  build 15) within seconds and reported a different terminal state: the
  **run-level** `completionStatus` is `ERRORED` while all four action checks
  Apple publishes for the commit (Build, Test, Analyze, Archive) report
  success. The run's Analyze action succeeded with no issues, and its 18 test
  result bundles downloaded normally, so the run-level status is the only
  reason that build cannot pass the gate. Which action Apple blames has not
  yet been observed.
- The bridge now logs its candidates when a wait times out, prints the
  per-action statuses whenever a run ends other than `SUCCEEDED`, and waits 75
  minutes (overridable with `XCODE_CLOUD_WAIT_SECONDS`) instead of 60, because
  the 24 October run had not reached `COMPLETE` within the old window. These
  are repository-side diagnostics; they do not by themselves make Required CI
  pass. A fresh build on `main` is needed to name the failing action and to
  record whether a full Cloud → SonarQube workflow can succeed.

A successful end-to-end Required CI run on `main` therefore remains
outstanding, alongside the real-host and device evidence listed above.
