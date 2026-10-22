// SPDX-License-Identifier: MPL-2.0

import assert from "node:assert/strict"
import { test } from "node:test"

import { withLock, PushStore, type OutboxItem, type Registration } from "../src/store.ts"

import { makeDevice, makeStore, MemoryKv } from "./helpers.ts"

function makeItem(overrides: Partial<OutboxItem> = {}): OutboxItem {
  return {
    id: "evt_1::dev_a",
    eventId: "evt_1",
    deviceID: "dev_a",
    ledgerKey: "host:host-a|session:ses_1|owner:-|transition:evt_1",
    content: { alert: { title: "t", body: "b" } },
    createdAt: 1_760_000_000_000,
    nextAttemptAt: 1_760_000_000_000,
    attempts: 0,
    lastError: undefined,
    ...overrides,
  }
}

test("enqueueItem dedupes by id; updates are keyed and merged", async () => {
  const store = makeStore()
  assert.equal(await store.enqueueItem(makeItem()), true)
  assert.equal(await store.enqueueItem(makeItem()), false)
  assert.equal((await store.listOutbox()).length, 1)

  await store.updateOutbox("evt_1::dev_a", { attempts: 2, lastError: "retryable" })
  const [item] = await store.listOutbox()
  assert.ok(item)
  assert.equal(item.attempts, 2)
  assert.equal(item.lastError, "retryable")
  assert.equal(item.eventId, "evt_1")
  // Updates to unknown ids are no-ops.
  await store.updateOutbox("nope::x", { attempts: 9 })
  assert.equal((await store.listOutbox()).length, 1)
})

test("transition dedupe markers and pruning", async () => {
  const store = makeStore()
  assert.equal(await store.isSent("evt_1"), false)
  await store.markSent("evt_1", 1_760_000_000_000)
  assert.equal(await store.isSent("evt_1"), true)

  await store.markSent("evt_2", 1_700_000_000_000) // older than cutoff
  const removed = await store.pruneSent(1_750_000_000_000)
  assert.equal(removed, 1)
  assert.equal(await store.isSent("evt_1"), true)
  assert.equal(await store.isSent("evt_2"), false)
})

test("pruneOutbox removes only items older than the cutoff", async () => {
  const store = makeStore()
  await store.enqueueItem(makeItem({ id: "old::dev_a", eventId: "old", createdAt: 100 }))
  await store.enqueueItem(makeItem({ id: "new::dev_a", eventId: "new", createdAt: 1_000 }))
  const removed = await store.pruneOutbox(500)
  assert.equal(removed, 1)
  const remaining = await store.listOutbox()
  assert.equal(remaining.length, 1)
  const [survivor] = remaining
  assert.ok(survivor)
  assert.equal(survivor.eventId, "new")
})

test("lease: contended across owners, re-entrant for the holder, released", async () => {
  const store = makeStore()
  const now = 1_760_000_000_000
  assert.equal(await store.lease("a", now, 30_000), true)
  assert.equal(await store.lease("b", now + 1_000, 30_000), false)
  // Same owner re-leases freely.
  assert.equal(await store.lease("a", now + 2_000, 30_000), true)
  // After expiry another owner wins.
  assert.equal(await store.lease("b", now + 60_000, 30_000), true)
  // Release only clears the caller's lease.
  await store.releaseLease("a")
  const lease = await store.getLease()
  assert.equal(lease?.owner, "b")
  await store.releaseLease("b")
  assert.equal(await store.getLease(), undefined)
})

test("markAllDevicesNeedsEnroll flags each device once", async () => {
  const store = makeStore()
  await store.saveDevice(makeDevice("dev_a"))
  await store.saveDevice(makeDevice("dev_b", { needsEnroll: true }))
  const changed = await store.markAllDevicesNeedsEnroll(1_760_000_100_000)
  assert.equal(changed, 1)
  const devices = await store.listDevices()
  assert.ok(devices.every((device) => device.needsEnroll))
})

test("registration round-trips through storage", async () => {
  const store = makeStore()
  assert.equal(await store.getRegistration(), undefined)
  await store.saveRegistration({
    tenant: "host-a",
    app: "opencode",
    token: "tnt_x",
    privateKeyB64: "priv",
    publicB64: "pub",
    registeredAt: 1,
    rotatedAt: undefined,
    generation: 1,
  })
  const registration = await store.getRegistration()
  assert.equal(registration?.token, "tnt_x")
  assert.equal(registration?.generation, 1)
})

test("withLock serializes overlapping critical sections on one key", async () => {
  let inside = 0
  let maxInside = 0
  const work = async (): Promise<void> => {
    await withLock("k", async () => {
      inside += 1
      maxInside = Math.max(maxInside, inside)
      await new Promise((resolve) => setTimeout(resolve, 5))
      inside -= 1
    })
  }
  // A different key is intentionally independent and touches no counters.
  const other = withLock("other", async () => {})
  await Promise.all([work(), work(), work(), other])
  assert.equal(maxInside, 1)
})

test("stats accumulate and merge", async () => {
  const store = makeStore()
  assert.equal((await store.getStats()).accepted, 0)
  await store.updateStats({ enqueued: 3 })
  await store.updateStats({ accepted: 2, lastError: undefined })
  const stats = await store.getStats()
  assert.equal(stats.enqueued, 3)
  assert.equal(stats.accepted, 2)
  assert.equal(stats.lastError, undefined)
})

test("scans follow next cursors across every page", async () => {
  // Page size 2: nothing may be lost after the first storage.list call.
  const store = makeStore({ kv: new MemoryKv(2) })
  for (const id of ["dev_a", "dev_b", "dev_c", "dev_d", "dev_e"]) {
    await store.saveDevice(makeDevice(id))
  }
  const devices = await store.listDevices()
  assert.deepEqual(
    devices.map((device) => device.id).sort(),
    ["dev_a", "dev_b", "dev_c", "dev_d", "dev_e"],
  )
  // Outbox pages too.
  for (let index = 0; index < 4; index += 1) {
    await store.enqueueItem(
      makeItem({ id: `evt_${index}::dev_a`, eventId: `evt_${index}` }),
    )
  }
  assert.equal((await store.listOutbox()).length, 4)
})

test("storage scopes isolate registrations, devices, dedupe and leases", async () => {
  const kv = new MemoryKv()
  const alpha = new PushStore(kv, "scope-a")
  const beta = new PushStore(kv, "scope-b")
  await alpha.saveDevice(makeDevice("dev_a"))
  await alpha.saveRegistration(makeRegistrationInScope())
  await alpha.markSent("evt_1", 1_760_000_000_000)
  assert.equal(await alpha.lease("owner-a", 1_760_000_000_000, 30_000), true)

  // Same physical KV, but a different options-scope sees none of it.
  assert.equal(await beta.getDevice("dev_a"), undefined)
  assert.equal((await beta.listDevices()).length, 0)
  assert.equal(await beta.getRegistration(), undefined)
  assert.equal(await beta.isSent("evt_1"), false)
  assert.equal(await beta.getLease(), undefined)
  // …while the owning scope still reads everything back.
  assert.equal((await alpha.getDevice("dev_a"))?.id, "dev_a")
  assert.ok(await alpha.isSent("evt_1"))
})

test("patchDevice merges without resurrecting removed devices", async () => {
  const store = makeStore()
  await store.saveDevice(makeDevice("dev_a", { lastResult: "accepted" }))
  assert.equal(
    await store.patchDevice("dev_a", { needsEnroll: true, updatedAt: 1_760_000_100_000 }),
    true,
  )
  const patched = await store.getDevice("dev_a")
  assert.equal(patched?.needsEnroll, true)
  // Untouched fields survive the patch (no stale-snapshot overwrite).
  assert.equal(patched?.lastResult, "accepted")
  assert.equal(patched?.destinationToken, "ab".repeat(16))

  await store.removeDevice("dev_a")
  // A patch after removal reports false and must NOT recreate the device.
  assert.equal(await store.patchDevice("dev_a", { needsEnroll: true }), false)
  assert.equal(await store.getDevice("dev_a"), undefined)
})

function makeRegistrationInScope(): Registration {
  return {
    tenant: "host-a",
    app: "opencode",
    token: "tnt_scope",
    privateKeyB64: "priv",
    publicB64: "pub",
    registeredAt: 1,
    rotatedAt: undefined,
    generation: 1,
  }
}
