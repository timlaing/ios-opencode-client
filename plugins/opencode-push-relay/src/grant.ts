// SPDX-License-Identifier: MPL-2.0

import { sha256hex } from "./signing.ts"

/**
 * Local claim inspection for enrollment — mirrors `relay_client.grant_claims`.
 *
 * The grant's Ed25519 signature is made by the RELAY's grant-issuer key,
 * which v1 deliberately never ships to tenants ("single issuer key in v1, no
 * key-set shipping" — enrollment-spec A15), so this module cannot verify it.
 * The signature check happens through the relay instead: `handlers.ts` calls
 * `POST /v1/enroll/renew` with the presented grant before storing anything —
 * the relay verifies the signature and re-issues the grant it just minted.
 * What is verified HERE are the claims the relay itself enforces on
 * `/v1/push` (tenant, pubkey, app, destination-token hash, expiry): cheap
 * pairing-time sanity checks so a mis-paired client fails fast with a
 * declared RPC error instead of a mystery at push time.
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
  | "app_mismatch"
  | "pubkey_mismatch"
  | "token_mismatch"

export interface EnrollmentExpectation {
  readonly tenant: string
  readonly app: string
  readonly publicB64: string
  readonly destinationToken: string
}

/**
 * Cross-check a presented grant's claims against the current binding before
 * it is handed to the relay for signature verification. The claims must bind
 * this tenant, this app, this host's signing key, and exactly the destination
 * token the client is pairing — the same claims the relay enforces on
 * `/v1/push`. Claim checks alone cannot rule out forgery (see the module
 * comment); callers must verify the signature through the relay.
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
  if (claims.app !== expected.app) return { ok: false, problem: "app_mismatch" }
  if (claims.tpk !== expected.publicB64) return { ok: false, problem: "pubkey_mismatch" }
  if (claims.tok !== `sha256:${sha256hex(expected.destinationToken)}`) {
    return { ok: false, problem: "token_mismatch" }
  }
  return { ok: true, claims }
}
