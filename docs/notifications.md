# Notifications and Cloudflare Worker design

## Release boundary

| Capability | Initial release | Later APNs release |
| --- | --- | --- |
| Local alerts on configured Wi-Fi | Required | Retained |
| Main app suspended, eligible local extension active | Local notifications | Local delivery or optional APNs fallback |
| Cellular/VPN alone | No background local-push guarantee | Remote APNs alerts |
| Local Live Activity | Update while main app has runtime; show stale status afterward | Retained |
| Live Activity while main app is suspended | No continuous-update promise | APNs update/end |
| Hosted infrastructure | None required | Stateless Cloudflare Worker |
| Additional OpenCode plugin | None required for local event observation | Optional push companion required for this proposed relay workflow |

Local alerts, Live Activities, and remote alerts have independent user preferences. Do not make cloud enrollment a prerequisite for local push or core app operation.

Ordinary notification scope is sessions started from this app plus sessions explicitly followed by the user, filtered by enabled alert categories. Viewing a session does not subscribe it. Persist subscriptions for the local-push extension and support unfollowing; use the same scope for future plugin/relay delivery.

During onboarding, ask users which alert categories to enable (completion, failure, approval requests, questions), what content notifications may show, and whether Live Activities start automatically for sessions started in the app or manually through Follow Session. Keep all choices editable in Settings. Do not automatically start an activity or enable alert categories before the user configures them. App preferences and Apple's notification/Live Activity permissions must both be respected.

## Initial release: local push

Use the [Home Assistant-derived local push implementation guide](local-push-implementation.md) as the concrete lifecycle reference. It maps pinned Home Assistant iOS source/tests to our app-side managers, extension, status store and scheduler. The selected pattern is one NEAppPushManager per eligible SSID, with one lightweight OpenCode observer per enabled host inside the active provider; these are different layers.

```text
OpenCode host / native event stream
                │ Authenticated HTTPS over an eligible network
                ▼
iOS Local Push Connectivity extension
                │
                ▼
Local notification → tap → native session screen
```

### iOS implementation

Add an App Push Provider extension using `NEAppPushProvider`, configured by the main app with `NEAppPushManager` and user-selected Wi-Fi SSIDs. Request Apple's `app-push-provider` Network Extension entitlement for both targets early. Approval and physical-device validation are initial-release dependencies, not assumed capabilities.

The extension owns a lightweight authenticated connection to the existing OpenCode event stream. OpenCode uses SSE; adopting Home Assistant's approach does not require copying its WebSocket protocol or adding a new host port. Use existing OpenCode pairing tokens. Home Assistant's notification receipt-confirmation protocol has no existing OpenCode equivalent: do not invent that endpoint or claim server-driven failover in the initial version. Prototype SSE parsing, reconnect behavior, and memory use within the extension's runtime before building the wider notification UI.

Share only the necessary host credentials, notification preferences, routing identities, and deduplication/checkpoint data through a shared Keychain access group and App Group container. Use a process-safe shared store. The extension must not load the conversation renderer or a web view.

Configure per host:

- Eligible Wi-Fi SSIDs and reachable HTTPS endpoint.
- Local-push enabled/disabled.
- Completion, failure, approval, and question categories.
- All relevant sessions or explicitly followed sessions.
- Generic lock-screen text by default; session title opt-in.

Show Disabled, Not on Configured Wi-Fi, Connecting, Connected, Reconnecting, Authentication Required, and Error states. Expose last connection/event time and a test alert. Do not show Connected solely because the VPN is up.

### Event processing

1. Authenticate, subscribe, and retrieve current pending interactions/session state to establish a baseline.
2. Track explicit execution started/succeeded/failed/interrupted events. An idle state alone is not completion.
3. Observe permission and question/form changes using the pinned server contract.
4. Generate notifications for new relevant transitions. Reconnection must not alert on the entire historical backlog.
5. Use event/request identity and stable notification identifiers to deduplicate between the main app and extension. Treat delivery as best effort, not exactly once.
6. Reconcile current state after dropped events. Where the server supports a durable per-session log, retain its cursor for subscribed sessions; otherwise compare fresh authoritative snapshots.
7. Reconnect with backoff; use supported heartbeat signals and read-only health probes when needed. Handle extension timer/lifecycle callbacks.

When foregrounded on the same session, avoid duplicate banners and show the event in the native UI. Tapping an alert opens the correct host/project/session and revalidates the pending request before showing approval controls. Do not approve directly from the lock screen initially.

### Network and platform limits

Local Push Connectivity runs on configured Wi-Fi networks. A VPN connection by itself does not activate it on cellular. Reaching a remote host through a VPN while on an eligible SSID may work, but requires physical-device testing of routing and VPN lifecycle. Small additional battery use is expected from the persistent connection.

Without the entitlement or working extension, foreground-only event handling does not satisfy the initial local-push requirement. Record any entitlement denial or unsupported deployment constraint as a release blocker requiring a product decision.

### Local Live Activities

Use ActivityKit and a native WidgetKit presentation. Initially let the user start tracking one session while the app is active. Display a concise state, elapsed time rendered on-device, and last-updated freshness. Do not fabricate a completion percentage.

The Local Push extension cannot be assumed to update ActivityKit directly. Home Assistant's current implementation queues activity requests to its main app and notes that its cross-process signal cannot wake a suspended app. Use the same honest boundary: persist/coalesce the latest update, apply it when the app has runtime, and set a stale deadline. A notification may announce completion while the activity remains stale until the app runs again.

## Later release: plugin and stateless Cloudflare Worker

```text
Normal operation: iOS app ⇄ VPN ⇄ OpenCode

Remote delivery: OpenCode push plugin → HTTPS Worker → APNs → iPhone
                                                   ├─ Alert
                                                   └─ Live Activity update/end
```

### Ownership

| Component | State and responsibility |
| --- | --- |
| iOS app | Device/activity tokens, token rotation reporting, user consent, preferences, activity presentation |
| Optional host plugin | Device/session subscriptions, delivery grants, installation key, preferences, durable outbox, cursors, retries, latest activity state |
| Worker | Validate each request, translate to APNs, sign Apple provider token, send, return response |
| Worker secrets | Apple `.p8` key, Team/Key IDs as configuration, grant-issuer signing key and verification keys |

The Worker stores no durable device, session, notification, or retry database. Warm-isolate caches for imported crypto keys/provider JWTs are permitted but cannot be required for correctness. No KV, D1, or Durable Objects are required by the base design.

### Plugin behavior

Install as a normal OpenCode v2 server plugin on each participating host. Expose narrow authenticated plugin RPC methods for notification enrollment, subscriptions, preferences, status, and revocation. Do not add agent tools or a general remote-command channel.

Observe native events and normalize started, working, needs-approval, needs-answer, succeeded, failed, and interrupted states. Filter by actual session location/subscription, not only the plugin instance's location. Deduplicate across project plugin instances.

Persist delivery work before transmission. Coalesce obsolete progress updates, retain terminal events, expire stale approvals, and retry transient failures with backoff. Delivery failure must never block an OpenCode task. Keep an installation-level delivery owner/lease so multiple instances do not drain the same outbox concurrently.

### Proposed REST interface

`POST /v1/push` accepts one self-contained request:

```json
{
  "grant": "<signed destination-bound authorization>",
  "destinationToken": "<device or ActivityKit token>",
  "kind": "liveActivity",
  "eventId": "<stable event identity>",
  "expiresAt": 1792231200,
  "content": {
    "event": "update",
    "timestamp": 1792230900,
    "state": {
      "status": "needsApproval",
      "sessionReference": "<opaque reference>"
    }
  }
}
```

This is the relay's proposed schema, not an OpenCode or APNs wire payload. Sign the method, path, timestamp, and body digest with the paired plugin installation key. Define canonical encoding/versioning before implementation.

The Worker verifies the grant/signature/expiry, binds the supplied token to the grant, bounds payload size, and translates a small allowlist of event templates into APNs requests. Derive the app topic and sandbox/production destination from trusted configuration and the grant; never accept an arbitrary APNs host, URL, topic, or headers.

Respond synchronously with a normalized result and Apple's request identifier:

- `accepted`: APNs accepted the request, not proof of display/delivery.
- `invalidDestination`: plugin removes or replaces the destination token.
- `retryable`: network/Apple transient failure; plugin retries before expiry.
- `rejected`: authorization or payload failure; no automatic retry until corrected.

Preserve increasing activity timestamps and stable event identity. APNs identifiers/collapse behavior do not provide general exactly-once delivery. The plugin owns retry decisions after uncertain responses.

### Enrollment and authorization

Separate relay authorization from OpenCode credentials and from Apple's provider JWT. A signed delivery grant binds a destination-token hash, plugin public key, allowed push kinds, trusted app/environment, and expiry. It can be verified without a database.

Issuing that grant is a separate security requirement: authenticate the app/device, verify possession of the destination through an APNs challenge, and obtain signed consent for the plugin key. A public endpoint must not issue arbitrary grants simply because a caller supplies a token. App attestation alone does not prove ownership of a particular APNs token.

Before a public implementation, specify and review the enrollment challenge/attestation mechanism, replay handling, expiry, renewal, and abuse limits. Its one-use challenges or strict attestation counters may require minimal state; keep that separate from the stateless delivery path. Do not claim a fully secure, stateless enrollment protocol has already been verified.

Strictly stateless grant validation cannot provide immediate per-grant revocation or durable replay suppression. Use short-lived grants renewed through authorized enrollment. Local unsubscribe deletes the plugin's records but does not invalidate a stolen grant immediately. A denylist, revocation service, or stateful edge policy is an optional deliberate extension.

### Cloudflare implementation

- Use a TypeScript Module Worker, native `fetch`, and Web Crypto for signature verification and ES256 provider JWT signing.
- Store private keys in Worker secret bindings, not source, plugin configuration, request payloads, or logs.
- Do not rely on `node:http2`: Cloudflare documents it as a non-functional stub.
- Production `fetch` has been reported working with APNs through Cloudflare's proxy stack; local workerd behavior differs. A deployed APNs smoke test is a prerequisite, not an assumed guarantee.
- Cache imported keys and Apple authentication tokens opportunistically. Avoid generating a new provider JWT for every notification; follow Apple's refresh guidance and do not assume requests share an isolate or connection.
- Await the APNs result during the invocation. Do not use fire-and-forget work as a durable delivery queue.
- Do not cache push responses at the HTTP/CDN layer. Log only redacted outcome/latency/error metadata with short retention.
- Keep generic alert and opaque session references as defaults. Titles or richer status require user opt-in; no file contents, commands, host paths, or OpenCode credentials in relay payloads.

### Live Activity delivery

Start activities from the foreground initially; register their individual ActivityKit push tokens through the paired host connection. Observe token rotation and activity dismissal. Push-to-start is deferred from the first APNs implementation.

The Worker produces Apple's `liveactivity` topic/payload, including update/end event, timestamp, content-state, stale date, and applicable dismissal behavior. The plugin sends meaningful state transitions rather than streamed tokens. Use an on-device timer for elapsed time.

Ordinary notification permission and Live Activity authorization/settings are separate. Users may enable remote activity updates without ordinary completion banners.

### Local and APNs coexistence

Initially default each ordinary alert subscription to one configured delivery mode: local-only or APNs. Avoid claiming automatic local-first fallback without an acknowledgment protocol. To add automatic fallback, include event acknowledgments and a short-lived local-delivery lease on the plugin; use the same event identity across channels and test late acknowledgments. Live Activity remote updates use their separate ActivityKit channel.

### Pricing and operations

The selected future deployment is a shared hosted relay. Users will not be required to deploy their own Worker for the distributed app. Before launch, establish the operator, funding, quotas, abuse controls, support, incident response, and behavior during outages or exhausted quotas. The app remains completely free. Local push and direct OpenCode access remain independent of relay availability. Hosting selection does not remove the secure-enrollment work or justify storing device/session delivery state in the Worker.

Funding is explicitly undecided. An agreed operating/funding plan is a launch blocker for shared remote push, independently of technical readiness. It is not a blocker for the initial local-push release and does not authorise charges or a paid offering.

Pricing checked on 17 October 2026: Workers Free includes 100,000 requests/day across the account and 10 ms CPU per invocation. Workers Paid starts at US$5/month and includes 10 million requests and 30 million CPU milliseconds/month. Other Cloudflare products have separate allowances and pricing.

Measure grant verification and Apple signing under cold and warm execution before selecting the free plan. Network waiting is distinct from CPU execution. Apply ingress abuse limits and CPU limits; optional edge counters are stateful infrastructure even when delivery has no database. An unused low-volume allowance is not a guarantee of free public operation.

## Verification

Initial local-push release:

- Entitlement present in signed app and extension; user notification permissions handled correctly.
- Physical iPhone locked/main app suspended on configured Wi-Fi receives each enabled alert category.
- Leaving Wi-Fi disables local delivery honestly; cellular plus VPN does not claim local availability.
- VPN routing, credential expiry, host restart, reconnect, extension restart, duplicates, and stale approvals tested.
- Low memory use and battery behavior measured; multiple hosts and projects remain isolated.
- Local Live Activity becomes stale while suspended and reconciles when reopened.

Later Worker/APNs release:

- Deployed Worker delivers sandbox/production alerts and activity update/end to physical devices.
- Cold/warm signing, key rotation, invalid tokens, expired grants, forged signatures, payload tampering, and cross-destination attempts tested.
- Enrollment rejects unverified token ownership and unauthorized plugin bindings.
- Lost response/retry, stale update, host restart, duplicate event, and expired outbox tests pass.
- No secrets or content leaks in logs; app works normally with plugin/Worker disabled.

## Sources

- [Apple Local Push Connectivity](https://developer.apple.com/documentation/networkextension/local-push-connectivity?changes=__1)
- [Apple local connection lifecycle](https://developer.apple.com/documentation/networkextension/maintaining-a-reliable-network-connection)
- [Home Assistant local push](https://companion.home-assistant.io/docs/notifications/notification-local/)
- [Home Assistant ActivityKit extension handoff](https://github.com/home-assistant/iOS/blob/a0880aef231f0b0148bcb523f86756a30039ab04/Sources/Shared/Notifications/NotificationCommands/HandlerLiveActivity.swift#L37)
- [OpenCode v2.0.25 execution events](https://github.com/anomalyco/opencode/blob/b44eea9e204024db2b480a136ece29d790d5f593/packages/schema/src/session-event.ts)
- [Apple APNs request requirements](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns)
- [Apple provider-token authentication](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns?changes=_5)
- [Apple ActivityKit push](https://developer.apple.com/documentation/ActivityKit/starting-and-updating-live-activities-with-activitykit-push-notifications)
- [Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/)
- [Worker secret bindings](https://developers.cloudflare.com/workers/configuration/secrets/)
- [Workers Node compatibility](https://developers.cloudflare.com/workers/configuration/compatibility-flags/#enable-nodehttp2-module)
- [Cloudflare production/local APNs transport discussion](https://github.com/cloudflare/workerd/issues/4841)
