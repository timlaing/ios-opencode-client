// SPDX-License-Identifier: MPL-2.0

import assert from "node:assert/strict"
import { test } from "node:test"

import { ALL_CATEGORIES } from "../src/classifier.ts"
import { backoffMs, DeliveryEngine, eventIdFor } from "../src/engine.ts"
import { RelayError } from "../src/relay.ts"

import { FakeRelay, makeConfig, makeDevice, makeDraft, makeStore } from "./helpers.ts"

const BASE_NOW = 1_760_000_000_000

function setup() {
  const store = makeStore()
  const relay = new FakeRelay()
  const enrolled: string[] = []
  const lost: string[] = []
  const logs: string[] = []
  let kicks = 0
  let now = BASE_NOW
  const engine = new DeliveryEngine(
    makeConfig(),
    store,
    relay,
    {
      onDeviceNeedsEnroll: (deviceID) => enrolled.push(deviceID),
      onRegistrationLost: (code) => lost.push(code),
      kick: () => {
        kicks += 1
      },
      log: (message) => logs.push(message),
    },
    () => now,
  )
  return {
    store,
    relay,
    engine,
    enrolled,
    lost,
    logs,
    kicks: () => kicks,
    now: () => now,
    advance: (ms: number) => {
      now += ms
    },
  }
}

test("enqueue fans out to matching devices only, and dedupes the transition", async () => {
  const s = setup()
  await s.store.saveDevice(makeDevice("dev_a"))
  await s.store.saveDevice(
    makeDevice("dev_b", {
      prefs: { sessions: ["ses_other"], categories: [...ALL_CATEGORIES], contentLevel: "minimal" },
    }),
  )
  await s.store.saveDevice(makeDevice("dev_c", { needsEnroll: true }))
  await s.store.saveDevice(
    makeDevice("dev_d", {
      prefs: { sessions: "all", categories: ["permissionRequested"], contentLevel: "minimal" },
    }),
  )

  const draft = makeDraft()
  assert.equal(await s.engine.enqueue(draft), 1)
  assert.equal(await s.engine.enqueue(draft), 0) // same canonical transition

  const outbox = await s.store.listOutbox()
  assert.equal(outbox.length, 1)
  const [queued] = outbox
  assert.ok(queued)
  assert.equal(queued.deviceID, "dev_a")
  assert.equal(s.kicks(), 1)

  // Sealed blob: standard base64 (relay validates with b64decode(validate=True)),
  // routing-only content.
  const sealed = queued.content.sealed
  assert.ok(sealed)
  assert.ok(!sealed.includes("-") && !sealed.includes("_"))
  const decoded = JSON.parse(Buffer.from(sealed, "base64").toString("utf8")) as Record<
    string,
    unknown
  >
  assert.equal(decoded.ledgerKey, draft.ledgerKey)
  assert.equal(decoded.category, "sessionCompleted")
  assert.equal(decoded.sessionID, "ses_1")
  assert.equal(decoded.host, "host-a")
  // Alert carries category copy only.
  assert.equal(queued.content.alert?.title, draft.title)
  assert.equal(queued.content.alert?.category, "sessionCompleted")
})

test("tick delivers, dedupes via sent/, and records stats", async () => {
  const s = setup()
  await s.store.saveDevice(makeDevice("dev_a"))
  const draft = makeDraft()
  await s.engine.enqueue(draft)

  await s.engine.tick()
  assert.equal(s.relay.pushes.length, 1)
  const [request] = s.relay.pushes
  assert.ok(request)
  assert.equal(request.kind, "alert")
  assert.equal(request.eventId, eventIdFor(draft.ledgerKey))
  assert.equal(request.destinationToken, "ab".repeat(16))
  assert.ok(request.expiresAt)

  assert.equal((await s.store.listOutbox()).length, 0)
  assert.ok(await s.store.isSent(eventIdFor(draft.ledgerKey)))
  assert.equal((await s.store.getStats()).accepted, 1)
  const device = await s.store.getDevice("dev_a")
  assert.equal(device?.lastResult, "accepted")
  assert.ok(device?.lastPushAt)

  // The transition stays deduplicated after delivery.
  assert.equal(await s.engine.enqueue(draft), 0)
  await s.engine.tick()
  assert.equal(s.relay.pushes.length, 1)
})

test("tick defers to another instance's unexpired lease", async () => {
  const s = setup()
  await s.store.saveDevice(makeDevice("dev_a"))
  assert.equal(await s.store.lease("other-instance", s.now(), 30_000), true)
  await s.engine.enqueue(makeDraft())
  await s.engine.tick()
  assert.equal(s.relay.pushes.length, 0)
  // After the foreign lease expires this instance drains.
  s.advance(60_000)
  await s.engine.tick()
  assert.equal(s.relay.pushes.length, 1)
})

test("overlapping ticks never double-send in-flight items", async () => {
  const s = setup()
  await s.store.saveDevice(makeDevice("dev_a"))
  await s.engine.enqueue(makeDraft())
  // Hold the first push in flight while more ticks pile up (the realistic
  // case: an enqueue's kick() lands mid-drain, and the lease is re-entrant
  // for this instance — without serialisation the second tick re-selects
  // the in-flight outbox item and sends it again).
  let release!: () => void
  const gate = new Promise<void>((resolve) => {
    release = resolve
  })
  const send = s.relay.push.bind(s.relay)
  s.relay.push = async (request) => {
    await gate
    return send(request)
  }
  const first = s.engine.tick()
  const overlapping = s.engine.tick()
  const alsoOverlapping = s.engine.tick()
  release()
  await Promise.all([first, overlapping, alsoOverlapping])
  assert.equal(s.relay.pushes.length, 1)
  assert.equal((await s.store.listOutbox()).length, 0)
})

test("drain re-news its lease per item and stops if another owner takes it", async () => {
  const s = setup()
  await s.store.saveDevice(makeDevice("dev_a"))
  await s.engine.enqueue(makeDraft())
  await s.engine.enqueue(
    makeDraft({
      transitionID: "evt_2",
      ledgerKey: "host:host-a|session:ses_1|owner:-|transition:evt_2",
    }),
  )
  // Two queued items. The first push hangs long enough for LEASE_MS to
  // elapse, during which a different instance takes the lease — the drain
  // must notice on the next item instead of double-sending from an
  // expired lease.
  const send = s.relay.push.bind(s.relay)
  let stolen = false
  s.relay.push = async (request) => {
    if (!stolen) {
      stolen = true
      s.advance(31_000) // > LEASE_MS (30s)
      assert.equal(await s.store.lease("thief-instance", s.now(), 30_000), true)
    }
    return send(request)
  }
  await s.engine.tick()
  // Only the in-flight item was sent; the rest stays queued for the new
  // lease holder rather than being pushed from a stale lease.
  assert.equal(s.relay.pushes.length, 1)
  assert.equal((await s.store.listOutbox()).length, 1)
})

test("retryable results back off, then succeed on a later tick", async () => {
  const s = setup()
  await s.store.saveDevice(makeDevice("dev_a"))
  await s.engine.enqueue(makeDraft())

  s.relay.pushQueue.push({ result: "retryable", detail: "apns 500" })
  await s.engine.tick()
  let outbox = await s.store.listOutbox()
  assert.equal(outbox.length, 1)
  const [delayed] = outbox
  assert.ok(delayed)
  assert.equal(delayed.attempts, 1)
  assert.ok(delayed.nextAttemptAt > s.now())
  // Only the machine code is persisted; the relay detail goes to the log.
  assert.equal(delayed.lastError, "retryable")

  // Not due yet: no second transmission.
  await s.engine.tick()
  assert.equal(s.relay.pushes.length, 1)

  s.advance(backoffMs(1) + 1)
  await s.engine.tick()
  assert.equal(s.relay.pushes.length, 2)
  assert.equal((await s.store.listOutbox()).length, 0)
  const stats = await s.store.getStats()
  assert.equal(stats.retryable, 1)
  assert.equal(stats.accepted, 1)
})

test("network errors are retryable and stay queued", async () => {
  const s = setup()
  await s.store.saveDevice(makeDevice("dev_a"))
  await s.engine.enqueue(makeDraft())
  s.relay.pushQueue.push(new RelayError(0, "network_error", "ECONNREFUSED"))
  await s.engine.tick()
  assert.equal((await s.store.listOutbox()).length, 1)
  assert.equal((await s.store.getStats()).retryable, 1)
})

test("per-device contentLevel builds each device's own body", async () => {
  const s = setup()
  await s.store.saveDevice(
    makeDevice("dev_min", {
      destinationToken: "11".repeat(16),
      prefs: { sessions: "all", categories: ["sessionFailed"], contentLevel: "minimal" },
    }),
  )
  await s.store.saveDevice(
    makeDevice("dev_sum", {
      destinationToken: "22".repeat(16),
      prefs: { sessions: "all", categories: ["sessionFailed"], contentLevel: "summaries" },
    }),
  )
  await s.engine.enqueue(
    makeDraft({
      category: "sessionFailed",
      title: "Session failed",
      body: "The session stopped with an error.",
      failureSummary: "model timeout",
    }),
  )
  await s.engine.tick()
  assert.equal(s.relay.pushes.length, 2)
  const bodyByToken = new Map(
    s.relay.pushes.map((request) => [request.destinationToken, request.content.alert?.body]),
  )
  assert.equal(bodyByToken.get("11".repeat(16)), "The session stopped with an error.")
  assert.equal(bodyByToken.get("22".repeat(16)), "model timeout")
})

test("extended grant problems re-pair the device", async () => {
  for (const code of ["app_mismatch", "destination_mismatch", "kind_not_allowed"]) {
    const s = setup()
    await s.store.saveDevice(makeDevice("dev_a"))
    await s.engine.enqueue(makeDraft())
    s.relay.pushQueue.push(new RelayError(403, code))
    await s.engine.tick()
    assert.equal((await s.store.getDevice("dev_a"))?.needsEnroll, true, code)
    assert.deepEqual(s.enrolled, ["dev_a"], code)
    assert.equal((await s.store.getStats()).dropped, 1, code)
  }
})

test("invalidDestination flags the device for re-enrollment and notifies", async () => {
  const s = setup()
  await s.store.saveDevice(makeDevice("dev_a"))
  await s.engine.enqueue(makeDraft())
  s.relay.pushQueue.push({ result: "invalidDestination", detail: "bad token" })
  await s.engine.tick()
  const device = await s.store.getDevice("dev_a")
  assert.equal(device?.needsEnroll, true)
  assert.equal(device?.lastResult, "invalidDestination")
  assert.deepEqual(s.enrolled, ["dev_a"])
  assert.equal((await s.store.listOutbox()).length, 0)
  assert.equal((await s.store.getStats()).invalidDestination, 1)
})

test("grant failures re-pair the device; binding failures flag the registration", async () => {
  const s = setup()
  await s.store.saveDevice(makeDevice("dev_a"))
  await s.store.saveDevice(makeDevice("dev_b"))
  await s.engine.enqueue(makeDraft())
  s.relay.pushQueue.push(
    new RelayError(401, "grant_expired"),
    new RelayError(401, "invalid_signature"),
  )
  await s.engine.tick()
  assert.equal((await s.store.getDevice("dev_a"))?.needsEnroll, true)
  assert.deepEqual(s.enrolled, ["dev_a"])
  assert.deepEqual(s.lost, ["invalid_signature"])
  assert.equal((await s.store.getStats()).dropped, 2)
  assert.equal((await s.store.listOutbox()).length, 0)
})

test("rejected results are terminal and stay deduplicated", async () => {
  const s = setup()
  await s.store.saveDevice(makeDevice("dev_a"))
  const draft = makeDraft()
  await s.engine.enqueue(draft)
  s.relay.pushQueue.push({ result: "rejected", detail: "payload too large" })
  await s.engine.tick()
  assert.equal((await s.store.listOutbox()).length, 0)
  assert.ok(await s.store.isSent(eventIdFor(draft.ledgerKey)))
  assert.equal((await s.store.getStats()).rejected, 1)
  assert.equal(await s.engine.enqueue(draft), 0)
})

test("stable 4xx rejections are terminal; unknown-device items drop", async () => {
  const s = setup()
  await s.store.saveDevice(makeDevice("dev_a"))
  await s.engine.enqueue(makeDraft())
  s.relay.pushQueue.push(new RelayError(422, "invalid_request", "sealed too large"))
  await s.engine.tick()
  assert.equal((await s.store.listOutbox()).length, 0)
  assert.equal((await s.store.getStats()).rejected, 1)

  // Device disappeared between enqueue and drain.
  await s.engine.enqueue(
    makeDraft({
      transitionID: "evt_2",
      ledgerKey: "host:host-a|session:ses_1|owner:-|transition:evt_2",
    }),
  )
  await s.store.removeDevice("dev_a")
  await s.engine.tick()
  assert.equal((await s.store.getStats()).dropped, 1)
})

test("due grants renew at half-life and update the device", async () => {
  const s = setup()
  const nowSeconds = Math.floor(s.now() / 1000)
  await s.store.saveDevice(
    makeDevice("dev_a", { grantRenewAt: nowSeconds - 1, grantExpiresAt: nowSeconds + 3600 }),
  )
  s.relay.renewResponse = { grant: "v1.renewed-grant", expiresAt: nowSeconds + 7200 }
  await s.engine.tick()
  assert.equal(s.relay.renewCalls.length, 1)
  const [call] = s.relay.renewCalls
  assert.ok(call)
  // config.grantTtlSeconds is undefined → omitted, relay App default applies.
  assert.equal(call.ttl, undefined)
  const device = await s.store.getDevice("dev_a")
  assert.equal(device?.grant, "v1.renewed-grant")
  assert.equal(device?.grantExpiresAt, nowSeconds + 7200)
  assert.ok(device && device.grantRenewAt > nowSeconds)
  assert.equal(device?.renewRetryAt, undefined)
  assert.equal((await s.store.getStats()).renewals, 1)
})

test("renewal network failures back off; dead grants re-pair", async () => {
  const s = setup()
  const nowSeconds = Math.floor(s.now() / 1000)
  await s.store.saveDevice(makeDevice("dev_a", { grantRenewAt: nowSeconds - 1 }))
  s.relay.renewError = new RelayError(0, "network_error", "offline")
  await s.engine.tick()
  const afterFailure = await s.store.getDevice("dev_a")
  assert.ok(afterFailure?.renewRetryAt !== undefined && afterFailure.renewRetryAt > s.now())
  assert.ok(s.logs.some((line) => line.includes("grant renewal")))

  // Within the retry window: no hammering every tick.
  await s.engine.tick()
  assert.equal(s.relay.renewCalls.length, 1)

  // A grant-level failure re-pairs instead of retrying.
  await s.store.saveDevice({ ...afterFailure!, renewRetryAt: undefined })
  s.relay.renewError = new RelayError(401, "grant_expired")
  await s.engine.tick()
  assert.equal((await s.store.getDevice("dev_a"))?.needsEnroll, true)
  assert.deepEqual(s.enrolled, ["dev_a"])
})

test("sendTest bypasses prefs and reports per device", async () => {
  const s = setup()
  await s.store.saveDevice(
    makeDevice("dev_a", { prefs: { sessions: [], categories: [], contentLevel: "minimal" } }),
  )
  await s.store.saveDevice(makeDevice("dev_b", { needsEnroll: true }))
  const results = await s.engine.sendTest()
  assert.equal(results.length, 2)
  const [first, second] = results
  assert.ok(first && second)
  assert.equal(first.deviceID, "dev_a")
  assert.equal(first.ok, true)
  assert.equal(first.result, "accepted")
  assert.ok(first.apnsId)
  assert.equal(second.deviceID, "dev_b")
  assert.equal(second.ok, false)
  assert.equal(second.result, "needsEnroll")
  assert.equal(s.relay.pushes.length, 1)
  const [testPush] = s.relay.pushes
  assert.ok(testPush)
  assert.equal(testPush.content.alert?.title, "Push test")
  // Explicit subset targets one device only.
  const single = await s.engine.sendTest(["dev_a"])
  assert.equal(single.length, 1)
})

test("outbox survives a restart: items persist and drain on the next tick", async () => {
  const s = setup()
  await s.store.saveDevice(makeDevice("dev_a"))
  await s.engine.enqueue(makeDraft())
  // "Restart": a fresh engine over the same storage drains the persisted item.
  const relay2 = new FakeRelay()
  const engine2 = new DeliveryEngine(makeConfig(), s.store, relay2, {
    onDeviceNeedsEnroll: () => {},
    onRegistrationLost: () => {},
    kick: () => {},
    log: () => {},
  })
  await engine2.tick()
  assert.equal(relay2.pushes.length, 1)
  assert.equal((await s.store.listOutbox()).length, 0)
})
