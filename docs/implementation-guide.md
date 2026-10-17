# Implementation guide

## Architecture

Derive existing behavior from the pinned web app and server wherever possible. Use its contracts, validation, state transitions, error handling, and tests as the starting point; adapt platform mechanisms to iOS while preserving the user's explicit product/privacy choices. Do not redesign a solved workflow or copy a web placeholder as if it were complete. The [updated decision register](implementation-decisions.md) identifies sourced behavior, remaining native choices, and verification work.

The [implementation defaults and user controls](implementation-defaults.md) resolve routine native choices and specify a full-featured implementation within the agreed staged scope. Use those defaults for storage, rendering, concurrency, security, sync, resource budgets, and release tooling. Earlier requests in this guide to specify a policy are now governed by that document; verify their behavior during implementation rather than reopening preference questions.

Use the [concrete API contract](api-contract.md), [navigation/screen specification](navigation-screens.md), and [generated-data/mock guide](testing-mock.md) for implementation. The exact pinned OpenAPI, workflow/screen bindings, generated response/SSE examples and runnable reference mock are supplied in `contracts/`, `fixtures/generated/`, and `mock/`. Their presence closes the earlier documentation-deliverable gaps; it does not close live-host, native UI or device verification gates.

```text
Native iOS/iPadOS app
  ├─ SwiftUI navigation, conversation, files, diffs, approvals, settings
  ├─ URLSession + OpenCode adapter + authoritative-state reconciliation
  ├─ Keychain credentials + protected local content/draft cache
  ├─ ActivityKit / WidgetKit local Live Activity
  └─ App Group / shared Keychain
             └─ NEAppPushProvider local-push extension [initial release]

Authenticated HTTPS over user-managed VPN
             ▼
Existing OpenCode v2.0.25 server on macOS/Linux
             └─ Optional push companion plugin [later release]
                       ▼
                Stateless Cloudflare Worker → APNs
```

Core functionality and initial local push use existing native OpenCode APIs. No management gateway or compulsory plugin. Keep the future push companion isolated behind a capability check.

## Modules and interfaces

| Module | Responsibility |
| --- | --- |
| ConnectionService | Host identity, credentials, readiness, version/capability checks |
| ProjectRepository | Directory navigation, new-folder/configuration flow, project location |
| SessionRepository | Sessions, messages, prompts, agent/model selection, stop and queue state |
| EventService | Stream decoding, cursors where supported, reconnect and reconciliation |
| InteractionRepository | Permissions, forms/questions, stale/already-answered requests |
| WorkspaceRepository | Files, previews, attachments, session/workspace diffs |
| IntegrationRepository | Native plugin/MCP inventory, state/configuration operations |
| UsageModel | Last-reported context, cumulative tokens/cost, compaction |
| NotificationCoordinator | Shared preferences, event classification, notification identity/deduplication |
| LocalPushProvider | Small background extension, host stream lifecycle, local notifications |
| LiveActivityCoordinator | Foreground start/update/end, timestamps, freshness, later push-token registration |
| EmbeddedPanelCoordinator | Specific later web panels, trusted origin, host/session isolation |

Use SwiftUI, Swift concurrency, URLSession, Keychain, GRDB/SQLite for durable drafts/cache/shared notification metadata, ActivityKit, WidgetKit, and NetworkExtension. Use separate stores and backup policies as specified in the defaults document. Do not share an unsynchronized in-memory store or assume app-only cache semantics work across processes.

For local push, follow the [Home Assistant-derived implementation guide](local-push-implementation.md): app-side manager configuration/reload/recovery, provider lifecycle, per-host health, scheduling, and native test cases are mapped to pinned HA source. Replace its WebSocket/webhook/receipt protocol with the existing OpenCode SSE/pairing contract and our shared GRDB/Keychain stores. Do not import HA's unrelated notification commands or background work.

Scope identifiers by host, project/location, and session. Preserve server identifiers for messages, events, and pending interactions. Never infer an action succeeded from an optimistic local UI update alone.

## OpenCode adapter

Freeze the schema and relevant web-client behavior at v2.0.25. Some required routes are experimental; support an explicit tested version range, display incompatibility clearly, and update the adapter with each approved server upgrade.

Trace actual browser actions to native server methods. Do not mix V1 documentation/routes with V2 source. Record source verification separately from runtime verification.

- Sessions, events, models, agents, forms, permissions, files, diffs, commands, and skills use native APIs.
- Create a new directory by writing initial project configuration through the filesystem endpoint, after checking destination/configuration existence.
- Upload phone attachments through supported native submission/staging APIs. Never send an iOS-local path as if it exists on the host.
- Persistent plugin switches edit the project JSONC source and verify runtime readback; the v2.0.25 config PATCH schema cannot perform that operation.
- MCP runtime connection state and persistent configuration are separate concepts. Expose and test the intended behavior without assuming a connect/disconnect call edits configuration.
- Structured todos are absent from the stock v2.0.25 contract and remain deferred. Do not silently add a todo plugin.

After reconnect, fetch current execution, messages, pending interactions, integrations, usage, and changes. Stream events may be missed. Do not automatically resend a prompt, approval, or configuration write whose result is uncertain; reconcile first.

## Selected setup and privacy requirements

Cache the most recent 30 days of chat history and provide Clear Cache. Eviction and clearing affect local copies only, with older history fetched from the host when needed. Specify timestamp semantics and cleanup behavior; handle unsent drafts separately.

Exclude cached conversations and attachment copies from device/cloud backups using the appropriate storage locations and backup-exclusion attributes. Store backed-up draft text and metadata separately from excluded caches. Verify the exclusions, including database sidecar files where applicable. Apply the device-only Keychain policy in the defaults specification and verify re-pairing after restoration to another device.

Show the current screen in the app-switcher preview; do not insert a neutral cover automatically on backgrounding. Define and test how this interacts with the optional app lock.

While disconnected, retain the unsent message as a draft and show that sending is unavailable. Reconnection must not submit it automatically: the user presses Send once connectivity returns. A submission whose outcome is uncertain must still be reconciled before offering a retry.

Keep drafts device-local and out of iCloud settings sync, but include draft text and metadata in device-restoration backups. Attachment copies remain excluded: restored drafts must show missing attachments and require reattachment before sending. Restoration must never submit a draft automatically. Provide a draft-retention setting independently of the 30-day conversation cache, defaulting to keep until sent or explicitly discarded. Specify any optional expiry durations, messaging, and cleanup behavior before implementation.

Support attachment selection from Files and the photo library, plus camera capture. Use native pickers and request camera access when the user invokes capture; handle denied permissions and unavailable cameras gracefully. Stage protected local copies as needed, validate model/server ingestion support, and provide preview, removal, cancellation, and retry. Never imply that previewable content is necessarily accepted by the selected model.

Open external conversation links through the default system browser. Validate URL schemes and destinations, preserve internal app navigation, and never append host credentials to external URLs.

During onboarding, ask whether notifications should use generic text or include project/session titles and event details. Store the choice for the app and local-push extension, expose it in Settings, and use generic text until a choice has been made. Apply the same preference to future remote-push payloads.

Also ask which alert categories to enable: completion, failure, approval requests, and questions. Separately ask whether Live Activities start automatically for sessions started in this app or manually through Follow Session. Persist these choices and allow changes in Settings. Until configured, do not start activities automatically or assume consent to alert categories. Explain the initial local-activity freshness limits alongside the choice; platform permissions remain separate from these app preferences.

Limit notification subscriptions to sessions started from this app and sessions explicitly followed by the user. Persist host/session identities for the app and local-push extension, support unfollowing, and apply the same scope to future companion-plugin enrollment. Do not infer a subscription merely because a session was viewed or appeared in a host event stream.

Prepare public source for the app, future companion plugin, and Worker under the selected MPL-2.0 licence. Review dependency compatibility, contributor rights, and attribution. Include the unmodified licence text and appropriate per-file notices/SPDX identifiers, preserve third-party notices, and provide an in-app Licences/Source destination with timely access to the covered source corresponding to each distributed release. Review executable EULA terms so they preserve MPL rights in source code. No mandatory royalty or extra on-screen-credit restriction is selected. See [licensing goals and Apple compatibility](monetisation.md#licensing-goals).

Supply build/deployment instructions and example configuration without credentials or private operational details. The selected future deployment is a shared hosted relay; document its operator, funding, abuse controls, quotas, support, and incident response before launch. No paid service is authorised for app users.

Offer optional iCloud sync for appearance and host addresses. Keep this narrowly scoped settings store separate from caches, attachment copies, credentials, and device-specific notification enrollment. Explain that enabling it stores host addresses in iCloud, handle signed-out/unavailable iCloud gracefully, and define conflict resolution and disabling-sync behavior. Ask for credentials separately on each device; do not sync secrets through the settings store.

Provide a reopening preference in Settings: restore the last screen/session or always open the project list, subject to the optional app lock. When restoring, revalidate access and current host/session state before sending commands; if the destination was removed or cannot be resolved, show an explanation and a route back to projects. Network unavailability should preserve an available cached view with accurate offline status.

Support multiple iPad windows in the initial release using scene-specific navigation/restoration state and shared repositories. Allow different host/project/session destinations side by side. Coordinate edits to the same session draft and reconcile execution state across windows to prevent silent overwrites or duplicate submissions. Verify window creation, closure, restoration, and simultaneous access to one session on an iPad.

Require an explicit tap before fetching external Markdown images, in both conversation roles and composer previews. Avoid background prefetches and credential forwarding to external origins.

Provide guided macOS/Linux host setup with instructions, connection checks, and actionable VPN, DNS, TLS, authentication, and version errors. This does not require an automatic remote installer.

Offer manual address/password entry, pasted pairing links, and QR scanning using the existing OpenCode web authentication/pairing protocol described below. Show the parsed host identity for review, validate fields and schemes, and require normal TLS checks. Do not introduce a custom QR schema, bypass certificate validation, or execute commands on scanning.

Implement an optional biometric app lock using LocalAuthentication. Protect the app UI without treating it as server authorization or preventing the notification extension from performing its authorised work. Specify fallback and lifecycle behavior and test on physical devices.

Keep diagnostics on-device. Do not add automatic analytics or crash-upload SDKs. Provide an explicit support-export flow with a redacted preview and the system share sheet; exclude credentials, prompts, file contents, and private host addresses by default. Apply the seven-day/5 MiB log-retention default and manual-clear/export controls, and verify deletion before release.

Provide GitHub issue links for public support and a separate private security-reporting route. Publish the actual destinations before release, make the distinction clear in-app, and keep diagnostic export separate from posting an issue. Do not automatically upload reports or create issues.

## Existing web authentication and pairing

The user selected protocol parity with the existing web app. Source inspection at pinned v2.0.25 confirms:

- `opencode pair` issues a short-lived code through authenticated `POST /api/pair`. It prints `/auth/connect/<code>` links and a QR payload containing `{ "code": "...", "urls": [...] }`. The code is single-use and expires after five minutes. Document `opencode pair --url <VPN-reachable-HTTPS-origin>` for the selected network model; verify the actual host/proxy setup before presenting it as a working user example. Do not automatically enable OpenCode's separate remote-tunnel option.
- Redeem with `GET /auth/connect/<code>` and `Accept: application/json`. The response is `{ "token": "..." }`. Browser HTML navigation instead sets a session cookie and redirects; native clients use the JSON path.
- Subsequent native requests use HTTP Basic authentication with username `opencode` and the returned token in the password position. The existing server password is also accepted through the manual fallback. This is not an OAuth/Bearer-token protocol.
- Tokens expire after 30 days in this pinned release. They are signed using a key derived from the server password; rotating that password invalidates existing tokens. The inspected token format contains an expiry and signature, not a per-device identifier. Do not promise individual-device revocation, automatic refresh, or device-scoped permissions without a verified native mechanism.
- Match the web client's distinction between invalid input, expired/already-used code, unreachable host, and rejected authentication. Preserve a redeemed token securely when a later health check fails so a retry does not attempt to consume the code again. Reauthentication must not resend an uncertain prompt or approval.
- Decode the existing multi-address QR payload and follow its address-selection behavior within the agreed VPN/HTTPS policy. Never send credentials or codes to unreviewed destinations or across untrusted redirects. Do not redeem codes during passive input previews. Match the pinned client's rejection of legacy credential-bearing `/connect` formats.

Store the resulting credential in Keychain; share only necessary access with the local-push extension. Expiry/revocation must lead to clear re-pair/sign-in status in the app and notification diagnostics. Removing a host deletes local credentials/subscriptions; do not describe that as server-side revocation.

Verify pairing, password fallback, multi-address selection, expired/spent codes, failed post-redemption health checks, token expiry, password rotation, server restart, and locked-device extension access on real hosts/devices. Protocol source verification is complete for the mechanisms above; runtime integration is not yet proven. The future shared APNs relay's enrollment/authorization remains a separate design and must not be assumed to accept OpenCode credentials.

Pinned sources: [web pairing parser/redemption](https://github.com/anomalyco/opencode/blob/b44eea9e204024db2b480a136ece29d790d5f593/packages/app/src/servers/connect/pairing.ts), [web retry handling](https://github.com/anomalyco/opencode/blob/b44eea9e204024db2b480a136ece29d790d5f593/packages/app/src/servers/connect/redeem.ts), [protocol routes](https://github.com/anomalyco/opencode/blob/b44eea9e204024db2b480a136ece29d790d5f593/packages/protocol/src/groups/server.ts), [server handler](https://github.com/anomalyco/opencode/blob/b44eea9e204024db2b480a136ece29d790d5f593/packages/server/src/handlers/server.ts), [token authentication](https://github.com/anomalyco/opencode/blob/b44eea9e204024db2b480a136ece29d790d5f593/packages/server/src/auth.ts), [pair-code lifetime](https://github.com/anomalyco/opencode/blob/b44eea9e204024db2b480a136ece29d790d5f593/packages/server/src/pairing.ts), and [CLI generation](https://github.com/anomalyco/opencode/blob/b44eea9e204024db2b480a136ece29d790d5f593/packages/cli/src/commands/handlers/pair.ts).

## Build stages

Use the supplied contracts/specifications and defaults to begin implementation, and close the early feasibility items in [design gaps and release decisions](design-review.md) before substantial UI investment. The [selected commercial model](monetisation.md) is completely free. Do not implement advertising, StoreKit purchasing, supporter products, or subscriptions.

1. **Compatibility and local-push feasibility:** capture the pinned schema and sanitized fixtures; request Apple's entitlement; prototype a physical-device Local Push extension against a disposable OpenCode project. Validate native file/configuration operations separately.
2. **Core native shell:** hosts, project creation/opening, sessions/history, credentials, local cache, and version diagnostics.
3. **Conversation and supervision:** Markdown for both roles, composer preview, thinking/tool states, attachments, agent/model selection, queue/stop behavior, approvals, questions, and usage.
4. **Workspace and integrations:** native file tree/previews, diffs, plugin/MCP controls, verified configuration preservation/readback.
5. **Initial local delivery and public release:** finish local-push preferences/status/deduplication, local Live Activities, reconnection, accessibility, demo mode, privacy/support materials, and TestFlight/device acceptance. Do not defer local push beyond this release.
6. **Staged web parity:** prefer native editing/provider/workspace controls; embed a terminal renderer or complex web panel only with a recorded reason and tests.
7. **Optional remote delivery:** implement the companion plugin and Worker according to [notification design](notifications.md), following enrollment/security and deployed-APNs feasibility checks.

## Testing and release acceptance

Use sanitized server fixtures and a mock transport for deterministic UI work. Test actual native APIs on disposable macOS/Linux projects and local/remote notification delivery on physical iPhones. Simulator success is insufficient for the notification requirements.

Initial release must demonstrate:

- New project and first session created from the phone; existing desktop session continued on the phone.
- Accurate bidirectional Markdown, stable streaming/scrolling, preserved source/drafts, and multi-file attachment handling.
- Accurate working/thinking/retry/disconnected states; questions/approvals already answered elsewhere handled correctly.
- Correct project files/diffs and usage labels; no mixing of host/session content.
- Plugin configuration edits preserve unrelated settings and comments, detect changed source before write, and verify effective state. Document concurrent-write limits of the native filesystem API.
- VPN loss, server restart, and app suspension recover without duplicate work.
- Each local-push scenario in [notifications.md](notifications.md#verification) passes with approved entitlements.
- Live Activities show freshness honestly, including when a local notification arrives while the activity cannot update.
- VoiceOver, large text, dark mode, hardware keyboard, iPhone and iPad navigation work.
- The normal app has no dependency on cloud enrollment or the later plugin.

Maintain the parity matrix with statuses: source-verified, implemented, host-tested, and device-tested. A passing API check or rendered screen does not imply parity is complete.

## Delivery artifacts

- Supplied: feature/workflow matrix and complete route catalog tied to v2.0.25; retain host/device verification status per workflow during implementation.
- Supplied: S01–S20 native screen/layout/navigation contract with populated, empty, loading, permission, disconnected and error states. Swift UI snapshots and device evidence follow implementation.
- Supplied: pinned OpenAPI schema, adapter boundaries, generated synthetic fixtures, HTTP/SSE examples, and executable reference mock/tests. No private server recordings are included.
- Host setup guide covering persistent OpenCode service, private reachability, authentication, and trusted TLS.
- Physical-device local-push evidence and entitlement/signing instructions.
- Optional plugin/Worker API design, security decisions, deployment instructions, and APNs test evidence when implemented.
- Public-release demo mode, privacy disclosure, support contact, and reviewer setup instructions.
- Completed decisions/evidence for [design gaps](design-review.md); verify the free app contains no ad SDK, purchase flow, subscription, or feature paywall.

## Remaining verification dependencies

Source inspection established native mechanisms for files, configuration, usage, events, and MCP controls. It did not establish working runtime mutations, entitlement eligibility, extension memory/battery behavior, or successful APNs delivery. These are explicit build-stage acceptance checks, not grounds for adding a mandatory management service or silently dropping requested functionality.
