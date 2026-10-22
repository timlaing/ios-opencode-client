// SPDX-License-Identifier: MPL-2.0

import assert from "node:assert/strict"
import { test } from "node:test"

import { pushCommandDefinitions, type CommandDeps } from "../src/commands.ts"
import { DeliveryEngine } from "../src/engine.ts"
import { RelayError, type RelayClient } from "../src/relay.ts"
import { sha256hex } from "../src/signing.ts"
import { buildStatus, formatStatus } from "../src/status.ts"

import {
  FakeRelayClient,
  makeConfig,
  makeDevice,
  makeRegistration,
  makeStore,
} from "./helpers.ts"

function setup(options: { configured?: boolean } = {}) {
  const store = makeStore()
  const relay = new FakeRelayClient()
  const config = options.configured === false ? undefined : makeConfig()
  const engine =
    config === undefined
      ? undefined
      : new DeliveryEngine(config, store, relay, {
          onDeviceNeedsEnroll: () => {},
          onRegistrationLost: () => {},
          kick: () => {},
          log: () => {},
        })
  const submissions: Array<{ sessionID: string; delivery: unknown; text: string }> = []
  const emitted: string[] = []
  const logs: string[] = []
  let adopted = 0
  const deps: CommandDeps = {
    config: () => config,
    store,
    engine: () => engine,
    relay: () => relay as unknown as RelayClient,
    ensureRegistration: () => store.getRegistration(),
    adoptRegistration: () => {
      adopted += 1
    },
    buildStatusReport: () =>
      buildStatus({
        config,
        missing: config === undefined ? ["relayUrl", "app"] : [],
        problems: [],
        store,
        relay: relay as unknown as RelayClient,
        ensureOutcome: undefined,
      }),
    emitConfig: (reason) => emitted.push(reason),
    io: {
      submit: async (sessionID, delivery, text) => {
        submissions.push({ sessionID, delivery, text })
      },
    },
    log: (message) => logs.push(message),
  }
  const definitions = pushCommandDefinitions(deps)
  const run = async (name: string): Promise<string> => {
    const definition = definitions.find((entry) => entry.name === name)
    assert.ok(definition, `missing command ${name}`)
    await definition.execute({ sessionID: "ses_cmd", prompt: {}, delivery: "log" })
    const submission = submissions.at(-1)
    assert.ok(submission, `command ${name} submitted nothing`)
    assert.equal(submission.sessionID, "ses_cmd")
    return submission.text
  }
  return { run, store, relay, emitted, logs, adopted: () => adopted, definitions }
}

test("commands are registered with descriptions", () => {
  const s = setup()
  assert.deepEqual(
    s.definitions.map((definition) => definition.name),
    ["push-status", "push-key-rotate", "push-test"],
  )
  for (const definition of s.definitions) assert.ok(definition.description.length > 0)
})

test("push-status explains the inactive state when unconfigured", async () => {
  const s = setup({ configured: false })
  const text = await s.run("push-status")
  assert.match(text, /inactive/)
  assert.match(text, /missing relayUrl/)
  assert.match(text, /opencode\.json/)
})

test("push-status reports registration, devices and stats when active", async () => {
  const s = setup()
  await s.store.saveRegistration(makeRegistration())
  await s.store.saveDevice(makeDevice("dev_a"))
  const text = await s.run("push-status")
  assert.match(text, /relay\.test/)
  assert.match(text, /tenant host-a/)
  // Token appears only as a fingerprint.
  assert.ok(text.includes(sha256hex("tnt_fixture-token-0001").slice(0, 12)))
  assert.ok(!text.includes("tnt_fixture-token-0001"))
  assert.match(text, /dev_a/)
  assert.match(text, /binding\s+bound/)
  assert.match(text, /relay health\s+ok/)
  assert.match(text, /stats\s+enqueued 0/)
})

test("push-key-rotate on a bound tenant replaces token+key, flags devices, emits config", async () => {
  const s = setup()
  await s.store.saveRegistration(makeRegistration({ publicB64: "OLD_PUBLIC_KEY" }))
  await s.store.saveDevice(makeDevice("dev_a"))
  const text = await s.run("push-key-rotate")
  assert.match(text, /Push credentials rotated\./)
  assert.match(text, /re-pair devices/)
  assert.match(text, /1 device\(s\)? flagged|flagged for re-enrollment/)
  const registration = await s.store.getRegistration()
  assert.equal(registration?.token, "tnt_rotated-token")
  assert.notEqual(registration?.publicB64, "OLD_PUBLIC_KEY")
  assert.equal(registration?.generation, 2)
  assert.ok(registration?.rotatedAt !== undefined)
  assert.equal((await s.store.getDevice("dev_a"))?.needsEnroll, true)
  assert.deepEqual(s.emitted, ["rotated"])
  assert.equal(s.adopted(), 1)
  // The rotate call carried the NEW pubkey, signed with the old credentials.
  assert.equal(s.relay.rotatedPubkeys.length, 1)
  assert.notEqual(s.relay.rotatedPubkeys[0], "OLD_PUBLIC_KEY")
})

test("push-key-rotate before any enrollment swaps the local keypair only", async () => {
  const s = setup()
  await s.store.saveRegistration(makeRegistration({ publicB64: "OLD_PUBLIC_KEY" }))
  s.relay.probe = { state: "unbound" }
  const text = await s.run("push-key-rotate")
  assert.match(text, /Rotated the local signing keypair\./)
  assert.match(text, /nothing to re-pair/)
  const registration = await s.store.getRegistration()
  assert.notEqual(registration?.publicB64, "OLD_PUBLIC_KEY")
  assert.equal(registration?.token, "tnt_fixture-token-0001") // token untouched
  assert.equal(s.relay.rotatedPubkeys.length, 0) // no relay call needed
  assert.deepEqual(s.emitted, ["rotated"])
})

test("push-key-rotate refuses when the relay rejects our key, and says who must act", async () => {
  const s = setup()
  await s.store.saveRegistration(makeRegistration())
  s.relay.probe = { state: "rejected", code: "invalid_signature" }
  const text = await s.run("push-key-rotate")
  assert.match(text, /Cannot rotate from here/)
  assert.match(text, /relay tenant revoke host-a/)
  assert.equal(s.relay.rotatedPubkeys.length, 0)
})

test("push-key-rotate surfaces relay outages and missing /v1/rotate clearly", async () => {
  const offline = setup()
  await offline.store.saveRegistration(makeRegistration())
  offline.relay.rotateQueue.push(new RelayError(0, "network_error", "down"))
  assert.match(await offline.run("push-key-rotate"), /Rotation failed: .*network_error/)

  const old = setup()
  await old.store.saveRegistration(makeRegistration())
  old.relay.rotateQueue.push(new RelayError(404, "http_404"))
  assert.match(await old.run("push-key-rotate"), /does not expose POST \/v1\/rotate/)
})

test("push-key-rotate with nothing registered points at /push-status", async () => {
  const s = setup()
  const text = await s.run("push-key-rotate")
  assert.match(text, /No registration to rotate/)
})

test("push-test delivers to paired devices and reports each", async () => {
  const s = setup()
  await s.store.saveDevice(makeDevice("dev_phone"))
  const text = await s.run("push-test")
  assert.match(text, /Push test → https:\/\/relay\.test/)
  assert.match(text, /dev_phone\s+accepted \(\d+ ms\)/)
  assert.match(text, /apns-id apns-1/)
})

test("push-test without devices says to pair first", async () => {
  const s = setup()
  assert.match(await s.run("push-test"), /no paired devices/)
})

test("push-test failure rows carry the machine code only; detail goes to the log", async () => {
  const s = setup()
  await s.store.saveDevice(makeDevice("dev_phone"))
  s.relay.pushQueue.push(
    new RelayError(401, "grant_expired", "grant is expired <script>alert(1)</script>"),
  )
  const text = await s.run("push-test")
  assert.match(text, /dev_phone\s+FAILED grant_expired/)
  // Relay-controlled free text must never reach the prompt-bound report.
  assert.ok(!text.includes("<script>"))
  assert.ok(!text.includes("grant is expired"))
  // …but it is preserved in the server log for debugging.
  assert.ok(s.logs.some((message) => message.includes("grant is expired")))
})

test("lease line distinguishes this holder, another live holder, and free", async () => {
  const store = makeStore()
  const relay = new FakeRelayClient()
  const report = (instanceHoldsLease?: boolean) =>
    buildStatus({
      config: makeConfig(),
      missing: [],
      problems: [],
      store,
      relay: relay as unknown as RelayClient,
      ensureOutcome: undefined,
      instanceHoldsLease,
    })

  // No lease record: free — not "held elsewhere", even if the caller
  // believes it holds the lease.
  assert.match(formatStatus(await report(true)), /lease\s+free/)
  // Live lease owned by this instance.
  await store.lease("engine-1", Date.now(), 30_000)
  assert.match(formatStatus(await report(true)), /lease\s+held by this instance/)
  // Same live lease, but this instance is not the owner.
  assert.match(
    formatStatus(await report(false)),
    /held elsewhere \(another project location is draining\)/,
  )
  // Expired lease: free again, regardless of owner match.
  await store.releaseLease("engine-1")
  await store.lease("engine-3", Date.now() - 60_000, 5_000)
  assert.match(formatStatus(await report(false)), /lease\s+free/)
  assert.match(formatStatus(await report(true)), /lease\s+free/)
})
