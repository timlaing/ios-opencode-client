// SPDX-License-Identifier: MPL-2.0

import assert from "node:assert/strict"
import { test } from "node:test"

import { decodeGrant, validateEnrollment } from "../src/grant.ts"
import { sha256hex } from "../src/signing.ts"

import { makeClaims, makeGrant } from "./helpers.ts"

const expectation = {
  tenant: "host-a",
  app: "opencode",
  publicB64: "FIXTURE_PUBKEY_BASE64URL",
  destinationToken: "ab".repeat(16),
}

test("decodeGrant parses v1 grants and rejects malformed input", () => {
  const claims = decodeGrant(makeGrant(makeClaims()))
  assert.ok(claims)
  assert.equal(claims.ten, "host-a")
  assert.equal(claims.app, "opencode")
  assert.deepEqual(claims.kinds, ["alert"])

  assert.equal(decodeGrant("not-a-grant"), null)
  assert.equal(decodeGrant("v2.abc.def"), null)
  assert.equal(decodeGrant("v1.only-two-parts"), null)
  assert.equal(decodeGrant("v1.!!!not-base64!!!.sig"), null)
  // JSON array payloads are not claim objects.
  const arrayPayload = Buffer.from("[1,2,3]").toString("base64url")
  assert.equal(decodeGrant(`v1.${arrayPayload}.sig`), null)
})

test("validateEnrollment accepts a grant bound to this host and token", () => {
  const result = validateEnrollment(makeGrant(makeClaims()), expectation)
  assert.ok(result.ok)
  assert.equal(result.claims.env, "sandbox")
})

test("mismatch problems are reported precisely", () => {
  const bad = (claims: Record<string, unknown>): string => {
    const result = validateEnrollment(makeGrant(makeClaims(claims)), expectation)
    assert.equal(result.ok, false)
    assert.ok(!result.ok)
    return result.problem
  }
  assert.equal(bad({ ten: "host-b" }), "tenant_mismatch")
  assert.equal(bad({ app: "other-app" }), "app_mismatch")
  assert.equal(bad({ tpk: "OTHER_PUBLIC_KEY" }), "pubkey_mismatch")
  assert.equal(bad({ tok: `sha256:${sha256hex("cd".repeat(16))}` }), "token_mismatch")
  assert.equal(bad({ exp: Math.floor(Date.now() / 1000) - 10 }), "grant_expired")
  const malformed = validateEnrollment("v1.garbage", expectation)
  assert.equal(malformed.ok, false)
  assert.ok(!malformed.ok)
  assert.equal(malformed.problem, "malformed_grant")
})

test("an exp claim exactly now is expired; a future exp passes", () => {
  const now = Math.floor(Date.now() / 1000)
  const expired = validateEnrollment(makeGrant(makeClaims({ exp: now })), expectation)
  assert.equal(expired.ok, false)
  const live = validateEnrollment(makeGrant(makeClaims({ exp: now + 60 })), expectation)
  assert.ok(live.ok)
})
