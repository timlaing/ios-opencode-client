# Local push implementation using Home Assistant iOS as reference

## Selected reference and scope

Use Home Assistant Companion iOS as the principal implementation example for Apple's Local Push Connectivity lifecycle, manager configuration, per-host status and notification delivery. The inspected reference is pinned to [home-assistant/iOS commit a0880aef231f0b0148bcb523f86756a30039ab04](https://github.com/home-assistant/iOS/tree/a0880aef231f0b0148bcb523f86756a30039ab04). It is an evidence snapshot, not a claim that it is the latest release.

Implement original Swift code fitted to our repositories and shared GRDB store. Follow Home Assistant's lifecycle patterns; use OpenCode v2.0.25 for authentication, events and domain state. Do not introduce HAKit, Home Assistant registration/webhook identifiers, notification commands, or a server plugin to use this approach. Actual Swift/device implementation remains outstanding.

## Source-to-implementation map

| Home Assistant reference                                                                                                                                                                                                                                                                                                                                     | Observed pattern                                                                                                                                                                         | OpenCode implementation                                                                                                                                               |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [App-side extension interface](https://github.com/home-assistant/iOS/blob/a0880aef231f0b0148bcb523f86756a30039ab04/Sources/App/Notifications/NotificationManagerLocalPushInterfaceExtension.swift)                                                                                                                                                           | Groups servers by SSID, loads existing managers, changes/saves only dirty configurations, removes obsolete managers, reloads after save, observes isActive, serialises/coalesces updates | `LocalPushConfigurationController` owns one manager per eligible SSID, with the list of enabled local host UUIDs for that SSID                                        |
| [Provider configuration](https://github.com/home-assistant/iOS/blob/a0880aef231f0b0148bcb523f86756a30039ab04/Sources/Shared/Notifications/LocalPush/PushProviderConfiguration.swift)                                                                                                                                                                         | Small Codable configuration contains server identity and state-storage key, not a copied connection client                                                                               | Versioned configuration of host UUIDs and shared-store keys; credentials remain in shared Keychain                                                                    |
| [PushProvider](https://github.com/home-assistant/iOS/blob/a0880aef231f0b0148bcb523f86756a30039ab04/Sources/Extensions/PushProvider/PushProvider.swift)                                                                                                                                                                                                       | NEAppPushProvider start/stop/timer handling, configuration observation, per-server managers, observer/task cancellation, one-shot start completion                                       | `OpenCodePushProvider` owns lightweight `HostEventObserver` instances and status publication; replaces connections on config changes and cleans up completely on stop |
| [LocalPushManager](https://github.com/home-assistant/iOS/blob/a0880aef231f0b0148bcb523f86756a30039ab04/Sources/Shared/Notifications/LocalPush/LocalPushManager.swift)                                                                                                                                                                                        | Connection/subscription status, received counts across reconnects, local notification requests, explicit receipt-confirmation protocol                                                   | OpenCode SSE observer + event classifier + `UNUserNotificationCenter`; retain counters/status, but no invented server receipt-confirmation method                     |
| [State synchronisation helper](https://github.com/home-assistant/iOS/blob/a0880aef231f0b0148bcb523f86756a30039ab04/Sources/Shared/Notifications/LocalPush/UserDefaultsValueSync.swift)                                                                                                                                                                       | Codable extension state published through shared preferences and observed by the app                                                                                                     | Shared GRDB status records with schema version/provider generation; cross-process signal is a hint to refetch, not state or a wake guarantee                          |
| [Direct local-push interface](https://github.com/home-assistant/iOS/blob/a0880aef231f0b0148bcb523f86756a30039ab04/Sources/App/Notifications/NotificationManagerLocalPushInterfaceDirect.swift)                                                                                                                                                               | Same per-server manager concept usable in a process that already has runtime                                                                                                             | Reuse event decoding/classification with foreground app transport; do not create a second redundant foreground connection just for alerts                             |
| [Live Activity command handler](https://github.com/home-assistant/iOS/blob/a0880aef231f0b0148bcb523f86756a30039ab04/Sources/Shared/Notifications/NotificationCommands/HandlerLiveActivity.swift)                                                                                                                                                             | Extension queues activity work for main app; explicitly notes Darwin signals cannot wake a suspended app                                                                                 | Coalesce activity updates/end state in App Group storage; app drains when it has runtime; stale deadline remains visible                                              |
| [Manager lifecycle tests](https://github.com/home-assistant/iOS/blob/a0880aef231f0b0148bcb523f86756a30039ab04/Tests/App/Notifications/NotificationManagerLocalPushInterfaceExtension.test.swift) / [connection/delivery tests](https://github.com/home-assistant/iOS/blob/a0880aef231f0b0148bcb523f86756a30039ab04/Tests/Shared/LocalPushManager.test.swift) | Injectable manager loading, load/save/reload failure recovery, unchanged-config no-op, stale removal, targeted recreation, unavailable transitions, receipt count preservation           | Native fake manager/store/clock/transport/notification-scheduler tests with the cases below; Python mock supplies the OpenCode event side                             |

## Architecture and ownership

```text
Main app — user settings / existing OpenCode pairing
  ├─ LocalPushConfigurationController (MainActor)
  │    └─ NEAppPushManager for each eligible SSID
  │         └─ configuration: host UUID list + schema/store identity
  ├─ foreground OpenCode event client
  └─ shared notification coordinator / ActivityKit coordinator
                         │
             App Group metadata + shared Keychain
                         │
iOS launches extension on an eligible Wi-Fi network
  └─ OpenCodePushProvider: NEAppPushProvider
       ├─ HostEventObserver(host A): authenticated GET /api/event
       ├─ HostEventObserver(host B): authenticated GET /api/event
       ├─ shared event classifier / delivery ledger
       ├─ local UNNotificationRequest
       └─ status / latest activity state → shared store
```

Grouping managers by SSID is distinct from maintaining a stream per enabled host inside the active provider. Do not create one NEAppPushManager per session or one independent manager for every host/SSID pair. Multiple hosts can share a manager; the same host can belong to several configured SSIDs. Prevent redundant host observers within a provider, and use the delivery ledger to tolerate overlapping provider lifetimes during Wi-Fi transitions.

## App-side manager configuration

Use a MainActor controller with an injected adapter for NEAppPushManager operations. No view writes manager preferences directly. Persist the user's selected host/SSID membership in the local shared store; do not sync SSIDs through the optional iCloud settings feature.

1. Build the desired SSID → enabled host UUID set from current local settings and reviewed HTTPS host addresses. Sort/deduplicate sets before comparison so list reordering does not cause saves. Exclude removed/disabled hosts and entries with no usable credential/reference.
2. `loadAllFromPreferences`, identify only this app's provider configurations, and match one manager per SSID. Do not mutate managers belonging to other providers.
3. Populate `providerBundleIdentifier`, `localizedDescription`, `matchSSIDs = [ssid]`, `isEnabled = true`, and a versioned Codable payload inside `providerConfiguration`. The payload contains identifiers/config revision only, never passwords, tokens, prompts or transcript text.
4. Diff current/desired configuration. Save only changed/new managers. Remove obsolete managed configurations when an SSID/host is removed or disabled; Home Assistant's code records that toggling isEnabled alone was not reliably stopping unwanted providers in its environment.
5. Await save/remove completions and publish failures. Reload saved managers from preferences after a short settle delay, then attach fresh active-state observations. Do not show Available merely because saving succeeded.
6. Serialise/coalesce overlapping updates. A failed load/save/reload must release the in-progress gate and service the next queued update. A queued user Disable/Remove must not be lost behind a retry.

Adopt Home Assistant's 0.5-second post-save reload delay as an initial implementation default, with injected clock/scheduler tests. This is a reference-derived starting value, not an Apple timing guarantee. Our controller should explicitly await individual save completions before scheduling the reload, rather than relying only on elapsed time.

### Controlled recovery

Home Assistant schedules immediate app-open reconciliation plus delayed retries at 10, 30 and 60 seconds, and has a targeted recovery that removes/recreates an inactive manager when retrying on its matching SSID. Adopt this bounded pattern as an app-side recovery default, separate from SSE transport reconnect backoff.

- Retry configuration reconciliation on foreground, material settings changes, and explicit Retry Local Push. Coalesce duplicate triggers. Delayed retries stop if settings change, the app loses runtime, the host becomes disabled, or the manager/stream is healthy.
- Recreate a manager only for an explicit recovery trigger when it remains inactive, the desired config is still enabled, and the current SSID is known to match. Remove the stale manager successfully before creating the replacement. An unknown SSID is not proof of a match.
- Do not recreate active managers on each server/network timeout. An active provider with a failed host stream uses transport recovery; it does not need perpetual preferences churn.
- Reading the current SSID is a convenience with platform/privacy requirements, not a prerequisite for every manual configuration step. Let users enter eligible SSIDs and show when the current network cannot be determined; do not request unrelated permissions silently or pretend an unknown SSID activates the extension.
- A recovery action never enables APNs, starts an OpenCode remote tunnel, submits a prompt, or changes server configuration.

## Provider start, configuration changes, timer and stop

The extension target uses `NSExtensionPointIdentifier = com.apple.networkextension.app-push` and the app's own principal class. Apple requires the approved app-push-provider entitlement on both app and provider targets. Verify final signed entitlements, App Group/Keychain groups and embedded extension, rather than copying a public project's build settings or provisioning profiles.

`start(completionHandler:)` decodes/validates configuration, checks shared-schema compatibility, resolves reviewed host settings/Keychain items, and starts owned observers. Guarantee the callback runs once per start attempt. Home Assistant gates startup on connection state; use that as the example when implementing bounded asynchronous startup and explicit errors. Our multi-host adaptation must isolate individual host failures: one unreachable host must not cancel another healthy host. A success callback/isActive is not evidence that every configured stream is ready; per-host status remains authoritative. Validate exact startup/timeout behavior with Apple's lifecycle and physical devices before claiming reliability.

Observe `providerConfiguration` changes and apply a diff: add new hosts, update material credential/address/config revisions, and stop removed hosts. Cancel old tasks/observers before replacing them; generation IDs prevent callbacks from stopped observers updating current state. Do not retain an entire app repository graph or UI renderer in this target.

`handleTimerEvent()` is a system-provided opportunity to check connection freshness and reconnect an eligible stopped/stale observer; do not create a second live stream for a healthy host. SSE comments count as transport liveness. Do not assume the callback runs at a chosen period or substitute an ordinary background timer for this API.

`stop(with:completionHandler:)` cancels SSE requests, backoff tasks, configuration observations and status/heartbeat work; releases notification ownership leases; publishes stopped state without deleting the user's preferences; then calls completion once. Ignore stale callbacks from the old provider generation. A stop reason should be retained in redacted diagnostics, not logged with credentials or raw event bodies.

## OpenCode-specific stream adapter

Replace Home Assistant's HAKit WebSocket subscription with authenticated OpenCode `GET /api/event`, using the existing paired token as Basic password. Use the existing OpenCode SSE framing/heartbeat and the [pinned event contract](api-contract.md#w16-events-and-reconciliation--s08s17). Decode streaming bytes incrementally; do not buffer message history or render Markdown in the extension.

Only retain the state needed for followed/app-started sessions: current execution/pending interaction identity, category/privacy preference, dedup state and freshness. The stream is host-wide; discard irrelevant event payloads early. Avoid downloading large files, model catalogs, tool outputs, previews or arbitrary attachments in notification delivery.

On connect/reconnect, establish the stream and reconcile the subscribed sessions using existing read APIs. Buffer a bounded number of relevant events during the read baseline and reconcile any overlap by event/request identity. If the bound is exceeded, discard the partial baseline and retry targeted state reads; never silently process a corrupted ordering as current state. Bootstrap shows already-pending interactions in the app without flooding historical terminal alerts. Canonical live execution success/failure and new permission/form events drive local alerts; a lost volatile-stream interval can lose alerts. Do not infer successful completion solely from absence in `/api/session/active`.

Use the chosen 1–60 second jittered SSE reconnect schedule for transient transport failures. An auth rejection becomes Re-pair Required and stops blind credential retries; credential/address changes resume through a new observer generation. Keep stream reconnect and manager recreation as separate mechanisms.

## Status and diagnostics, adapted from Home Assistant

Home Assistant shows establishing/unavailable/available with received counts and updates availability after connection loss. Use equivalent readable state, with more precise separate eligibility/delivery flags:

| Status                                | Evidence required                                                                                             |
| ------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| Disabled / Not Configured             | User disabled, no eligible SSID/host mapping, or setup incomplete                                             |
| Waiting for Eligible Wi-Fi            | Configured but no confirmed active provider on a matching network                                             |
| Unsupported / Entitlement Unavailable | Platform or signed entitlement/setup cannot support the configured provider                                   |
| Establishing                          | Active current provider generation is starting/authenticating the host stream                                 |
| Available                             | Current manager is active, host SSE is authenticated/connected, and current-generation shared status is fresh |
| Reconnecting / Unavailable            | Stream interrupted/unreachable with bounded retry and last reason                                             |
| Re-pair Required                      | Host rejected the saved credential/token                                                                      |
| Stale / Unknown                       | Only an old generation/expired freshness record is available                                                  |

Notification permission is displayed separately: a healthy stream with denied notification permission must not say “alerts working.” Track received events, relevant events, notification-scheduling success/failure, last event/heartbeat, reconnect count and redacted reason per host. Counts are diagnostic, not delivery acknowledgments or proof that a human saw a banner.

Publish status on transition and at most once every 30 seconds for heartbeat-only updates; default freshness deadline 60 seconds, to be measured on devices. Store provider generation/start identity so a stale “Available” record cannot survive a restart as live evidence. Shared-store changes/signals prompt the foreground app to refetch; no cross-process signal is assumed to wake a suspended app. Keep SSIDs/addresses redacted from default exported diagnostics.

## Notification classification and scheduling

Use the app's existing policy: notify only app-started/explicitly followed sessions, selected categories and selected content privacy. Permission requests/questions route to their actual owner IDs. Create local notifications using UNUserNotificationCenter, as Home Assistant does; reportIncomingCall/CallKit are not part of this app.

Share one classifier and delivery ledger between foreground app and extension. A stable ledger key includes host UUID, session/interaction identity and canonical transition/event ID; a stable UNNotificationRequest identifier prevents repeated requests for the same transition. Claim scheduling transactionally with a bounded owner lease, then record the scheduler result. Distinguish attempted/scheduled from displayed/delivered-to-user. If scheduling fails, record/release appropriately; on crash/restart reconcile pending/delivered notification identifiers before retrying a claimed item. This reduces duplicates but cannot guarantee exactly-once display across crashes, stream gaps and OS policy.

While the app is foreground and viewing the relevant session, suppress duplicate banners through notification presentation policy while updating the conversation. Avoid embedding transcript text, tool arguments, file content or approval secrets. A tap carries only routing identifiers and leads to reauthentication/refetch; no automatic approval or other privileged write.

### Do not copy Home Assistant's receipt protocol

Home Assistant subscribes to a notification-specific channel and sends a `localPushConfirm` message with its own webhook/confirmation identifiers after handling a notification. OpenCode's existing global SSE stream is a general volatile event feed with no equivalent delivery-acknowledgment route. Initial local push must therefore not call a fictional confirmation endpoint or claim server-side fallback/retry based on local receipt.

The initial design remains direct SSE observation without a companion plugin. If later local-first/APNs failover needs server knowledge of delivery, add an explicit acknowledged-delivery protocol to the optional companion design, with tests and documented state ownership. That is a later design; existing host pairing does not itself provide notification receipts.

## Live Activity handoff

Follow Home Assistant's shared-queue/coalescing idea, not its notification command payload. The extension persists only the latest needed ActivityKit state/end request for a tracked session. A foreground app signal and launch/foreground draining apply updates when the main app has runtime. The local provider cannot be assumed to call ActivityKit directly or awaken the main app through a Darwin signal. Show the activity's last-update/stale time; a completion notification can arrive while the activity remains stale. Real remote updates while suspended remain the later APNs channel.

## Explicit differences from the Home Assistant code

- Keep OpenCode pairing, Basic token authentication, SSE and native pending-state APIs; no HAKit/webhook registration or Home Assistant WebSocket server requirement.
- Use our process-safe shared GRDB store for transactional notification/status state rather than copying the UserDefaults synchronization mechanism unchanged.
- Keep system HTTPS trust. The reference provider Info.plist includes NSAllowsArbitraryLoads; do not copy that setting into our production targets.
- Do not import Home Assistant's general notification command dispatcher, location/sensor periodic updates, notification attachment processing or communication decoration into the minimal provider. Its extra functionality is not necessary for OpenCode alerts.
- Keep each host's stream failure isolated, validate configuration generations, await preference writes, and distinguish permission/freshness from manager activity. These are deliberate adaptations, not claims that Home Assistant uses our exact algorithms.
- The inspected Home Assistant repository is Apache-2.0. This document references behavior and source locations; no HA source was copied into our mock/app. If implementation reuses code, retain required upstream licence/notices and mark adaptations; the project's MPL choice does not erase Apache obligations.
- WHEN the approved entitlement makes the App Group container active, the shared stores (`HostStore`, `NotificationLedger` — one SQLite file per process pair) must switch from `DatabaseQueue` to `DatabasePool` (WAL) with `Configuration.observesSuspensionNotifications = true`, and the app and extension lifecycles must post GRDB's suspend/resume notifications (GRDB 7.11.1 "Sharing a Database"). A `DatabaseQueue` lock held while iOS suspends the process terminates it with `0xdead10cc` on a shared-container file. This is dormant TODAY (no App Group container exists — `SharedStoreLocation` fails closed) and must be verified on-device with both processes live; do not land it earlier, where it cannot be exercised.

## Implementation sequence and acceptance

1. Create/inject the manager-preferences adapter and desired-config planner; test grouping/diff/save/remove/reload/coalescing without needing the entitlement.
2. Build the minimal provider target with the shared OpenCode event decoder/credential access; run against the synthetic SSE mock over an eligible test setup. Only actual signed devices establish extension feasibility.
3. Implement event classifier/ledger/status publication with a fake clock/store/notification scheduler, then validate local banners on devices.
4. Integrate S17 status/retry/test UX and per-host eligible-Wi-Fi configuration; test changes while already on the network.
5. Add activity-state handoff and validate stale behavior; do not turn local push into a dependency on the later Worker.

Required native tests, derived from the inspected HA tests and adapted:

- Multiple hosts on one SSID produce one manager; one host on two SSIDs has correct memberships without redundant observer/scheduler effects.
- Identical desired state is a no-op; dirty settings await save and reload; stale managers are removed without recreating disabled hosts.
- Load/save/remove/reload failures release the coordination gate; overlapping user changes/retries coalesce without losing Disable/Remove.
- A targeted inactive-manager recovery recreates only on a confirmed matching SSID; away/unknown network does not churn preferences; failed removal does not create a duplicate.
- Start/stop completion is called once; configuration changes cancel replaced tasks; timer callbacks do not duplicate active streams; old-generation callbacks cannot restore stale status.
- A dropped stream immediately loses Available status; successful reconnect preserves diagnostic count; expired token pauses auth retries; first-unlock-after-reboot is represented accurately.
- A denied notification permission is visible separately from connection health; received count and scheduling count cannot be confused.
- Main app/extension concurrency, duplicate frames, scheduling failure and provider crash do not silently drop ledger state or create an unbounded duplicate loop.
- Selected follow/category/privacy scope applies to all local alerts; taps refetch stale approvals/forms; historical completions do not flood on bootstrap.
- Eligible Wi-Fi, Wi-Fi changes, VPN loss/recovery, host restart, multiple hosts, lock/unlock and app suspension work within measured resource budgets.
- Activity handoff updates only when main app has runtime; suspended activities become stale without claiming live updates.

The existing Python mock's SSE/notification-related scenarios exercise the OpenCode side only. Do not count its passing tests as NEAppPushManager, entitlement, extension lifecycle, or actual local-notification delivery evidence.

## Additional primary references

- [Home Assistant local-push user documentation](https://companion.home-assistant.io/docs/notifications/notification-local/)
- [Home Assistant repository licence at the reference commit](https://github.com/home-assistant/iOS/blob/a0880aef231f0b0148bcb523f86756a30039ab04/LICENSE.md)
- [Apple Local Push Connectivity and entitlement requirements](https://developer.apple.com/documentation/networkextension/local-push-connectivity)
- [Apple provider lifecycle](https://developer.apple.com/documentation/networkextension/neapppushprovider)
- [Apple reliable-connection guidance](https://developer.apple.com/documentation/networkextension/maintaining-a-reliable-network-connection)
