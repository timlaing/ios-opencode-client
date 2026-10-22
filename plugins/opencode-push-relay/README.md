# opencode-push-relay

OpenCode **server plugin** that registers this host with an
[apns-push-relay](../../docs/notifications.md) instance and delivers
session/permission notifications to paired iOS clients over APNs.

Status: implemented and unit-tested (96 tests) against a fake relay and the
relay's golden signing fixture, and verified to load in a real OpenCode
v2.0.30 server (see [Loading](#loading-verified-against-opencode-v2030)).
**Not yet verified against a live relay or device** — see
`docs/verification.md` in the repo root.

## Behavior

- **Inert until configured.** With `relayUrl`/`app` unset the plugin loads
  commands and the RPC but performs no registration and no relay traffic;
  `/push-status` explains what is missing.
- **Registration.** On startup (when configured) the plugin registers this
  host as a relay tenant (`POST /v1/register`), generates its Ed25519 signing
  keypair, and re-registers automatically if the binding vanished from the
  relay (idle-expiry or operator revocation). Paired devices are flagged for
  re-enrollment whenever the binding changes.
- **Pairing.** The iOS app reads tenant info through the `push` RPC
  (`info`), obtains a grant from the relay's enrollment flow, and delivers it
  via `enroll`. The plugin cross-checks the grant's `ten`/`app`/`tpk`/`tok`
  claims against the current binding, then verifies the signature **through
  the relay** (a signed `POST /v1/enroll/renew` — v1 never ships the
  grant-issuer key to tenants) and stores the relay's re-issued grant.
- **Delivery.** The host event stream is classified (mirroring the iOS app's
  local `NotificationClassifier`) into category-only pushes with a routing
  `sealed` blob; a durable outbox persists items before transmission, a
  single installation-level lease gates draining, transients back off
  exponentially, and grants renew at half-life via `POST /v1/enroll/renew`.
  The event subscription is pumped: if the stream ends or throws, the plugin
  resubscribes (capped backoff) instead of going silent for the process
  lifetime. Each device's own `contentLevel` pref is applied when its copy of
  a notification is built. Overlapping `tick()` calls inside one instance are
  serialised (an enqueue's kick mid-drain can never double-send), and every
  relay call carries a bounded 15 s timeout that degrades to a retryable
  status-0 error.
- **Rotation.** `/push-key-rotate` calls `POST /v1/rotate` (proof-of-
  possession, spec §2.7): token + signing key are replaced atomically and
  paired devices re-enroll. Before any device has enrolled, rotation only
  swaps the local keypair.

## Options (`plugins[].options` in opencode.json(c))

| Option            | Default             | Notes                                                                             |
| ----------------- | ------------------- | --------------------------------------------------------------------------------- |
| `relayUrl`        | _(required)_        | Relay base URL, no trailing slash; `https://` except loopback; no query/fragment. |
| `app`             | _(required)_        | Relay App id (operator-configured in the relay's config.yaml).                    |
| `tenant`          | lowercased hostname | Tenant id for this host; must be unique on the relay.                             |
| `autoRegister`    | `true`              | Register at startup when no credentials are stored.                               |
| `categories`      | all four            | `sessionCompleted`, `sessionFailed`, `permissionRequested`, `formRequested`.      |
| `contentLevel`    | `minimal`           | `summaries` adds short failure reasons (never transcript text).                   |
| `defaultSessions` | `all`               | Session subscription default for newly paired devices.                            |
| `pushTtlSeconds`  | `3600`              | APNs expiry for alert pushes.                                                     |
| `grantTtlSeconds` | relay App default   | TTL requested on grant renewal.                                                   |

## Commands

- `/push-status` — registration, relay health, binding probe, paired devices,
  outbox depth, delivery stats, and recovery notes.
- `/push-key-rotate` — rotate token + signing key via `/v1/rotate`; devices
  re-pair afterwards. Explains when only the relay operator can fix a state
  (`relay tenant revoke`).
- `/push-test` — send an alert to every paired device and report per-device
  APNs results.

## RPC (`push`)

Narrow surface per `docs/notifications.md` — enrollment, preferences, status,
revocation only; no agent tools, no remote-command channel.

- Methods: `info`, `enroll`, `update`, `status`, `revoke`
- Events: `config` (registration changed → apps re-fetch + re-enroll),
  `device` (enrollment state changed)

Import the contract without the implementation via the package's `./rpc`
export.

## Storage and leases

One server-global KV table namespaced by plugin id, then scoped per
options (`relayUrl|app|tenant`): `registration`, `device/<id>`,
`outbox/<id>`, `sent/<eventId>`, `lease`. Project locations with identical
options share their scope — one registration, device set, outbox and lease —
while locations with different options never mix credentials. The delivery
lease ensures a single instance drains at a time (others pick up after
expiry; the holder re-news it before every outbox item, so a slow drain
cannot outlive it, and `/push-status` reports holder vs free from the
lease's live expiry). Correctness never depends on the lease alone: outbox
writes are idempotent per (transition, device), and the lease plus retry
handling own the delivery guarantee. APNs collapse ids only merge the
presentation of alerts that were actually transmitted — a retry after APNs
accepted a request can send the same alert again, so collapse ids are never
treated as send-side deduplication.

## Loading (verified against OpenCode v2.0.30)

- **In this repo.** OpenCode v2.0.30 auto-discovers plugins from
  `.opencode/plugins/<dir>/index.js`; the committed shim at
  `.opencode/plugins/opencode-push-relay/index.js` re-exports this
  package's entry. Verified with a real `opencode serve`: the plugin
  loads, the `push` RPC and all three commands register, and the startup
  log reports `inactive:`. The shim receives no options, so the plugin is
  inert here (no registration, storage writes, or relay traffic).
- **Project `plugins[]` declarations are not loaded in v2.0.30.** A
  `{"package": "./plugins/opencode-push-relay", "options": {...}}` entry
  in the project `opencode.json(c)` (root or `.opencode/`) is parsed into
  the config layers but never reaches the plugin loader — verified with
  empty and non-empty options. `relayUrl`/`app` therefore cannot be set
  from within this repo on v2.0.30; the root `opencode.jsonc` entry
  documents the intended wiring for versions that honor it.
- **Deploying with options.** The package ships prebuilt JavaScript
  (`dist/`, produced by the `prepare` script): Node refuses to type-strip
  TypeScript beneath `node_modules`, so the npm `exports` must point at
  `.js`. Verified locally by importing both entrypoints from a simulated
  physical `node_modules` install (not yet via a real `npm publish`).
  Declare the published package name in the config your OpenCode build
  actually loads, e.g. the global `~/.config/opencode/opencode.jsonc`:

  ```json
  {
    "plugins": [
      {
        "package": "opencode-push-relay",
        "options": { "relayUrl": "https://relay.example", "app": "opencode" }
      }
    ]
  }
  ```

  This uses the same npm-plugin mechanism as the global plugins that
  demonstrably load on every boot, but has not been exercised end-to-end
  here — it needs the package on npm.

## Development

```sh
npm install
npm run typecheck   # tsc --noEmit (strict, noUncheckedIndexedAccess)
npm test            # node --test tests/ — signing fixture, classifier,
                    # config, grant checks, store, engine, handlers,
                    # commands, and a real-HTTP RelayClient suite
```

The signing tests run against the relay repo's golden
`tests/fixtures/canonical.json`, byte-pinning the canonical message against
the relay implementation.
