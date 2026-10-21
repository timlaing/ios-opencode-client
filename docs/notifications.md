# Notifications and Cloudflare Worker design

## Release boundary

| Capability | Initial release | Later APNs release |
| --- | --- | --- |
| Local alerts on configured Wi-Fi | Removed 21 October 2026 | Remote APNs alerts |
| Cellular/VPN alone | Foreground delivery only while the app has runtime | Remote APNs alerts |
| Local Live Activity | Update while main app has runtime; show stale status afterward | Retained |
| Live Activity while main app is suspended | No continuous-update promise | APNs update/end |
| Hosted infrastructure | None required | Stateless Cloudflare Worker |
| Additional OpenCode plugin | None required | Optional push companion required for this proposed relay workflow |

Local alerts, Live Activities, and remote alerts have independent user preferences. Do not make cloud enrollment a prerequisite for notifications or core app operation.

Today, notifications come only from the conversation on screen: its terminal events banner while the app is not active, filtered by enabled alert categories, and nothing subscribes a session that is not on screen. Sessions started from this app plus sessions explicitly followed by the user are the persisted SCOPE for later delivery releases (the APNs relay) — following persists that choice and supports unfollowing.

During onboarding, present the alert-category switches (session succeeded, failed, or interrupted — all three enabled by default, so the user opts out rather than in), what content notifications may show (generic text until the privacy choice is recorded), and whether Live Activities start automatically for sessions started in the app or manually through Follow Session. Keep all choices editable in Settings. Do not automatically start an activity before the user chooses it; a banner additionally requires iOS permission and the app's own recorded consent — app preferences and Apple's notification/Live Activity permissions are separate states and both must be respected.

## Local push: removed (21 October 2026)

Local push was removed by decision: the `NEAppPushProvider` extension, the per-SSID `NEAppPushManager` configuration, per-host enablement and eligible-Wi-Fi settings, the notification pipeline (classifier, supervisor, ledger, planner), and the delivery status rows are all gone, and Apple's `app-push-provider` entitlement was never requested. `docs/local-push-implementation.md` (the Home Assistant-derived guide) was deleted in the same change.

What remains of initial delivery is app-side and foreground-honest: banners for the conversation on screen, posted while the app is not active, from live delivery only (so a reconnect never replays a backlog), covering the inactive/early-background window and never a turn that ends after suspension — specified and tested in `docs/api-contract.md` W16. A session that is not on screen has no live subscription and produces no banner. Local Live Activities follow below; the later APNs release is unaffected by this decision.


## Local Live Activities

Use ActivityKit and a native WidgetKit presentation. Initially let the user start tracking one session while the app is active. Display a concise state, elapsed time rendered on-device, and last-updated freshness. Do not fabricate a completion percentage.

Updates can only be applied while the app has runtime — iOS may suspend it seconds after it leaves the foreground. Use that honest boundary: persist/coalesce the latest update, apply it when the app runs, and set a stale deadline. A notification may announce completion while the activity remains stale until the app runs again.

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

### Alert delivery mode

With local push removed, ordinary alerts in this release are delivered only while the app has runtime (foreground banners); the later release delivers them over APNs. Delivery-mode selection and local-first fallback do not apply without a local channel to fall back from. Live Activity remote updates use their separate ActivityKit channel.

### Pricing and operations

The selected future deployment is a shared hosted relay. Users will not be required to deploy their own Worker for the distributed app. Before launch, establish the operator, funding, quotas, abuse controls, support, incident response, and behavior during outages or exhausted quotas. The app remains completely free. Direct OpenCode access remains independent of relay availability. Hosting selection does not remove the secure-enrollment work or justify storing device/session delivery state in the Worker.

Funding is explicitly undecided. An agreed operating/funding plan is a launch blocker for shared remote push, independently of technical readiness. It is not a blocker for the initial release and does not authorise charges or a paid offering.

Pricing checked on 17 October 2026: Workers Free includes 100,000 requests/day across the account and 10 ms CPU per invocation. Workers Paid starts at US$5/month and includes 10 million requests and 30 million CPU milliseconds/month. Other Cloudflare products have separate allowances and pricing.

Measure grant verification and Apple signing under cold and warm execution before selecting the free plan. Network waiting is distinct from CPU execution. Apply ingress abuse limits and CPU limits; optional edge counters are stateful infrastructure even when delivery has no database. An unused low-volume allowance is not a guarantee of free public operation.

## Verification

Initial local push: retired — removed by decision on 21 October 2026 (no extension, no entitlement, no device checklist). Remaining initial delivery and Live Activity behaviour is covered by the app suites:

- User notification permissions handled correctly.
- Local Live Activity becomes stale while suspended and reconciles when reopened.

Later Worker/APNs release:

- Deployed Worker delivers sandbox/production alerts and activity update/end to physical devices.
- Cold/warm signing, key rotation, invalid tokens, expired grants, forged signatures, payload tampering, and cross-destination attempts tested.
- Enrollment rejects unverified token ownership and unauthorized plugin bindings.
- Lost response/retry, stale update, host restart, duplicate event, and expired outbox tests pass.
- No secrets or content leaks in logs; app works normally with plugin/Worker disabled.

## Sources

- [OpenCode v2.0.25 execution events](https://github.com/anomalyco/opencode/blob/b44eea9e204024db2b480a136ece29d790d5f593/packages/schema/src/session-event.ts)
- [Apple APNs request requirements](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns)
- [Apple provider-token authentication](https://developer.apple.com/documentation/usernotifications/establishing-a-token-based-connection-to-apns?changes=_5)
- [Apple ActivityKit push](https://developer.apple.com/documentation/ActivityKit/starting-and-updating-live-activities-with-activitykit-push-notifications)
- [Workers pricing](https://developers.cloudflare.com/workers/platform/pricing/)
- [Worker secret bindings](https://developers.cloudflare.com/workers/configuration/secrets/)
- [Workers Node compatibility](https://developers.cloudflare.com/workers/configuration/compatibility-flags/#enable-nodehttp2-module)
- [Cloudflare production/local APNs transport discussion](https://github.com/cloudflare/workerd/issues/4841)
