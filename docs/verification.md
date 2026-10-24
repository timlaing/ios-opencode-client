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
- [PR #6](https://github.com/timlaing/ios-opencode-client/pull/6) remains open
  for Swift compiler warning fixes. Its recorded validation belongs to its
  branch and must not be attributed to main before merge.

Remaining release evidence includes disposable macOS/Linux host acceptance,
physical-device operation, actual iCloud propagation, live relay/APNs delivery,
accessibility acceptance and a successful full Cloud/SonarQube workflow.
