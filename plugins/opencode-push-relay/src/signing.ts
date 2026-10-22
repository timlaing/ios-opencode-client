// SPDX-License-Identifier: MPL-2.0

/**
 * Ed25519 request signing for the relay's signed routes.
 *
 * The canonical message mirrors `apns_relay.signing.canonical_message` byte
 * for byte (the relay's `tests/fixtures/canonical.json` pins the encoding and
 * is vendored under this package's `tests/fixtures/`):
 *
 *   SHA256HEX(token) \n METHOD \n path \n timestamp \n nonce \n SHA256HEX(body)
 *
 * The token is digested, never signed raw; the method is uppercased; the body
 * digest covers the exact bytes sent.
 */

import { createHash, createPrivateKey, createPublicKey, generateKeyPairSync, randomBytes, sign as nodeSign, verify as nodeVerify, type KeyObject } from "node:crypto"

/** Stored tenant credentials: base64 PKCS#8 private key + base64url pubkey. */
export interface StoredKeyPair {
  /** PKCS#8 DER, base64 — JSON-safe for plugin storage. */
  readonly privateKeyB64: string
  /** Raw 32-byte Ed25519 public key, base64url (the relay's tenantPubkey). */
  readonly publicB64: string
}

/** Signing material for one request. */
export interface Creds {
  readonly token: string
  readonly privateKeyB64: string
}

export function sha256hex(data: string | Uint8Array): string {
  return createHash("sha256").update(data).digest("hex")
}

export function generateKeyPair(): StoredKeyPair {
  const { privateKey } = generateKeyPairSync("ed25519")
  const privateKeyB64 = privateKey.export({ type: "pkcs8", format: "der" }).toString("base64")
  const publicJwk = createPublicKey(privateKey).export({ format: "jwk" }) as { x?: string }
  if (!publicJwk.x) throw new Error("ed25519 public key export missing x")
  return { privateKeyB64, publicB64: publicJwk.x }
}

function privateKeyOf(privateKeyB64: string): KeyObject {
  // Explicit DER/PKCS#8: bare-Buffer import cannot resolve ed25519 on
  // OpenSSL 3.x ("DECODER routines::unsupported").
  return createPrivateKey({
    key: Buffer.from(privateKeyB64, "base64"),
    format: "der",
    type: "pkcs8",
  })
}

export interface CanonicalInput {
  readonly token: string
  readonly method: string
  readonly path: string
  readonly timestamp: string
  readonly nonce: string
  readonly body: string
}

/** The exact bytes Ed25519 signs. */
export function canonicalMessage(input: CanonicalInput): Buffer {
  return Buffer.from(
    [
      sha256hex(input.token),
      input.method.toUpperCase(),
      input.path,
      input.timestamp,
      input.nonce,
      sha256hex(input.body),
    ].join("\n"),
    "utf8",
  )
}

/** Headers for a signed route: bearer token + time/nonce/signature. */
export function signHeaders(
  creds: Creds,
  method: string,
  path: string,
  body: string,
  options?: { readonly timestamp?: number; readonly nonce?: string },
): Record<string, string> {
  const timestamp = String(options?.timestamp ?? Math.floor(Date.now() / 1000))
  const nonce = options?.nonce ?? randomBytes(16).toString("base64url")
  const message = canonicalMessage({ token: creds.token, method, path, timestamp, nonce, body })
  const signature = nodeSign(null, message, privateKeyOf(creds.privateKeyB64)).toString("base64url")
  return {
    authorization: `Bearer ${creds.token}`,
    "x-relay-time": timestamp,
    "x-relay-nonce": nonce,
    "x-relay-signature": signature,
  }
}

/** Verify a signature under a base64url public key (tests and diagnostics). */
export function verifySignature(publicB64: string, message: Buffer, signatureB64url: string): boolean {
  const key = createPublicKey({ key: { kty: "OKP", crv: "Ed25519", x: publicB64 }, format: "jwk" })
  return nodeVerify(null, message, key, Buffer.from(signatureB64url, "base64url"))
}
