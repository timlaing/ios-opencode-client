// SPDX-License-Identifier: MPL-2.0

import assert from "node:assert/strict"
import { test } from "node:test"

import type { PushConfig } from "../src/config.ts"
import { makeRpcHandlers, type HandlerContext, type HandlerDeps } from "../src/handlers.ts"
import { RelayError, type RelayClient } from "../src/relay.ts"
import { sha256hex } from "../src/signing.ts"
import { buildStatus } from "../src/status.ts"
import type { PushStore, Registration } from "../src/store.ts"

import {
  FakeRelayClient,
  makeClaims,
  makeConfig,
  makeDevice,
  makeGrant,
  makeRegistration,
  makeStore,
} from "./helpers.ts"

interface Captured extends HandlerContext {
  readonly errors: Array<{ type: string; message: string; data?: unknown }>
}

function capturingContext(): Captured {
  const errors: Array<{ type: string; message: string; data?: unknown }> = []
  return {
    errors,
    error(type: string, message: string, data?: unknown) {
      const failure = { type, message, data }
      errors.push(failure)
      return failure
    },
  }
}

function setup(options: { config?: PushConfig | undefined; registration?: Registration } = {}) {
  const store = makeStore()
  const relay = new FakeRelayClient()
  // `"config" in options` distinguishes "explicitly unconfigured" from "default".
  const config = "config" in options ? options.config : makeConfig()
  const registration =
    options.registration !== undefined
      ? (async () => {
          await store.saveRegistration(options.registration as Registration)
          return options.registration as Registration
        })()
      : store.getRegistration()
  const deps: HandlerDeps = {
    config,
    store,
    relay: relay as unknown as RelayClient,
    ensureRegistration: () => registration,
    buildStatusReport: () =>
      buildStatus({
        config,
        missing: [],
        problems: [],
        store,
        relay: relay as unknown as RelayClient,
        ensureOutcome: undefined,
      }),
  }
  const handlers = makeRpcHandlers(deps)
  const context = capturingContext()
  const call = async (name: string, input: unknown): Promise<unknown> => {
    const handler = handlers[name]
    assert.ok(handler, `missing handler ${name}`)
    return handler(input, context)
  }
  return { handlers, context, call, store, relay, deps }
}

test("unconfigured plugin: enroll/info report not_configured", async () => {
  const s = setup({ config: undefined })
  const enrollFailure = (await s.call("enroll", {})) as { type: string }
  assert.equal(enrollFailure.type, "not_configured")
  // The unconfigured path must answer every read handler too (finding:
  // missing unconfigured-info test), not only the mutating one.
  const infoFailure = (await s.call("info", {})) as { type: string }
  assert.equal(infoFailure.type, "not_configured")
  assert.equal(s.context.errors.length, 2)
  assert.equal(s.context.errors[0]?.type, "not_configured")
  assert.equal(s.context.errors[1]?.type, "not_configured")
})

test("configured but unregistered: enroll reports registration_missing", async () => {
  const s = setup()
  const failure = (await s.call("enroll", {})) as { type: string }
  assert.equal(failure.type, "registration_missing")
})

test("enroll verifies the grant through the relay and stores the re-issued one", async () => {
  const registration = makeRegistration()
  const s = setup({ registration })
  // A fixed renewed expiry keeps the renewal math deterministic.
  const renewedExp = 1_800_000_000
  s.relay.renewResponse = { grant: "v1.reissued.grant", expiresAt: renewedExp }
  const result = (await s.call("enroll", {
    destinationToken: "cd".repeat(16),
    grant: makeGrant(makeClaims({ tok: `sha256:${sha256hex("cd".repeat(16))}` })),
    deviceID: "dev_phone",
    prefs: { sessions: ["ses_1"], categories: ["sessionCompleted"], contentLevel: "summaries" },
  })) as Record<string, unknown>
  assert.equal(s.context.errors.length, 0)
  assert.equal(result.deviceID, "dev_phone")
  // The grant stored is the relay's re-issue — signed proof the relay
  // accepted ours — not the grant the client handed us.
  assert.equal(s.relay.renewCalls.length, 1)
  assert.equal(s.relay.renewCalls[0]?.ttl, makeConfig().grantTtlSeconds)
  const device = await s.store.getDevice("dev_phone")
  assert.ok(device)
  assert.equal(device.grant, "v1.reissued.grant")
  assert.equal(device.destinationToken, "cd".repeat(16))
  assert.equal(device.needsEnroll, false)
  assert.equal(device.environment, "sandbox")
  assert.equal(device.grantExpiresAt, renewedExp)
  // Renewal is computed at half-life between now and the renewed expiry.
  const nowSeconds = Math.floor(Date.now() / 1000)
  const expectedRenewAt = nowSeconds + Math.floor((renewedExp - nowSeconds) / 2)
  assert.ok(Math.abs(device.grantRenewAt - expectedRenewAt) <= 1)
  assert.deepEqual(device.prefs.sessions, ["ses_1"])
  assert.deepEqual(device.prefs.categories, ["sessionCompleted"])
  assert.equal(device.prefs.contentLevel, "summaries")
  assert.equal(result.grantExpiresAt, renewedExp)
  assert.equal(result.environment, "sandbox")
})

test("enroll refuses a grant the relay cannot verify and stores nothing", async () => {
  const s = setup({ registration: makeRegistration() })
  s.relay.renewError = new RelayError(400, "invalid_grant", "malformed grant")
  const failure = (await s.call("enroll", {
    destinationToken: "cd".repeat(16),
    grant: makeGrant(makeClaims({ tok: `sha256:${sha256hex("cd".repeat(16))}` })),
  })) as { type: string; data?: { problem: string } }
  assert.equal(failure.type, "invalid_grant")
  assert.equal(failure.data?.problem, "invalid_grant")
  assert.equal((await s.store.listDevices()).length, 0)
})

test("re-enrolling one destination token keeps exactly one active device", async () => {
  const s = setup({ registration: makeRegistration() })
  const token = "cd".repeat(16)
  const grant = (): string => makeGrant(makeClaims({ tok: `sha256:${sha256hex(token)}` }))

  // First pairing without a deviceID: one record with a generated id.
  const first = (await s.call("enroll", {
    destinationToken: token,
    grant: grant(),
  })) as Record<string, unknown>
  const firstID = first.deviceID
  assert.ok(typeof firstID === "string")

  // Retry without a deviceID (reinstall/re-pair): reuses the record —
  // a twin for the same token would make every event push twice.
  const second = (await s.call("enroll", {
    destinationToken: token,
    grant: grant(),
  })) as Record<string, unknown>
  assert.equal(second.deviceID, firstID)
  let devices = await s.store.listDevices()
  assert.equal(devices.length, 1)

  // An explicit new deviceID with the same token supersedes the old record.
  const third = (await s.call("enroll", {
    destinationToken: token,
    grant: grant(),
    deviceID: "dev_new",
  })) as Record<string, unknown>
  assert.equal(third.deviceID, "dev_new")
  devices = await s.store.listDevices()
  assert.equal(devices.length, 1)
  assert.equal(devices[0]?.id, "dev_new")

  // A different token is a different device: it coexists with dev_new.
  const otherToken = "ef".repeat(16)
  await s.call("enroll", {
    destinationToken: otherToken,
    grant: makeGrant(makeClaims({ tok: `sha256:${sha256hex(otherToken)}` })),
  })
  assert.equal((await s.store.listDevices()).length, 2)
})

test("enroll without prefs applies plugin defaults", async () => {
  const s = setup({ registration: makeRegistration() })
  await s.call("enroll", {
    destinationToken: "cd".repeat(16),
    grant: makeGrant(makeClaims({ tok: `sha256:${sha256hex("cd".repeat(16))}` })),
  })
  const devices = await s.store.listDevices()
  assert.equal(devices.length, 1)
  const [device] = devices
  assert.ok(device)
  assert.match(device.id, /^dev_[0-9a-f]{12}$/)
  assert.equal(device.prefs.sessions, "all")
  assert.deepEqual(device.prefs.categories, [
    "sessionCompleted",
    "sessionFailed",
    "permissionRequested",
    "formRequested",
  ])
})

test("enroll rejects mis-bound grants with precise problems", async () => {
  const s = setup({ registration: makeRegistration() })
  const base = { destinationToken: "cd".repeat(16) }
  const problemOf = async (grant: string): Promise<string> => {
    const failure = (await s.call("enroll", { ...base, grant })) as { type: string; data?: unknown }
    assert.equal(failure.type, "invalid_grant")
    return (failure.data as { problem: string }).problem
  }
  assert.equal(await problemOf(makeGrant(makeClaims({ ten: "host-b" }))), "tenant_mismatch")
  assert.equal(await problemOf(makeGrant(makeClaims({ tpk: "OTHER" }))), "pubkey_mismatch")
  assert.equal(
    await problemOf(makeGrant(makeClaims({ tok: "sha256:deadbeef" }))),
    "token_mismatch",
  )
  assert.equal(
    await problemOf(makeGrant(makeClaims({ exp: Math.floor(Date.now() / 1000) - 5 }))),
    "grant_expired",
  )
  assert.equal(await problemOf("v1.garbage"), "malformed_grant")
})

test("enroll validates destinationToken and deviceID shapes", async () => {
  const s = setup({ registration: makeRegistration() })
  const bad = (await s.call("enroll", {
    destinationToken: "not-hex",
    grant: makeGrant(makeClaims()),
  })) as { type: string }
  assert.equal(bad.type, "bad_destination_token")
  const badID = (await s.call("enroll", {
    destinationToken: "cd".repeat(16),
    grant: makeGrant(makeClaims({ tok: `sha256:${sha256hex("cd".repeat(16))}` })),
    deviceID: "spaces are not allowed",
  })) as { type: string }
  assert.equal(badID.type, "bad_device_id")
})

test("re-enroll preserves createdAt and lastPushAt", async () => {
  const s = setup({ registration: makeRegistration() })
  await s.store.saveDevice({
    ...makeDevice("dev_phone", { lastPushAt: 1_759_000_000_000, lastResult: "accepted" }),
  })
  await s.call("enroll", {
    destinationToken: "cd".repeat(16),
    grant: makeGrant(makeClaims({ tok: `sha256:${sha256hex("cd".repeat(16))}` })),
    deviceID: "dev_phone",
  })
  const device = await s.store.getDevice("dev_phone")
  assert.equal(device?.createdAt, makeDevice("x").createdAt)
  assert.equal(device?.lastPushAt, 1_759_000_000_000)
  assert.equal(device?.destinationToken, "cd".repeat(16))
})

test("update merges prefs over the device's current ones", async () => {
  const s = setup({ registration: makeRegistration() })
  await s.store.saveDevice(makeDevice("dev_a"))
  const result = (await s.call("update", {
    deviceID: "dev_a",
    prefs: { sessions: ["ses_2", "ses_3"], contentLevel: "summaries" },
  })) as Record<string, unknown>
  assert.equal(s.context.errors.length, 0)
  const device = await s.store.getDevice("dev_a")
  assert.deepEqual(device?.prefs.sessions, ["ses_2", "ses_3"])
  // Categories untouched by the patch.
  assert.deepEqual(device?.prefs.categories, [
    "sessionCompleted",
    "sessionFailed",
    "permissionRequested",
    "formRequested",
  ])
  assert.equal(device?.prefs.contentLevel, "summaries")
  assert.deepEqual(result.sessions, ["ses_2", "ses_3"])

  const unknown = (await s.call("update", { deviceID: "nope", prefs: {} })) as { type: string }
  assert.equal(unknown.type, "unknown_device")
})

test("revoke removes locally and revokes on the relay", async () => {
  const s = setup({ registration: makeRegistration() })
  await s.store.saveDevice(makeDevice("dev_a"))
  const result = (await s.call("revoke", { deviceID: "dev_a" })) as Record<string, unknown>
  assert.equal(result.relayRevoked, true)
  assert.equal(await s.store.getDevice("dev_a"), undefined)
  assert.deepEqual(s.relay.revoked, [makeDevice("dev_a").grant])

  const unknown = (await s.call("revoke", { deviceID: "dev_a" })) as { type: string }
  assert.equal(unknown.type, "unknown_device")
})

test("revoke still removes locally when the relay call fails", async () => {
  const s = setup({ registration: makeRegistration() })
  await s.store.saveDevice(makeDevice("dev_a"))
  s.relay.revoke = async () => {
    throw new Error("offline")
  }
  const result = (await s.call("revoke", { deviceID: "dev_a" })) as Record<string, unknown>
  assert.equal(result.relayRevoked, false)
  assert.equal(await s.store.getDevice("dev_a"), undefined)
})

test("info reports tenant details and binding probe for a paired host", async () => {
  const s = setup({ registration: makeRegistration() })
  await s.store.saveDevice(makeDevice("dev_a", { needsEnroll: true }))
  const info = (await s.call("info", {})) as Record<string, unknown>
  assert.equal(info.configured, true)
  assert.equal(info.tenant, "host-a")
  assert.equal(info.registered, true)
  assert.equal(info.tenantPubkey, "FIXTURE_PUBKEY_BASE64URL")
  assert.equal(info.binding, "bound")
  assert.deepEqual(info.needsEnroll, ["dev_a"])
  assert.equal(info.devices, 1)
})

test("status returns the structured report (configured and unconfigured)", async () => {
  const s = setup({ registration: makeRegistration() })
  const status = (await s.call("status", {})) as Record<string, unknown>
  assert.equal(status.configured, true)
  assert.equal(status.registered, true)
  assert.equal(status.probe, "bound")
  assert.ok(Array.isArray(status.devices))
  // The status payload carries the short fingerprint — never the full key
  // that `info.tenantPubkey` returns (one meaning per field name).
  assert.equal(status.tenantPubkeyFingerprint, "FIXTURE_PUBK")
  assert.equal(status.tenantPubkey, undefined)

  const unconfigured = setup({ config: undefined })
  const off = (await unconfigured.call("status", {})) as Record<string, unknown>
  assert.equal(off.configured, false)
  assert.ok((off.notes as string[]).length >= 1)
})
