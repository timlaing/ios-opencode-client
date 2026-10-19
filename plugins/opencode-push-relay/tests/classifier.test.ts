// SPDX-License-Identifier: MPL-2.0

import assert from "node:assert/strict"
import { test } from "node:test"

import { ALL_CATEGORIES, classify, ledgerKey } from "../src/classifier.ts"

const all = { categories: ALL_CATEGORIES, contentLevel: "minimal" } as const

test("session success maps to sessionCompleted with a stable ledger key", () => {
  const draft = classify(
    { type: "session.execution.succeeded", id: "evt_1", data: { sessionID: "ses_1" } },
    "host-a",
    all,
  )
  assert.ok(draft)
  assert.equal(draft.category, "sessionCompleted")
  assert.equal(draft.sessionID, "ses_1")
  assert.equal(draft.ownerID, null)
  assert.equal(draft.transitionID, "evt_1")
  assert.equal(draft.ledgerKey, ledgerKey("host-a", "ses_1", null, "evt_1"))
  assert.equal(draft.ledgerKey, "host:host-a|session:ses_1|owner:-|transition:evt_1")
  assert.equal(draft.title, "Session completed")
})

test("failure copy depends on content level", () => {
  const event = {
    type: "session.execution.failed",
    id: "evt_2",
    data: { sessionID: "ses_1", error: { message: "model timeout" } },
  }
  const minimal = classify(event, "host-a", all)
  assert.equal(minimal?.body, "The session stopped with an error.")
  const summaries = classify(event, "host-a", {
    categories: ALL_CATEGORIES,
    contentLevel: "summaries",
  })
  assert.equal(summaries?.body, "model timeout")
})

test("failure summary shapes: string, nested data, unusable", () => {
  const summaries = { categories: ALL_CATEGORIES, contentLevel: "summaries" } as const
  const stringy = classify(
    { type: "session.execution.failed", id: "e", data: { sessionID: "s", error: "boom" } },
    "h",
    summaries,
  )
  assert.equal(stringy?.body, "boom")
  const nested = classify(
    {
      type: "session.execution.failed",
      id: "e",
      data: { sessionID: "s", error: { data: { message: "nested boom" } } },
    },
    "h",
    summaries,
  )
  assert.equal(nested?.body, "nested boom")
  const unusable = classify(
    { type: "session.execution.failed", id: "e", data: { sessionID: "s", error: {} } },
    "h",
    summaries,
  )
  assert.equal(unusable?.body, "The session stopped with an error.")
})

test("permission and form events route to their owner", () => {
  const permission = classify(
    { type: "permission.asked", id: "evt_3", data: { sessionID: "ses_1", requestID: "req_9" } },
    "host-a",
    all,
  )
  assert.equal(permission?.category, "permissionRequested")
  assert.equal(permission?.ownerID, "req_9")
  assert.equal(
    permission?.ledgerKey,
    "host:host-a|session:ses_1|owner:req_9|transition:evt_3",
  )
  const form = classify(
    { type: "form.created", id: "evt_4", data: { sessionID: "ses_1", id: "form_7" } },
    "host-a",
    all,
  )
  assert.equal(form?.category, "formRequested")
  assert.equal(form?.ownerID, "form_7")
})

test("owner events without an owner id are dropped (no stable ledger key)", () => {
  assert.equal(
    classify({ type: "permission.asked", id: "e", data: { sessionID: "s" } }, "h", all),
    null,
  )
  assert.equal(classify({ type: "form.created", id: "e", data: { sessionID: "s" } }, "h", all), null)
})

test("events without sessionID or event id are dropped", () => {
  assert.equal(classify({ type: "session.execution.succeeded", id: "e", data: {} }, "h", all), null)
  assert.equal(
    classify({ type: "session.execution.succeeded", data: { sessionID: "s" } }, "h", all),
    null,
  )
  assert.equal(classify({ type: "session.execution.succeeded", id: "e" }, "h", all), null)
  assert.equal(classify({}, "h", all), null)
})

test("noise events are never alert material", () => {
  for (const type of [
    "message.updated",
    "message.delta",
    "tool.execute.started",
    "permission.updated",
    "session.status",
    "storage.write",
  ]) {
    assert.equal(
      classify({ type, id: "e", data: { sessionID: "s" } }, "h", all),
      null,
      `expected null for ${type}`,
    )
  }
})

test("host-disabled categories are dropped", () => {
  const onlyFailure = { categories: ["sessionFailed"], contentLevel: "minimal" } as const
  assert.equal(
    classify(
      { type: "session.execution.succeeded", id: "e", data: { sessionID: "s" } },
      "h",
      onlyFailure,
    ),
    null,
  )
  assert.ok(
    classify({ type: "session.execution.failed", id: "e", data: { sessionID: "s" } }, "h", onlyFailure),
  )
})
