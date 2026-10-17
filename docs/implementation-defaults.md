# Implementation defaults and user controls

These defaults resolve the engineering choices in the [decision register](implementation-decisions.md). They are the implementation starting point, subject to compatibility, dependency, and device verification. They are not claims of implemented or measured behavior.

Deliver the fullest sensible functionality within the agreed release scope. Derive behavior from the pinned web app/server first, then adapt to native platform capabilities. Preserve initial local push, multiple iPad windows, and the selected privacy policies. Todos, voice, advanced editing/Git/terminal stages, and later remote APNs remain in their agreed stages; completeness does not silently change those decisions. Do not reduce supported formats, history access, or controls merely to simplify implementation.

## Defaults and configuration

| Area | Default | User control |
| --- | --- | --- |
| Conversation | Render Markdown for both roles; show streaming/tool activity and preserve scroll position | Per-message source/rendered view, copy, code wrapping, and expand/collapse tool details |
| Appearance | Follow system light/dark mode and Dynamic Type; monospaced code | Light/dark/system, code font size, wrap long code lines, compact/comfortable spacing |
| Diffs | Unified on iPhone; side-by-side on wide iPad windows, unified when narrow; three context lines | Unified/side-by-side, context 3/10/all, wrap lines, search, jump between changes, copy source |
| History | Persist messages from the most recent 30 days, based on server message timestamps; older history remains available from host on demand | Keep the selected 30-day policy initially; Clear Cache and cache-size control, independent of draft deletion |
| Cache size | 500 MiB soft budget for refetchable history/previews/thumbnails; least-recently-viewed eviction within the 30-day policy | 100 MiB, 500 MiB, 1 GiB, or 2 GiB; current usage and Clear Cache. Do not silently delete drafts or pending uploads to meet this budget |
| Drafts | Keep until sent/discarded; text/metadata included in restoration backups; no draft sync | Retention: until discarded, 7, 30, or 90 days since last edit; show expiry date when enabled and confirm shortening retention if existing drafts would be removed |
| External content | External images load on tap; external links open the default browser | Per-image Load/Retry/Open action; no automatic external-image setting in the initial scope, preserving the selected privacy behavior |
| File previews | Native text, image, PDF, and Markdown previews; no execution of HTML/scripts or shell content | Source/rendered Markdown, text search, line navigation, image zoom, PDF navigation, share/save where available |
| Photo attachments | Balanced copy: fit to 2048-pixel longest edge without upscaling, JPEG quality 0.85 for opaque photographic images; preserve alpha for transparent images | Balanced/original globally and per attachment; show conversion/result size before sending. Files picker attachments remain byte-for-byte original |
| Photo metadata | Remove location metadata from generated photo/camera attachment copies; preserve originals in the user's library | Explicit Include Location option when preparing photo/camera copies. Do not claim all arbitrary Files attachments have metadata stripped |
| Uploads | Reuse web inline/staging rules; show progress, cancel, retry, duplicate detection; wait for pending attachments before sending | Warn/confirm above 50 MiB per file; adjustable warning threshold 10/50/100 MiB or no warning. This is not a hard upload limit and cannot override server/provider restrictions |
| Upload network use | Explicit uploads allowed on cellular; automatic retries paused on constrained/expensive paths when policy requires confirmation | Allow cellular uploads; Continue file uploads in background (on by default, subject to platform/VPN support); show waiting/failed states |
| iCloud settings | Off until opted in; sync appearance and host connection addresses only | Enable/disable sync, status, and explicitly remove synced settings from iCloud. Credentials, drafts, subscriptions, Wi-Fi names, and security policies do not sync |
| App lock | Off; if enabled, require device authentication after one minute away | Immediate/1/5/15 minutes; Face ID/Touch ID with device-passcode fallback. Protect foreground access while leaving authorised notification work operational |
| App switcher | Current screen, as selected | No automatic neutral cover. Explain its interaction with the optional lock; an actual locked scene displays its normal lock screen |
| Reopening | Restore last screen/session as the initial Settings value | Restore last screen/session or always open projects; scene-specific restoration on iPad |
| Notifications | Ask during onboarding for categories and content privacy; only app-started/explicitly followed sessions qualify | Category switches, generic/detailed content, follow/unfollow, per-host local-push enablement and eligible Wi-Fi setup; generic content until privacy choice is made |
| Live Activities | Ask during onboarding; do not auto-start before selection; show last-updated/stale status | Automatic for app-started sessions or manual Follow Session; Stop Following and system activity permission/status |
| Diagnostics | Local redacted logs: seven days or 5 MiB, whichever limit is reached first; no automatic upload | View, clear, preview redacted export, share manually. No switch that logs credentials or complete prompts/files |

Numeric resource limits and image settings are selected starting values, not validated performance claims. Confirm them on supported devices. Adjust engineering budgets where measurements justify it; preserve visible capability and user choices, and document material changes.

## I1: Storage and coordination

Use SQLite through GRDB for durable records, with schema-versioned migrations. This replaces the earlier tentative SwiftData cache suggestion. Use three independently managed stores: app-private backed-up draft text/metadata, excluded app-private refetchable cache, and a small excluded App Group database for host notification subscriptions, checkpoints, and deduplication. Use transactions, SQLite locking/WAL and bounded busy handling appropriate to multiple processes; do not share an in-memory singleton across the extension boundary.

Keep attachment bytes in separate excluded files with reference records. A restored draft missing bytes shows a missing-attachment chip and requires reattachment. Back up draft text directly; do not reference text chunks stored only in an excluded cache. Flush draft changes after a 300 ms debounce and on scene deactivation where runtime permits. Keep a last committed draft across crashes; never claim a final write is guaranteed after termination.

Protect app-private drafts/cache with complete file protection; use protection available after first unlock only for the minimal shared notification store and active background-upload files that require locked-device access. Remove temporary copies when no draft or task references them. Run migrations before starting extension work; show an upgrade-required state if a shared schema is incompatible rather than resetting it silently.

## I2: Native rendering and complete interactions

Use `swift-markdown` as the parsing/AST baseline and native SwiftUI/UIKit block views for selectable text, lists, tables, code, images, links, and quotes. Use HighlighterSwift as the initial syntax-highlighting dependency behind an adapter, producing native attributed text with bundled resources. Its upstream README explicitly says iOS support is untested: validate build, threading, memory, and rendering before pinning a production version. Do not choose the discontinued Highlightr merely for its familiarity. Unknown languages remain readable/copyable plain code, with no data loss.

Use native virtualised file/diff views over the server's actual diff representation. Start with unified and responsive side-by-side layouts, line numbers, search, change navigation, expansion, and source copying. Do not recompute a differently scoped diff and present it as the server result.

Derive the rich-content inventory from actual web fixtures, including streaming/incomplete fences, tables, internal file/session links, Mermaid, and any supported mathematical content. For complex diagrams/math that native rendering cannot yet preserve, default to a narrowly scoped WKWebView using bundled, dependency-reviewed rendering assets. Disable external requests, arbitrary navigation, and privileged bridges; external links still go to the system browser. Do not embed the entire chat to obtain one complex block. Provide readable source, copy, and an accurate error state if rendering fails. Record intentional unsupported content rather than silently dropping it.

Use one rendering pipeline for assistant messages, user messages, and composer preview. Preserve raw Markdown exactly. Do not execute inline HTML/scripts. Test VoiceOver, Dynamic Type, reduced motion, selection, code copy, streaming stability, and long histories. Start with at most ten presentation refreshes per second during token streaming, coalesce intermediate UI updates without dropping events, and render the final state promptly. This cadence is an internal budget, not a setting users must understand.

## I3: Background work and local delivery

Use the [Home Assistant iOS implementation reference](local-push-implementation.md) for manager lifecycle and recovery: group hosts into a manager per eligible SSID; serialise/diff preferences; await save/remove completion; reload after an initial 0.5-second settle delay; observe manager activity plus fresh per-host status. App-open recovery is immediate with bounded 10/30/60-second rechecks when runtime/eligibility permit. Recreate an inactive manager only on explicit recovery with a confirmed matching network; do not churn active managers on transport timeouts. These source-derived defaults are separate from SSE reconnect backoff and remain subject to device validation.

Use the native event contract and web reconnect/state semantics. Maintain a connection per enabled host when the system grants extension runtime; observe all configured enabled hosts rather than silently imposing a product-level host cap. Measure multiple-host resource use early; if an actual platform limit appears, surface it and resolve the product impact explicitly.

For transient failures, start with reconnect delays of 1, 2, 4, 8, 16, 32, then 60 seconds with 20% jitter, unless web/server semantics prescribe otherwise. Reattempt promptly after a real reachability change without creating duplicate connections. Stop authentication-failure retry loops and show Re-pair Required. Do not automatically retry commands, approvals, or configuration writes.

Deduplicate notifications with stable web/server-derived event/run identities, persisted for seven days with a 10,000-record storage ceiling; validate that identity construction distinguishes genuine repeated events. On reconnect, prioritise visible/followed sessions and reconcile authoritative state. Do not emit a backlog of historical completion alerts.

Use file-backed background URLSession upload tasks where the existing upload endpoint and VPN configuration pass tests. This continues transfer only, never automatically sends a prompt after a suspended upload finishes. Do not claim arbitrary upload resume/range support from the raw-write endpoint. On failure, reconcile task/path state before offering retry; retain the draft. No ordinary background timer substitutes for Local Push Connectivity. Local Live Activities remain explicitly stale when main-app runtime is unavailable.

## I4: Security and host lifecycle

Use system TLS trust with valid public certificates or a user-installed trusted private CA. No Trust Any Certificate or Disable TLS Validation option. Pairing remains the existing OpenCode protocol. Block cross-origin credential forwarding and unexpected pairing redirects; revalidate a changed address before attaching credentials. A display name or synced address is not cryptographic host identity.

Use device-only, non-synchronising Keychain items. Default to WhenUnlockedThisDeviceOnly for foreground-only host credentials and AfterFirstUnlockThisDeviceOnly when local-push/background-upload access is enabled for that host. Share only required items with the extension. Require re-pairing after restoration to another device; there is no credential-backup toggle. Test reboot-before-first-unlock, subsequent locks, disabled background access, and the resulting failure/status flows.

The optional app lock protects UI access; do not attach a biometric requirement to the same Keychain read needed by background notification delivery. Keep the selected current-screen switcher behavior. Removing a host clears its local credential, subscription, cached history, and related pending work after explaining effects on drafts; require explicit confirmation before discarding unsent drafts. Offer to retain local draft text for manual recovery. Remove Host does not rotate server credentials or revoke other clients.

## I5: iPad windows

Keep navigation/restoration scene-specific and session/execution data shared. Default to one editing owner per host/project/session draft. Other windows can read it live and use an explicit Edit Here action, which commits the old owner's pending edits before transferring ownership. Never silently discard edits. Release ownership on scene destruction and recover stale ownership after a crash using process/scene state; preserve the durable draft. No multi-writer collaborative editor is required initially. Cross-window approval actions reconcile against the server so an already-answered request cannot be accepted twice locally.

## I6: Optional iCloud settings

Use NSUbiquitousKeyValueStore for the small selected settings scope; a full CloudKit database is unnecessary initially. Use stable host UUIDs and versioned per-host/per-preference records. Identical normalised addresses are offered for merging, never silently merged with another credential identity. Default conflict resolution is last recorded edit per field, with modification time and deterministic device-ID tie-breaking; this is eventually consistent and depends on device clocks, not a distributed ordering guarantee. Keep deletion tombstones until explicitly clearing synced settings to avoid resurrecting removed entries.

Do not put credentials, pairing codes, authorization-bearing URLs, notification enrollment, drafts, or attachment references in this store. Strip URL userinfo/query/fragment before accepting a host address. Handle Apple's KVS quota failures without losing local edits; report sync status. On sign-out/account change, pause sync and require confirmation before uploading existing local addresses to a newly selected account. Turning sync off keeps local settings and stops applying cloud changes; a separate confirmed Clear Synced Settings action removes cloud records. Remote host deletion removes the address from the synced list, but asks before removing device-local drafts or credentials.

## I7: Mutations and recovery

Serialise local writes per host/configuration target, preserve JSONC comments and unrelated keys, re-read before committing, and verify effective state afterward. If content changed, show a diff and offer Reload or Reapply to Latest; no silent overwrite option. A re-read is not atomic conflict prevention against other clients. Use native version checks/request identifiers only when the verified endpoint supports them.

For uncertain prompt, approval, project-creation, or configuration outcomes, show Checking Result and reconcile authoritative state. If ambiguity remains, retain the draft/change and require an explicit next action. Never fabricate an exactly-once guarantee or automatically resend. Ordinary connected-session queuing still follows existing web/server behavior; offline drafts remain manual-send as selected.

## I8: Performance, cleanup, and limits

Use server pagination when available and progressive client presentation otherwise; never invent pagination parameters or imply a partial download is the full history. Initially present 50 recent messages, then Load Earlier without a hard conversation-length cap. Collapse long tool output with Expand/Copy/Save controls, retaining full available content.

Start text previews at 1 MiB or 10,000 lines and diffs at 5,000 displayed changed lines before an explicit Load More/Large File action. These are progressive-rendering thresholds, not truncation or upload limits. Avoid decoding entire huge files into memory where the API can stream/range; where it cannot, show the actual constraint and provide save/share options. Never present an incomplete diff as complete.

Persist messages only within the selected 30-day server-timestamp window. Older messages can be fetched and viewed without extending their persistent retention. Prune on launch/foreground and after writes when runtime allows, not through a promised daily background job. Size eviction removes refetchable least-recently-viewed content; drafts are managed separately. Clear Cache removes refetchable local data only. Clear All Local Data explicitly lists drafts/credentials/subscriptions and requires confirmation. Keep server files/history untouched by local cleanup. Do not automatically delete staged host uploads without a verified safe ownership/reference/retention contract.

## I9: Build and release

Use an Xcode project with app, local-push extension, and WidgetKit/Live Activity targets, plus local Swift packages for shared domain/transport/storage code. Use Swift Package Manager, pin exact resolved dependencies, and commit Package.resolved. Keep rendering dependencies out of the push extension. Use separate development/production identifiers and configuration; actual team, bundle IDs, repository URLs, and support destinations are deployment inputs supplied by the maintainer, never fabricated.

Use GitHub Actions on macOS for build, unit/contract tests, simulator UI smoke tests, dependency/licence checks, and artefact creation. Keep physical-device notification, multi-window, VPN, and accessibility checks as release acceptance gates. Send reviewed builds to TestFlight; production App Store releases remain explicit maintainer actions. Preserve an immutable source tag/archive for each distributed binary and in-app licence/source links. No signing keys or APNs keys belong in repository files or diagnostics.

Support only the verified v2.0.25 baseline initially. Treat another version as unverified rather than assuming failure: run capability checks, clearly label unsupported functions, permit proven read-only behavior where safe, and block unverified mutations by default. Do not expose a Force Unsupported Writes toggle. Expand the tested range after contract/device checks.

## Future relay defaults

Remote push stays off and unenrolled initially. Design shared-relay authorization around an installation key, app-mediated consent, token binding, short-lived scoped grants, request signatures, and ingress abuse controls. Never send the host password/session token to the relay. Default visible payload content follows the user's privacy setting, with only routing identifiers and required event metadata; no prompts, file contents, or approval secrets.

Keep delivery/subscription/outbox/retry state on the optional plugin. Keep APNs delivery stateless in the Worker. Treat enrollment/replay/immediate-revocation state as a separately justified exception if secure design requires it; do not promise secure stateless enrollment before proof. These are design defaults, not a completed security protocol. Secure enrollment and deployed APNs tests remain gates. Operator/funding remain explicitly deferred and block remote-push launch; no budget, billing account, or paid service is authorised here.

## Settings boundaries

Expose settings for user outcomes, grouped into Appearance, Connections, Privacy, Storage, Attachments, Notifications, and Advanced Diagnostics. Per-host settings override relevant device defaults. Keep protocol choice, database selection, synchronization algorithms, file-protection classes, and concurrency locking internal. Never expose switches to disable TLS checks, ignore configuration conflicts, resend uncertain mutations automatically, or log secrets. Settings changes are reversible where possible, explain their scope, and do not silently affect other devices when they are not in the selected sync scope.

## Primary references

- [GRDB toolkit and documentation](https://github.com/groue/GRDB.swift)
- [Swift Markdown parser](https://github.com/swiftlang/swift-markdown)
- [HighlighterSwift README, including untested iOS support](https://github.com/smittytone/HighlighterSwift)
- [Apple: background transfers and file-backed upload constraints](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background)
- [Apple: device-only Keychain access](https://developer.apple.com/documentation/security/ksecattraccessibleafterfirstunlockthisdeviceonly)
- [Apple: iCloud key-value settings storage and quotas](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/UserDefaults/StoringPreferenceDatainiCloud/StoringPreferenceDatainiCloud.html)
- [Apple: Local Push provider](https://developer.apple.com/documentation/networkextension/neapppushprovider)

Web-specific source evidence remains in the [derivation register](implementation-decisions.md#pinned-source-evidence).
