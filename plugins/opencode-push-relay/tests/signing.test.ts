// SPDX-License-Identifier: MPL-2.0

import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { test } from "node:test"

import {
  canonicalMessage,
  generateKeyPair,
  sha256hex,
  signHeaders,
  verifySignature,
} from "../src/signing.ts"

const fixture = JSON.parse(
  readFileSync(new URL("./fixtures/canonical.json", import.meta.url), "utf8"),
) as {
  inputs: {
    token: string
    method: string
    path: string
    timestamp: number
    nonce: string
    body: string
  }
  token_digest: string
  body_digest: string
  canonical_message: string
}

test("canonical message matches the relay's golden fixture byte for byte", () => {
  const { inputs } = fixture
  assert.equal(sha256hex(inputs.token), fixture.token_digest)
  assert.equal(sha256hex(inputs.body), fixture.body_digest)
  const message = canonicalMessage({
    token: inputs.token,
    // Deliberately lowercase in the fixture — pins the uppercase rule.
    method: inputs.method,
    path: inputs.path,
    timestamp: String(inputs.timestamp),
    nonce: inputs.nonce,
    body: inputs.body,
  })
  assert.equal(message.toString("utf8"), fixture.canonical_message)
})

test("signHeaders produces signatures the relay's canonical verifies", () => {
  const keypair = generateKeyPair()
  const headers = signHeaders(
    { token: "tnt_test-token", privateKeyB64: keypair.privateKeyB64 },
    "post", // lowercase in — uppercase in the canonical
    "/v1/rotate",
    '{"pubkey":"new"}',
    { timestamp: 1_792_230_900, nonce: "fixed-nonce-0001" },
  )
  assert.equal(headers.authorization, "Bearer tnt_test-token")
  assert.equal(headers["x-relay-time"], "1792230900")
  assert.equal(headers["x-relay-nonce"], "fixed-nonce-0001")
  const signature = headers["x-relay-signature"]
  assert.ok(signature)
  const message = canonicalMessage({
    token: "tnt_test-token",
    method: "POST",
    path: "/v1/rotate",
    timestamp: "1792230900",
    nonce: "fixed-nonce-0001",
    body: '{"pubkey":"new"}',
  })
  assert.ok(verifySignature(keypair.publicB64, message, signature))
  // A different key must not verify the same signature.
  const other = generateKeyPair()
  assert.ok(!verifySignature(other.publicB64, message, signature))
  // Tampering with the body must not verify.
  const tampered = canonicalMessage({
    token: "tnt_test-token",
    method: "POST",
    path: "/v1/rotate",
    timestamp: "1792230900",
    nonce: "fixed-nonce-0001",
    body: '{"pubkey":"EVIL"}',
  })
  assert.ok(!verifySignature(keypair.publicB64, tampered, signature))
})

test("signHeaders defaults: current timestamp, random nonce, still verifiable", () => {
  const keypair = generateKeyPair()
  const headers = signHeaders(
    { token: "tnt_test-token", privateKeyB64: keypair.privateKeyB64 },
    "POST",
    "/v1/push",
    "",
  )
  const time = headers["x-relay-time"]
  const nonce = headers["x-relay-nonce"]
  const signature = headers["x-relay-signature"]
  assert.ok(time && nonce && signature)
  assert.ok(Math.abs(Number(time) - Math.floor(Date.now() / 1000)) <= 5)
  assert.ok(nonce.length >= 16)
  const message = canonicalMessage({
    token: "tnt_test-token",
    method: "POST",
    path: "/v1/push",
    timestamp: time,
    nonce,
    body: "",
  })
  assert.ok(verifySignature(keypair.publicB64, message, signature))
})

test("generated keypairs are distinct raw ed25519 keys in base64url", () => {
  const keypair = generateKeyPair()
  // Raw 32-byte ed25519 public key → 43 base64url chars, no padding.
  assert.match(keypair.publicB64, /^[A-Za-z0-9_-]{43}$/)
  assert.notEqual(generateKeyPair().publicB64, keypair.publicB64)
  // Private key is base64 PKCS#8 DER.
  const der = Buffer.from(keypair.privateKeyB64, "base64")
  assert.ok(der.length > 32)
})
