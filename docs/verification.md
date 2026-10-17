# Implementation-package verification

This report records the documentation/contract/mock work completed on 17 October 2026. It does not record an implemented Swift app or successful real-host/Apple-device delivery.

| Check | Result |
| --- | --- |
| Pinned API snapshot | v2.0.25 commit `b44eea9e204024db2b480a136ece29d790d5f593`; 550,766 bytes; SHA-256 in source-manifest.json |
| API coverage | All 141 operations and 256 component schemas vendored; generated route catalog and initial/later scope supplied |
| Initial mapping | 17 workflows; all 57 distinct initial operation IDs have a synthetic handler |
| Mock breadth | 61 operation IDs modelled in total; includes four helpers/later operations beyond initial scope |
| Screen contract | S01–S20 specified; all workflow screen IDs resolve to the screen inventory |
| Generated fixtures | Seed-based projects/sessions/models/agents/integrations/Markdown/files/diffs; PNG/PDF; example HTTP cases and JSONL/SSE trace |
| Automated suite | `python3 -m unittest discover -s tests -v`: 26 tests passed |
| Regeneration | Seven generated outputs compared by SHA-256 across repeated generation; byte-for-byte reproducible |
| Documentation | Markdown fences, local file links, heading anchors, and screen bindings checked |
| Licensing | Original mock/test/generator code marked MPL-2.0; upstream OpenAPI retains MIT licence notice |
| Home Assistant local-push reference | Inspected pinned manager/provider/config/state/delivery/Live Activity source and lifecycle tests; concrete adaptation guide supplied. Native lifecycle tests/device delivery are not yet executed |

Tests include schema vocabulary/fixtures, route/scope coverage, token expiry/password rotation, one-time pairing, browser/JSON redemption, project/session creation and readback, message pagination, inbox edits/conflicts, forms/approvals/stale replies, files/ranges/ETags, JSONC handling/plugin readback, MCP runtime state, attachments, SSE/recovery, generated examples, and failure/retry/waiting/unknown/duplicate scenarios. Passing these tests proves properties of the synthetic reference mock, not complete fidelity for each of 61 operations. Known simplifications are listed in the [mock guide](testing-mock.md#fidelity-and-limits).

## Remaining implementation/release evidence

- Implement the Swift adapter, repositories, native views, persistence, scene coordination, iCloud and background components using the supplied contracts/defaults.
- Validate experimental filesystem/configuration mutations, real inbox scheduling, compaction, plugin policy/reload, attachments and reconnect behavior against disposable macOS/Linux OpenCode hosts.
- Pin/build/test the chosen native dependencies, including the highlighter whose upstream iOS support is untested.
- Obtain Local Push Connectivity entitlement and supply real signing/team/bundle configuration; perform signed-device Wi-Fi/VPN/lock/reboot/notification/Live Activity tests.
- Verify native UI/accessibility, multi-window editing ownership, retention/backup restoration, diagnostic redaction and production HTTPS trust.
- Supply actual support/repository/privacy destinations and reviewer/demo release arrangements.

No further routine initial-version preference questions are needed. Discovery that requires a changed feature/privacy/cost/release decision must still be surfaced. The confirmed baseline archive/restore limitation is documented in the API and screen contracts. Future relay enrollment/security/funding remain separately staged.
