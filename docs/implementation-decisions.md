# Implementation decisions after web-app derivation

## Governing rule

Derive protocol behavior, payloads, state transitions, validation, and error handling from the pinned OpenCode web app and its server/client implementation wherever possible. Preserve the user's explicitly selected native UX, privacy, release scope, and retention policies when these differ from web defaults. Do not introduce a replacement protocol merely because the presentation is native.

For each workflow, record its web source, native server contract, iOS adaptation, intentional differences, and verification status. Reuse suitable algorithms, schemas, fixtures, and tests; audit licences before copying code. Web source verification does not establish native-device correctness, and a web placeholder does not establish working parity.

## Behaviors to derive rather than redesign

| Area | Existing solution to follow | Remaining adaptation/evidence |
| --- | --- | --- |
| Authentication/pairing | Existing pair command, link/QR parser, code redemption, token/password authentication, health checks, and reauthentication | Native views, Keychain, VPN/HTTPS filtering, extension access, and real-device tests; see the implementation guide |
| API contracts and identifiers | Pinned protocol schemas/client methods, host/project/session scope, errors, and actual web callers | Complete the route/action matrix and Swift decoding/encoding fixtures; selecting a new server protocol is unnecessary |
| Attachments | Model image/PDF capability routing; supported inline media up to the web's 20 MiB threshold; other/larger files staged to the server temporary upload directory through native filesystem writes | Native pickers/camera, streamed upload/progress/cancellation, mobile image conversion and lifecycle; verify server limits rather than treating the web threshold as a universal upload limit |
| Upload lifecycle | Upload tracking survives composer unmounting, supports cancellation, and exposes pending work to the composer | Navigation/window changes must preserve this behavior; app suspension is a separate iOS constraint and is not guaranteed by browser behavior |
| Connection/event recovery | Host client connection state, location-scoped event dispatch, invalidation while disconnected, and active-directory-first reconnect ordering | Trace full refresh/reducer coverage and client transport implementation; adapt scheduling to app/extension lifecycles and verify missed-event recovery |
| Draft identity and contents | Web composer scopes drafts by server/workspace/session or new-draft identity; persists structured content and separate blob references | Use native durable storage and the selected backup policy; do not inherit browser cache caps or blob-retention durations as product draft-expiry rules |
| Markdown semantics | Existing streaming Markdown, code highlighting, Mermaid handling, and local-file/session-link integration form a compatibility reference | Native rendering defaults are selected in the defaults specification; verify fixtures and preserve tap-to-load external images and system-browser external links |
| Usage and integrations | Previously inspected context calculations, cost labels, plugin directives, MCP runtime operations, and native configuration contracts | Continue tracing actual web actions; verify mutations and preserve configuration comments. Do not assume every API has a working web control |

The attachment threshold above is read from the pinned client, not independently proven by live-server boundary tests. Inline media and staged files are different delivery paths; an iOS-local path is never a valid host path by itself.

## Important web implementation gap

The inspected `runtime/server/global-sync/bootstrap.ts` has a global-config query returning an empty object with a TODO to restore loading through the V2 client. This is a narrow observation about that query, not proof that all web configuration features are absent. Trace each plugin/MCP configuration action before choosing its native implementation. Where the existing web flow is incomplete, record the gap and use verified native server capabilities rather than inventing web behavior or adding an unneeded companion service.

## Initial-release decisions with selected defaults

The user requested sensible defaults, useful configuration options, and the fullest sensible functionality within the agreed scope. The [defaults specification](implementation-defaults.md) now supplies selections for all nine areas below. Implementation and verification remain outstanding; there is no further routine preference questionnaire.

| ID | Decision | Selected default | Remaining verification |
| --- | --- | --- | --- |
| I1 | Native data stores and cross-process coordination | GRDB/SQLite; separate draft/cache/shared notification stores; Keychain for credentials | Migrations, crash/concurrency recovery, protection, and backup restoration |
| I2 | Markdown/code/diff rendering dependencies | swift-markdown with native block views; HighlighterSwift adapter; native diffs; isolated complex-block web fallback | Dependency pinning/licences, HighlighterSwift iOS support, web parity fixtures, accessibility, performance |
| I3 | iOS lifecycle and local-push implementation | Per-enabled-host native streams; bounded exponential reconnect; durable deduplication; file-backed background uploads where verified | Entitlement, physical-device lifecycle/resource tests, VPN and upload behavior |
| I4 | HTTPS trust and credential protection | System TLS trust; device-only Keychain classes based on background requirements; configurable app-lock grace | Certificate setups, redirect safety, locked-device/reboot behavior and credential restore |
| I5 | Multiple-window draft concurrency | One editing owner per draft, explicit Edit Here handoff; shared session state | No lost edits, stale-owner recovery, scene restoration and server interaction reconciliation |
| I6 | Optional iCloud settings implementation | Opt-in NSUbiquitousKeyValueStore; stable records; field-level last-edit resolution and deletion tombstones | Quota/conflict/deletion/account-change/opt-out handling |
| I7 | Native mutation conflicts and uncertain outcomes | Serial local writes; reread/compare/reapply/readback; reconcile uncertain results, no automatic replay | Actual native guarantees, concurrent clients, ambiguous writes and duplicate prevention |
| I8 | Mobile limits and cleanup | 500 MiB configurable refetchable cache, 30-day message window, progressive previews, configurable upload warnings/photo quality/draft expiry | Low-storage/large-content tests; validate selected numeric budgets and preserve full-content access |
| I9 | Release/build configuration | Xcode targets + local packages/SPM; pinned dependencies; macOS GitHub Actions; TestFlight and explicit production release | Maintainer identifiers/signing, entitlements, demo, device acceptance and source archives |

Most choices above can be resolved by engineering without changing the agreed product. Escalate only when evidence requires a feature reduction, changed privacy behavior, new cost, or a release-scope change.

## Future remote-push decisions

| ID | Decision | Boundary already selected |
| --- | --- | --- |
| R1 | Shared relay enrollment, grants, abuse controls, rotation, revocation, and replay handling | Plugin owns delivery/subscription state; Worker delivery is stateless. Determine whether secure enrollment/revocation needs limited additional state. Existing host pairing does not automatically authorise use of the public relay |
| R2 | Operator, funding, quotas, service expectations, and incident response | Shared hosted relay; completely free app; funding deliberately deferred and blocks remote-push launch, not initial local push |

## Verification work, not additional preference decisions

- Supplied: the [API contract](api-contract.md), [full route catalog](api-route-catalog.md), [screen specification](navigation-screens.md), and [generated fixtures/mock](testing-mock.md) provide initial implementation bindings. This derivation register is not a claim of full live-server parity.
- Test project/session creation, permissions/questions, configuration edits, attachments, and reconnection on disposable macOS/Linux hosts.
- Prove local push on signed physical devices before substantial UI investment. Entitlement availability is an external dependency, not an architecture preference.
- Validate the initial supported version and later upgrade compatibility. v2.0.25 remains the baseline; do not claim support for untested versions.

## Pinned source evidence

All links below use commit `b44eea9e204024db2b480a136ece29d790d5f593` (v2.0.25):

- [Attachment classification and inline threshold](https://github.com/anomalyco/opencode/blob/b44eea9e204024db2b480a136ece29d790d5f593/packages/app/src/composer/attachments/attachments.ts)
- [Attachment staging destination and upload](https://github.com/anomalyco/opencode/blob/b44eea9e204024db2b480a136ece29d790d5f593/packages/app/src/composer/attachments/destination.ts)
- [Upload lifetime and cancellation](https://github.com/anomalyco/opencode/blob/b44eea9e204024db2b480a136ece29d790d5f593/packages/app/src/composer/attachments/uploads.tsx)
- [Connection invalidation and reconnect ordering](https://github.com/anomalyco/opencode/blob/b44eea9e204024db2b480a136ece29d790d5f593/packages/app/src/runtime/server/server-sync/connection.ts)
- [Host transport and location-scoped events](https://github.com/anomalyco/opencode/blob/b44eea9e204024db2b480a136ece29d790d5f593/packages/app/src/runtime/server/client.tsx)
- [Composer identity and persistence](https://github.com/anomalyco/opencode/blob/b44eea9e204024db2b480a136ece29d790d5f593/packages/app/src/composer/persistence.tsx)
- [Structured draft/blob store](https://github.com/anomalyco/opencode/blob/b44eea9e204024db2b480a136ece29d790d5f593/packages/app/src/runtime/persistence/drafts.ts)
- [Markdown implementation](https://github.com/anomalyco/opencode/blob/b44eea9e204024db2b480a136ece29d790d5f593/packages/session-ui/src/components/markdown.tsx)
- [Global bootstrap and configuration query placeholder](https://github.com/anomalyco/opencode/blob/b44eea9e204024db2b480a136ece29d790d5f593/packages/app/src/runtime/server/global-sync/bootstrap.ts)

Pairing/authentication sources and findings are recorded in the [implementation guide](implementation-guide.md#existing-web-authentication-and-pairing).
