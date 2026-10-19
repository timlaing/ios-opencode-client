// SPDX-License-Identifier: MPL-2.0

import { signHeaders, type Creds } from "./signing.ts"

/**
 * HTTP client for one apns-push-relay instance.
 *
 * Signed routes carry `Authorization: Bearer tnt_…`, `x-relay-time`,
 * `x-relay-nonce` and `x-relay-signature` over the canonical message (see
 * `signing.ts`). Failures become `RelayError` with the relay's stable machine
 * code; `status === 0` means the relay was never reached.
 */
export class RelayError extends Error {
  readonly status: number
  readonly code: string
  readonly detail: string

  constructor(status: number, code: string, detail = "") {
    super(`${status === 0 ? "-" : status} ${code}${detail ? `: ${detail}` : ""}`)
    this.name = "RelayError"
    this.status = status
    this.code = code
    this.detail = detail
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
    return (await this.request("POST", "/v1/register", input, false)) as RegisterResponse
  }

  /** Rotate token + signing key under proof of possession (spec §2.7). */
  async rotate(newPubkey: string): Promise<RotateResponse> {
    return (await this.request("POST", "/v1/rotate", { pubkey: newPubkey }, true)) as RotateResponse
  }

  async push(request: PushRequest): Promise<PushResponse> {
    return (await this.request("POST", "/v1/push", request, true)) as PushResponse
  }

  async renew(grant: string, ttl?: number): Promise<RelayedGrant> {
    const body: { grant: string; ttl?: number } = { grant }
    if (ttl !== undefined) body.ttl = ttl
    return (await this.request("POST", "/v1/enroll/renew", body, true)) as RelayedGrant
  }

  async revoke(grant: string): Promise<{ revoked: string }> {
    return (await this.request("POST", "/v1/revoke", { grant }, true)) as { revoked: string }
  }

  async health(): Promise<{ status: string }> {
    return (await this.request("GET", "/health", undefined, false)) as { status: string }
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
