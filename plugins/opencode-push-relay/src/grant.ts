// SPDX-License-Identifier: MPL-2.0

import { sha256hex } from "./signing.ts"

/**
 * Decode-only grant inspection — mirrors `relay_client.grant_claims`.
 *
 * This does NOT verify the grant signature; the relay verifies grants itself
 * on every delivery, so nothing security-relevant relies on this decode. The
 * checks below are pairing-time sanity checks so a mis-paired client fails
 * fast with a declared RPC error instead of a mystery at push time.
 */
export interface GrantClaims {
  readonly jti?: string
  readonly ten?: string
  readonly tpk?: string
  readonly app?: string
  readonly kinds?: readonly string[]
  readonly env?: string
  readonly tok?: string
  readonly iat?: number
  readonly exp?: number
  readonly ttl?: number
  readonly [claim: string]: unknown
}

/** Parse `v1.<base64url claims>.<signature>`; null when not parseable. */
export function decodeGrant(grant: string): GrantClaims | null {
  const parts = grant.split(".")
  if (parts.length !== 3 || parts[0] !== "v1") return null
  const payload = parts[1] ?? ""
  try {
    const padded = `${payload}${"=".repeat((4 - (payload.length % 4)) % 4)}`
    const parsed: unknown = JSON.parse(Buffer.from(padded, "base64").toString("utf8"))
    if (parsed === null || typeof parsed !== "object" || Array.isArray(parsed)) return null
    return parsed as GrantClaims
  } catch {
    return null
  }
}

export type EnrollmentProblem =
  | "malformed_grant"
  | "grant_expired"
  | "tenant_mismatch"
  | "pubkey_mismatch"
  | "token_mismatch"

export interface EnrollmentExpectation {
  readonly tenant: string
  readonly publicB64: string
  readonly destinationToken: string
}

/**
 * Cross-check a delivered grant against the current binding before storing it.
 * The grant must be bound to this tenant, this host's signing key, and exactly
 * the destination token the client is pairing — the same three claims the
 * relay enforces on `/v1/push`.
 */
export function validateEnrollment(
  grant: string,
  expected: EnrollmentExpectation,
): { ok: true; claims: GrantClaims } | { ok: false; problem: EnrollmentProblem } {
  const claims = decodeGrant(grant)
  if (claims === null) return { ok: false, problem: "malformed_grant" }
  if (typeof claims.exp === "number" && claims.exp <= Math.floor(Date.now() / 1000)) {
    return { ok: false, problem: "grant_expired" }
  }
  if (claims.ten !== expected.tenant) return { ok: false, problem: "tenant_mismatch" }
  if (claims.tpk !== expected.publicB64) return { ok: false, problem: "pubkey_mismatch" }
  if (claims.tok !== `sha256:${sha256hex(expected.destinationToken)}`) {
    return { ok: false, problem: "token_mismatch" }
  }
  return { ok: true, claims }
}
