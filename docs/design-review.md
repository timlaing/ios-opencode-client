# Design gaps and release decisions

The design now includes concrete [API/workflow bindings](api-contract.md), [S01–S20 screens/navigation](navigation-screens.md), [defaults](implementation-defaults.md), and [generated fixtures/reference mock](testing-mock.md). These supply the initial implementation specification. Real-host/native-device verification and release inputs remain outstanding; documentation completeness is not evidence of a working iOS app.

## Decisions recorded

- **Host setup (1A):** guided instructions, connection checks, and troubleshooting for macOS/Linux hosts.
- **App lock (2A):** optional Face ID/Touch ID protection for the app UI.
- **Diagnostics (3A):** local-only diagnostics with user-reviewed, redacted support exports. No automatic analytics or crash uploads.
- **Local history (4A):** cache the most recent 30 days of chat history, with a Clear Cache control. Cache eviction does not delete host history; draft retention is separate.
- **Notification privacy (5C):** ask during onboarding whether notifications may show project/session titles and event details or should use generic text. Allow changing this in Settings.
- **External Markdown images (6A):** require a tap before loading an image from an external site. Do not fetch it automatically while rendering or previewing Markdown.
- **Backups (7A):** exclude cached conversations and attachment copies from device/cloud backups; retrieve available content from the host again when needed. Draft backup is covered by 22B; credentials use the device-only Keychain policy in the defaults specification.
- **App switcher (8B):** show the current screen in the app-switcher preview. Do not add a neutral privacy cover merely when backgrounding; retain the separately selected optional app lock.
- **Offline sending (9A):** preserve the draft while disconnected and require the user to press Send after reconnection. Do not automatically queue or submit offline messages.
- **Source availability (10A, final licensing choice):** open-source the app, future companion plugin, and Worker under MPL-2.0, subject to dependency compliance. This supersedes the earlier mandatory-royalty goal. See [licensing goals](monetisation.md#licensing-goals).
- **Notification categories (11C):** ask during onboarding which completion, failure, approval-request, and question alerts to enable. Allow later changes in Settings.
- **Live Activity start (12C):** ask during onboarding whether to start activities automatically for sessions started in this app or manually through Follow Session. Allow later changes in Settings.
- **Future push relay (13B):** provide a shared hosted Cloudflare Worker relay. The operator's funding, abuse controls, service limits, support, and incident response must be specified before launching remote push; the app remains completely free.
- **Settings sync (14B):** offer optional iCloud sync for appearance and host addresses. Enter credentials separately on each device; do not sync credentials through this settings feature. Conversation caches, attachment copies, drafts, and notification enrollment are outside this selected sync scope.
- **Reopening (15C):** let users choose in Settings between restoring the last screen/session and always opening the project list. When restoring, revalidate host access and session availability before interaction; provide a clear route back to projects if the previous destination is unavailable.
- **Attachment sources (16A):** support Files, the photo library, and camera capture in the initial release, subject to selected model/server format support.
- **Draft sync (17A):** keep unsent drafts local to each device; do not include them in iCloud settings sync. Device-restoration backups are permitted under 22B.
- **External links (18B):** open external chat links in the default system browser. Keep internal project/session/file navigation within the app and validate link destinations.
- **Notification scope (19A):** notify for sessions started from this app and sessions the user explicitly follows. Other sessions on a host do not automatically subscribe. Alert-category preferences still apply.
- **Draft retention (20C):** let users choose draft retention in Settings, independently of the 30-day history cache. The default is keep until sent or explicitly discarded (27A); specify any optional expiry durations, messaging, and cleanup behavior before implementation.
- **Support (21A):** use GitHub issues for public support and a separate private route for security reports. Do not direct sensitive diagnostics or security disclosures into public issues.
- **Draft backup (22B):** include unsent draft text and metadata in device backups for restoration, without enabling cross-device draft sync. Attachment copies remain excluded; restored drafts must identify missing attachments and require reattachment before sending.
- **Host entry (23B, refined):** reuse the existing OpenCode web authentication/pairing process: manual address/password entry, pasted `opencode pair` links, and its existing QR payload. Review the scanned host identity before connecting; scanning must not silently trust a certificate or execute commands. Do not invent a separate QR/enrollment protocol.
- **Relay funding (24C):** leave funding undecided and treat an agreed operating/funding plan as a launch blocker for future shared remote push. This does not block the initial local-push release.
- **Licence (25C, subsequently decided):** select MPL-2.0. App Store distribution is supported by its executable/source distinction and current Firefox iOS precedent; complete the app-specific dependency, notice, source-release, and executable-EULA review before publication. No royalty or additional mandatory on-screen-credit clause is selected.
- **iPad windows (26A):** support multiple app windows in the initial release, with different projects/sessions open side by side.
- **Default draft retention (27A):** keep drafts until sent or explicitly discarded by default; the retention setting remains configurable.

The product-preference questionnaire is complete for this high-level guide. Remaining gaps below require implementation specification, verification, or explicitly deferred release decisions rather than further preference rounds.

These choices define implementation requirements; the verification work below remains open.

## Outstanding work

Use the [web-derived implementation decision register](implementation-decisions.md) as the current list of choices. The table below tracks completion evidence; an open verification row does not mean an existing web protocol needs redesigning.

All nine initial engineering areas have documented defaults. The pinned API/workflow catalog, screen specification, fixtures and mock are supplied. Maintainer-specific deployment inputs, local-push entitlement/device evidence, dependency validation, runtime edge cases, and the later relay's secure enrollment/funding remain outstanding. No additional routine preference round is needed to proceed.

| Timing | Gap | Required work | Evidence of completion |
| --- | --- | --- | --- |
| Before substantial development | Local-push feasibility | Obtain Apple's App Push Provider entitlement and prototype native event delivery in the extension | Signed physical-device build receives alerts while locked and the main app is suspended |
| Before substantial development | Host onboarding | Define installation/service startup, trusted HTTPS, VPN reachability, authentication, and troubleshooting | A new user connects a clean macOS/Linux host without developer intervention |
| Before substantial development | Device trust and revocation | Implement the existing web pairing/password flow, document native token expiry/password rotation, and specify lost-phone response, local host removal, and actual server-enforced limits | Existing protocol source verified; native-device pairing, expiry, and recovery/revocation tests still required |
| Supplied; verify during integration | Concrete API/parity matrix | Initial workflows/screen bindings, complete pinned route/schema catalog, events/errors and baseline gaps are defined | Generated fixtures and contract/HTTP mock checks supplied; record live-host/device results per workflow; do not infer web support merely from a route |
| Before implementation | Safe configuration writes | Define stale-read detection, conflict handling, concurrent-client limits, and recovery | Disposable-host tests preserve unrelated configuration under concurrent changes |
| Before implementation | Custom plugin UI compatibility | Identify native presentations, permitted web fallbacks, unsupported panels, and later adaptation points | Representative plugin interfaces work or show an accurate capability limitation |
| Before release | Data protection | Specify caches, deletion, backups, temporary attachments, app-switcher previews, remote Markdown resources, and locked-device credentials | Written retention/data-flow policy and physical-device privacy tests |
| Before release | Performance and compatibility | Set measurable limits and budgets for histories, diffs, files, uploads, event streams, and supported server versions | Load tests, device measurements, upgrade tests, and graceful unsupported-feature behavior |
| Before release | Distribution and support | Provide reviewer-accessible demonstrations, diagnostics, licences, branding, privacy disclosures, and support arrangements | Tested review/demo setup and completed distribution checklist |
| Before remote push release | Secure Worker enrollment | Specify grant issuance, token possession, plugin binding, renewal, replay handling, and revocation | Security review plus forged/cross-device/replayed enrollment tests |

Rows requiring runtime/device evidence remain open until that evidence exists. The contract/screen/fixture/mock deliverables are now supplied. Source verification and passing synthetic tests are not proof of a working signed-device build or live host integration.

## Host setup and device trust

Guided setup is selected. Help users establish authenticated HTTPS and a working VPN through instructions and checks:

- Provide macOS and Linux instructions for starting OpenCode persistently, checking its version, keeping the host available, and updating it.
- Explain which HTTPS endpoint to enter, how certificates are trusted, and how to diagnose DNS, VPN, TLS, credentials, and incompatible-version failures separately.
- Test reconnect after sleep, reboot, token/password rotation, and server restart.
- Show the verified host identity and selected project before privileged interactions. Define the response to changed identity or credentials.
- Define Remove Host and Clear Local Data behavior, including credentials, drafts, caches, notifications, and subscriptions.
- Document the lost-phone process and any limitation on revoking one device without rotating shared host credentials.

Do not imply that app-side directory filtering or hidden controls restrict a broadly privileged server credential. Establish what the pinned OpenCode release can enforce. A biometric app lock is an optional device-side protection, not a substitute for server authorization.

## Concurrent operations and recovery

Reading configuration and then writing it leaves a race if another client edits it between those operations. Do not promise atomic conflict prevention unless the native endpoint provides it. Specify how to re-read, detect divergence, present conflicts, and recover safely within the API's actual guarantees.

Apply the same reasoning to new-project creation and uncertain submissions. Establish supported request identifiers/idempotency, reconciliation, and visible pending/unknown states. Never assume a timeout means the host performed no action.

## Privacy and device lifecycle

Decide and document:

- Define the 30-day history-cache eviction policy and Clear Cache behavior; separately specify retention for drafts, previews, thumbnails, logs, and attachment copies.
- Implement backup exclusions for cached conversations and attachment copies, include drafts in restoration backups, and apply the device-only credential policy. Verify restored drafts handle unavailable attachments and credentials require re-pairing after restoration to another device.
- Preserve the selected current-screen app-switcher preview and specify its interaction with the optional app lock. Implement the onboarding notification-privacy choice, including safe behavior before a choice is made.
- Implement tap-to-load external images and default-browser external links; untrusted content must not cause host credentials to be forwarded. Specify allowed URL schemes and handling of unsafe destinations.
- Which preview types can execute active content and how that is disabled or isolated.
- How narrow Keychain access can be while still allowing local push after the device locks. Test first unlock after reboot and subsequent locks; do not solve availability by storing credentials unprotected.
- Which local diagnostic fields are collected, their retention, and how users preview/redact a support export before explicitly sharing it.

The [selected model](monetisation.md) excludes advertising and purchasing. Diagnostics stay local, with no automatic telemetry or crash uploads. Support sharing is an explicit user action after reviewing a redacted report.

## Web parity and maintenance

The [API contract](api-contract.md), [complete route catalog](api-route-catalog.md), and machine-readable `contracts/mobile-scope.json` now supply initial workflow/method/screen/release bindings and errors, with source versus mock/runtime evidence distinguished. Continue recording host/device results. The confirmed web archive placeholder is a known unsupported baseline action, not an endpoint to invent.

Plugin enablement and backend tools do not automatically reproduce custom web interfaces. Establish a compatibility policy for GUI extensions and explain unsupported functionality without inventing native equivalents.

Define the tested OpenCode range, an upgrade test cadence, schema/event compatibility checks, and what happens when one optional capability changes. Maintain an adapter boundary and degrade individual unsupported features where safe. Do not claim arbitrary future OpenCode versions are supported.

Set budgets before implementation for paging/virtualizing long histories, limiting previews, rendering large diffs, upload size/cancellation, cache growth, extension memory, battery use, and reconnect frequency. Validate relevant IPv6-only connectivity and macOS/Linux path differences.

## Public release and product validation

- Test the value proposition with prospective users: which native workflows justify installing this app instead of using the web interface?
- Review original branding and required licence/attribution notices for every reused component. A dependency's inclusion in OpenCode does not establish its licence terms for this app.
- Supply a safe, useful demo mode and a reviewer-accessible setup. Do not require reviewers to join a private production VPN or use personal credentials.
- Identify who handles support and security reports, supported server versions, diagnostic retention, and service incidents.
- Budget for Apple membership, compatibility maintenance, support, and any future cloud services. A free hosting allowance does not remove operating obligations.
- Keep initial local push as a requirement. Entitlement denial requires an explicit product decision; foreground-only alerts are not an equivalent fallback.

## Order of work

1. Prove local push and the direct host connection on physical devices.
2. Complete onboarding, trust/revocation, and the initial API/parity matrix.
3. Specify configuration conflicts, data protection, performance budgets, and compatibility policy.
4. Implement and test the initial native workflows.
5. Validate demand and support capacity for the selected completely free model; do not add ad or purchase dependencies. Establish a sustainable operating plan before launching hosted push.
6. Close secure enrollment and deployed transport tests before the optional Worker/APNs release.

These are additional design and verification tasks. They do not introduce a mandatory management gateway or restore deferred todos/voice to the initial scope.
