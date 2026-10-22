# Implementation-package verification

This report was first written on 17 October 2026 and is updated as later work is verified: the contract/mock rows date from 17 October 2026, the Home Assistant local-push row from 21 October 2026, and the push-relay server plugin row from 22 October 2026. It does not record an implemented Swift app or successful real-host/Apple-device delivery.

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

- Implement the Swift adapter, repositories, native views, persistence, scene coordination, iCloud and background components using the supplied contracts/defaults.
- Validate experimental filesystem/configuration mutations, real inbox scheduling, compaction, plugin policy/reload, attachments and reconnect behavior against disposable macOS/Linux OpenCode hosts.
- Pin/build/test the chosen native dependencies, including the highlighter whose upstream iOS support is untested.
- Supply real signing/team/bundle configuration; perform signed-device notification/Live Activity tests.
- Verify native UI/accessibility, multi-window editing ownership, retention/backup restoration, diagnostic redaction and production HTTPS trust.
- Supply actual support/repository/privacy destinations and reviewer/demo release arrangements.

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
