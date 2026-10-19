// SPDX-License-Identifier: MPL-2.0

import assert from "node:assert/strict"
import { test } from "node:test"

import type { PushConfig } from "../src/config.ts"
import { makeRpcHandlers, type HandlerContext, type HandlerDeps } from "../src/handlers.ts"
import type { RelayClient } from "../src/relay.ts"
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
  const failure = (await s.call("enroll", {})) as { type: string }
  assert.equal(failure.type, "not_configured")
  const [first] = s.context.errors
  assert.ok(first)
  assert.equal(first.type, "not_configured")
})

test("configured but unregistered: enroll reports registration_missing", async () => {
  const s = setup()
  const failure = (await s.call("enroll", {})) as { type: string }
  assert.equal(failure.type, "registration_missing")
})

test("enroll stores a validated device and computes half-life renewal", async () => {
  const registration = makeRegistration()
  const s = setup({ registration })
  const iat = Math.floor(Date.now() / 1000) - 60
  const exp = iat + 86_460
  const result = (await s.call("enroll", {
    destinationToken: "cd".repeat(16),
    grant: makeGrant(
      makeClaims({ iat, exp, tok: `sha256:${sha256hex("cd".repeat(16))}` }),
    ),
    deviceID: "dev_phone",
    prefs: { sessions: ["ses_1"], categories: ["sessionCompleted"], contentLevel: "summaries" },
  })) as Record<string, unknown>
  assert.equal(s.context.errors.length, 0)
  assert.equal(result.deviceID, "dev_phone")
  const device = await s.store.getDevice("dev_phone")
  assert.ok(device)
  assert.equal(device.destinationToken, "cd".repeat(16))
  assert.equal(device.needsEnroll, false)
  assert.equal(device.environment, "sandbox")
  assert.equal(device.grantExpiresAt, exp)
  // Renewal is computed at half-life between iat and exp.
  assert.equal(device.grantRenewAt, iat + Math.floor((exp - iat) / 2))
  assert.deepEqual(device.prefs.sessions, ["ses_1"])
  assert.deepEqual(device.prefs.categories, ["sessionCompleted"])
  assert.equal(device.prefs.contentLevel, "summaries")
  assert.equal(result.grantExpiresAt, exp)
  assert.equal(result.environment, "sandbox")
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

  const unconfigured = setup({ config: undefined })
  const off = (await unconfigured.call("status", {})) as Record<string, unknown>
  assert.equal(off.configured, false)
  assert.ok((off.notes as string[]).length >= 1)
})
