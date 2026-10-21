// SPDX-License-Identifier: MPL-2.0

import { signHeaders, type Creds } from "./signing.ts"

/**
 * HTTP client for one apns-push-relay instance.
 *
 * Signed routes carry `Authorization: Bearer tnt_…`, `x-relay-time`,
 * `x-relay-nonce` and `x-relay-signature` over the canonical message (see
 * `signing.ts`). Failures become `RelayError` with the relay's stable machine
 * code; `status === 0` means the relay was never reached or answered with an
 * unusable body (`malformed_response`).
 *
 * Trust boundary: everything the relay supplies is relay-controlled text.
 * Codes are reduced to a machine-safe alphabet and length here, and details
 * are control-stripped and capped — details are for the server log only and
 * must never reach prompt-bound command reports (see commands.ts). Successful
 * responses are validated per method so a malformed 2xx surfaces as
 * `malformed_response` (transport-class, retried with backoff) instead of
 * silently becoming `{}`.
 */

/** Machine-token shape for relay-supplied codes: `[A-Za-z0-9_.:/-]{1,64}`. */
export function safeCode(value: string, fallback = "unknown"): string {
  const cleaned = value.replace(/[^A-Za-z0-9_.:/-]/g, "").slice(0, 64)
  return cleaned.length > 0 ? cleaned : fallback
}

/** Single-line, bounded relay detail for log lines (never for prompt text). */
export function safeDetail(value: string): string {
  let out = ""
  for (const ch of value) {
    const code = ch.codePointAt(0) ?? 0
    out += code < 0x20 || code === 0x7f ? " " : ch
  }
  return out.trim().slice(0, 200)
}

/** Display form for an error in prompt-bound reports: status+code, no detail. */
export function describeError(error: unknown): string {
  if (error instanceof RelayError) return `${error.status === 0 ? "-" : error.status} ${error.code}`
  return error instanceof Error ? error.message : String(error)
}

export class RelayError extends Error {
  readonly status: number
  readonly code: string
  readonly detail: string

  constructor(status: number, code: string, detail = "") {
    const safe = safeDetail(detail)
    super(`${status === 0 ? "-" : status} ${safeCode(code)}${safe ? `: ${safe}` : ""}`)
    this.name = "RelayError"
    this.status = status
    this.code = safeCode(code)
    this.detail = safe
  }
}

export interface RegisterResponse {
  tenant: string
  app: string
  token: string
  registered_at: number
  expires_at: number
}

export interface RotateResponse {
  tenant: string
  app: string
  token: string
  rotated_at: number
}

export type PushKind = "alert" | "background" | "liveActivity"

/** Relay payload allowlist: alert {title, subtitle, body, category, thread, sound}. */
export interface PushContent {
  readonly alert?: {
    readonly title?: string
    readonly subtitle?: string
    readonly body?: string
    readonly category?: string
    readonly thread?: string
    readonly sound?: string
  }
  readonly background?: { readonly payload?: unknown }
  readonly liveActivity?: Record<string, unknown>
  /** Standard-alphabet base64 (the relay validates with `b64decode`), ≤1024 decoded bytes. */
  readonly sealed?: string
}

export interface PushRequest {
  readonly grant: string
  readonly destinationToken: string
  readonly kind: PushKind
  readonly eventId?: string
  readonly expiresAt?: number
  readonly content: PushContent
}

export interface PushResponse {
  readonly result: "accepted" | "invalidDestination" | "retryable" | "rejected"
  readonly apnsId?: string | null
  readonly detail?: string | null
  readonly retryAfter?: number | null
}

export interface RelayedGrant {
  readonly grant: string
  readonly expiresAt: number
}

/** Outcome of the non-mutating binding probe (see `probeBinding`). */
export type BindingProbe =
  | { readonly state: "bound" } // authenticated fine; grant parsing ran
  | { readonly state: "unbound" } // registered, no signing key bound yet
  | { readonly state: "no-binding" } // unknown_tenant: idle-expired or revoked
  | { readonly state: "rejected"; readonly code: string } // key mismatch / clock / nonce

/** The delivery-facing slice of the relay; faked in tests. */
export interface RelayApi {
  push(request: PushRequest): Promise<PushResponse>
  renew(grant: string, ttl?: number): Promise<RelayedGrant>
  revoke(grant: string): Promise<{ revoked: string }>
}

const PUSH_RESULTS = ["accepted", "invalidDestination", "retryable", "rejected"] as const

function asRecord(body: unknown, what: string): Record<string, unknown> {
  if (body === null || typeof body !== "object" || Array.isArray(body)) {
    throw new RelayError(0, "malformed_response", `${what}: body is not an object`)
  }
  return body as Record<string, unknown>
}

function requireString(record: Record<string, unknown>, key: string, what: string): string {
  const value = record[key]
  if (typeof value !== "string" || value.length === 0) {
    throw new RelayError(0, "malformed_response", `${what}: missing ${key}`)
  }
  return value
}

function requireNumber(record: Record<string, unknown>, key: string, what: string): number {
  const value = record[key]
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new RelayError(0, "malformed_response", `${what}: missing ${key}`)
  }
  return value
}

export class RelayClient implements RelayApi {
  private readonly baseUrl: string
  private readonly creds: () => Creds | undefined

  constructor(baseUrl: string, creds: () => Creds | undefined) {
    this.baseUrl = baseUrl.replace(/\/+$/, "")
    this.creds = creds
  }

  private async request(
    method: string,
    path: string,
    body: unknown | undefined,
    signed: boolean,
  ): Promise<unknown> {
    const payload = body === undefined ? undefined : JSON.stringify(body)
    const headers: Record<string, string> = { accept: "application/json" }
    if (payload !== undefined) headers["content-type"] = "application/json"
    if (signed) {
      const creds = this.creds()
      if (!creds) throw new RelayError(0, "not_configured", "no tenant token in plugin storage")
      Object.assign(headers, signHeaders(creds, method, path, payload ?? ""))
    }
    let response: Response
    try {
      response = await fetch(`${this.baseUrl}${path}`, { method, headers, body: payload })
    } catch (cause) {
      throw new RelayError(0, "network_error", cause instanceof Error ? cause.message : String(cause))
    }
    if (!response.ok) throw await RelayClient.errorFrom(response)
    const text = await response.text()
    if (text.length === 0) return {}
    try {
      return JSON.parse(text) as unknown
    } catch {
      return {}
    }
  }

  private static async errorFrom(response: Response): Promise<RelayError> {
    let code = `http_${response.status}`
    let detail = ""
    try {
      const body = (await response.json()) as { error?: unknown; detail?: unknown }
      if (typeof body.error === "string") code = body.error
      if (typeof body.detail === "string") detail = body.detail
      else if (body.detail !== undefined) detail = JSON.stringify(body.detail)
    } catch {
      // non-JSON error body: keep the generic code
    }
    return new RelayError(response.status, code, detail)
  }

  async register(input: { id: string; app: string }): Promise<RegisterResponse> {
    const body = asRecord(await this.request("POST", "/v1/register", input, false), "register")
    return {
      tenant: requireString(body, "tenant", "register"),
      app: requireString(body, "app", "register"),
      token: requireString(body, "token", "register"),
      registered_at: requireNumber(body, "registered_at", "register"),
      expires_at: requireNumber(body, "expires_at", "register"),
    }
  }

  /** Rotate token + signing key under proof of possession (spec §2.7). */
  async rotate(newPubkey: string): Promise<RotateResponse> {
    const body = asRecord(
      await this.request("POST", "/v1/rotate", { pubkey: newPubkey }, true),
      "rotate",
    )
    return {
      tenant: requireString(body, "tenant", "rotate"),
      app: requireString(body, "app", "rotate"),
      token: requireString(body, "token", "rotate"),
      rotated_at: requireNumber(body, "rotated_at", "rotate"),
    }
  }

  async push(request: PushRequest): Promise<PushResponse> {
    const body = asRecord(await this.request("POST", "/v1/push", request, true), "push")
    const result = body["result"]
    if (typeof result !== "string" || !(PUSH_RESULTS as readonly string[]).includes(result)) {
      throw new RelayError(0, "malformed_response", "push: unknown result")
    }
    const apnsId = body["apnsId"]
    const detail = body["detail"]
    const retryAfter = body["retryAfter"]
    return {
      result: result as PushResponse["result"],
      apnsId: typeof apnsId === "string" ? apnsId : null,
      detail: typeof detail === "string" ? safeDetail(detail) : null,
      retryAfter: typeof retryAfter === "number" ? retryAfter : null,
    }
  }

  async renew(grant: string, ttl?: number): Promise<RelayedGrant> {
    const input: { grant: string; ttl?: number } = { grant }
    if (ttl !== undefined) input.ttl = ttl
    const body = asRecord(
      await this.request("POST", "/v1/enroll/renew", input, true),
      "enroll/renew",
    )
    return {
      grant: requireString(body, "grant", "enroll/renew"),
      expiresAt: requireNumber(body, "expiresAt", "enroll/renew"),
    }
  }

  async revoke(grant: string): Promise<{ revoked: string }> {
    const body = asRecord(await this.request("POST", "/v1/revoke", { grant }, true), "revoke")
    return { revoked: requireString(body, "revoked", "revoke") }
  }

  async health(): Promise<{ status: string }> {
    const body = asRecord(await this.request("GET", "/health", undefined, false), "health")
    return { status: safeCode(requireString(body, "status", "health")) }
  }

  /**
   * Classify this host's binding state without mutating anything: a signed
   * renew of an unparseable grant. The signed auth layer runs before grant
   * parsing, so the failure code disambiguates: `unknown_tenant` = no binding,
   * `enrollment_required` = registered but never enrolled, `invalid_signature`
   * = stored key differs from ours, any grant/403 error = bound (auth passed),
   * other 401s (clock/nonce) = rejected with that code.
   */
  async probeBinding(): Promise<BindingProbe> {
    try {
      await this.renew("v1.push-relay-probe")
      return { state: "bound" }
    } catch (error) {
      if (!(error instanceof RelayError)) throw error
      if (error.status === 0) throw error // never reached / not configured
      switch (error.code) {
        case "unknown_tenant":
          return { state: "no-binding" }
        case "enrollment_required":
          return { state: "unbound" }
        case "invalid_signature":
          return { state: "rejected", code: "invalid_signature" }
        default:
          break
      }
      if (error.status === 401) return { state: "rejected", code: error.code }
      return { state: "bound" }
    }
  }
}
