// SPDX-License-Identifier: MPL-2.0

import assert from "node:assert/strict"
import { test } from "node:test"

import { pumpEvents, retryDelay } from "../src/events.ts"

/** A subscribe fn that serves one stream per call from these definitions. */
function streams(defs: Array<() => AsyncIterable<unknown>>): {
  subscribe: (signal: AbortSignal) => AsyncIterable<unknown>
  calls: () => number
} {
  let index = 0
  return {
    subscribe: () => {
      const make = defs[Math.min(index, defs.length - 1)]
      assert.ok(make, "no stream definition left")
      index += 1
      return make()
    },
    calls: () => index,
  }
}

async function* eventsOf(...items: unknown[]): AsyncGenerator<unknown> {
  for (const item of items) yield item
}

async function* throws(error: Error): AsyncGenerator<unknown> {
  yield "before-error"
  throw error
}

async function* throwsImmediately(error: Error): AsyncGenerator<unknown> {
  throw error
}

test("retryDelay grows exponentially and caps at 30s", () => {
  assert.equal(retryDelay(1), 1_000)
  assert.equal(retryDelay(2), 2_000)
  assert.equal(retryDelay(3), 4_000)
  assert.equal(retryDelay(10), 30_000)
  assert.equal(retryDelay(99), 30_000)
})

test("the pump resubscribes when the stream ends", async () => {
  const first = streams([() => eventsOf("a", "b"), () => eventsOf("c")])
  const seen: unknown[] = []
  const controller = new AbortController()
  const done = pumpEvents(
    first.subscribe,
    async (event) => {
      seen.push(event)
      // Stop the loop after the second subscription delivers.
      if (event === "c") controller.abort()
    },
    controller.signal,
    () => {},
    async () => {},
  )
  await done
  assert.deepEqual(seen, ["a", "b", "c"])
  assert.equal(first.calls(), 2)
})

test("the pump resubscribes when the stream throws", async () => {
  const first = streams([() => throws(new Error("boom")), () => eventsOf("after")])
  const seen: unknown[] = []
  const logs: string[] = []
  const controller = new AbortController()
  await pumpEvents(
    first.subscribe,
    async (event) => {
      seen.push(event)
      if (event === "after") controller.abort()
    },
    controller.signal,
    (message) => logs.push(message),
    async () => {},
  )
  assert.deepEqual(seen, ["before-error", "after"])
  assert.equal(first.calls(), 2)
  assert.ok(logs.some((message) => message.includes("resubscribing")))
})

test("handler failures are logged and the stream keeps flowing", async () => {
  const seen: unknown[] = []
  const logs: string[] = []
  const controller = new AbortController()
  await pumpEvents(
    (signal) => eventsOf("a", "b", "c"),
    async (event) => {
      seen.push(event)
      if (event === "b") throw new Error("handler exploded")
      if (event === "c") controller.abort()
    },
    controller.signal,
    (message) => logs.push(message),
    async () => {},
  )
  assert.deepEqual(seen, ["a", "b", "c"])
  assert.ok(logs.some((message) => message.includes("handler exploded")))
})

test("an aborted signal stops the pump without resubscribing", async () => {
  const first = streams([() => eventsOf("a")])
  const controller = new AbortController()
  await pumpEvents(
    first.subscribe,
    async (event) => {
      controller.abort()
    },
    controller.signal,
    () => {},
    async () => {
      throw new Error("sleep must not run after abort")
    },
  )
  assert.equal(first.calls(), 1)
})

test("resubscribe backoff grows between failed attempts", async () => {
  const delays: number[] = []
  // Streams that die WITHOUT delivering: the backoff must grow.
  const first = streams([() => throwsImmediately(new Error("down"))])
  const controller = new AbortController()
  let attempts = 0
  await pumpEvents(
    first.subscribe,
    async () => {},
    controller.signal,
    () => {
      attempts += 1
      if (attempts === 3) controller.abort()
    },
    async (ms) => {
      delays.push(ms)
    },
  )
  assert.deepEqual(delays, [1_000, 2_000])
})
