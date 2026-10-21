// SPDX-License-Identifier: MPL-2.0

import os from "node:os"

import { ALL_CATEGORIES, type ContentLevel, type PushCategory } from "./classifier.ts"

/**
 * Plugin options, as passed through `plugins[].options` in opencode.json(c).
 * Everything is configurable; with `relayUrl`/`app` missing the plugin stays
 * inert (commands still load so `/push-status` can explain what is missing).
 */
export interface PushConfig {
  /**
   * Relay base URL, no trailing slash, no query/fragment, `https://` unless
   * loopback (e.g. https://push.example.org).
   */
  readonly relayUrl: string
  /** Relay App id (operator-configured in the relay's config.yaml). */
  readonly app: string
  /** Tenant id for this host; defaults to the lowercased hostname. */
  readonly tenant: string
  /** Register with the relay at startup when credentials are absent. */
  readonly autoRegister: boolean
  /** Categories this host sends (devices may narrow further). */
  readonly categories: readonly PushCategory[]
  readonly contentLevel: ContentLevel
  /** Default session subscription for newly paired devices. */
  readonly defaultSessions: "all" | "none"
  /** APNs expiry window for alert pushes, seconds. */
  readonly pushTtlSeconds: number
  /** TTL requested on grant renewal; omitted = relay App default. */
  readonly grantTtlSeconds: number | undefined
}

export type ConfigResult =
  | { ok: true; config: PushConfig }
  | { ok: false; missing: string[]; problems: string[] }

function numberOption(
  raw: Record<string, unknown>,
  key: string,
  fallback: number,
  min: number,
  max: number,
  problems: string[],
): number {
  const value = raw[key]
  if (value === undefined) return fallback
  if (typeof value === "number" && Number.isInteger(value) && value >= min && value <= max) {
    return value
  }
  problems.push(`${key}: integer seconds between ${min} and ${max}`)
  return fallback
}

/** Loopback hosts that may use cleartext `http://` (development relays). */
function isLoopbackHost(hostname: string): boolean {
  const host = hostname.replace(/^\[/, "").replace(/\]$/, "").toLowerCase()
  return host === "localhost" || host === "127.0.0.1" || host === "::1"
}

/** Parse and validate plugin options. Never throws — returns a result. */
export function parseConfig(options: unknown): ConfigResult {
  const raw: Record<string, unknown> =
    options !== null && typeof options === "object"
      ? (options as Record<string, unknown>)
      : {}
  const missing: string[] = []
  const problems: string[] = []

  let relayUrl = ""
  const rawUrl = typeof raw["relayUrl"] === "string" ? raw["relayUrl"].trim() : ""
  if (rawUrl === "") {
    missing.push("relayUrl")
  } else {
    try {
      const parsed = new URL(rawUrl)
      if (parsed.protocol !== "https:" && parsed.protocol !== "http:") {
        throw new Error("unsupported scheme")
      }
      if (parsed.search !== "" || parsed.hash !== "") {
        // `RelayClient` appends `/v1/...` to the raw value — a query or
        // fragment would silently route requests to the wrong path.
        problems.push("relayUrl: must not include a query string or fragment")
      } else if (parsed.protocol === "http:" && !isLoopbackHost(parsed.hostname)) {
        // Registration tokens, grants and destination tokens would cross an
        // untrusted network in cleartext.
        problems.push(
          "relayUrl: must use https:// (http:// is accepted only for loopback development endpoints)",
        )
      } else {
        relayUrl = rawUrl.replace(/\/+$/, "")
      }
    } catch {
      problems.push("relayUrl: must be an http(s) URL")
    }
  }

  const app = typeof raw["app"] === "string" ? raw["app"].trim() : ""
  if (app === "") {
    missing.push("app")
  } else if (app.length > 64) {
    problems.push("app: at most 64 characters (relay bound)")
  }

  let tenant = typeof raw["tenant"] === "string" ? raw["tenant"].trim() : ""
  if (tenant === "") tenant = os.hostname().toLowerCase()
  if (tenant.length < 1 || tenant.length > 253) {
    problems.push("tenant: 1..253 characters")
  }

  let autoRegister = true
  if (raw["autoRegister"] !== undefined) {
    if (typeof raw["autoRegister"] === "boolean") autoRegister = raw["autoRegister"]
    else problems.push("autoRegister: must be a boolean")
  }

  let categories: PushCategory[] = [...ALL_CATEGORIES]
  if (raw["categories"] !== undefined) {
    const value = raw["categories"]
    if (Array.isArray(value)) {
      const valid: PushCategory[] = []
      const unknown: string[] = []
      for (const entry of value) {
        if (typeof entry === "string" && (ALL_CATEGORIES as readonly string[]).includes(entry)) {
          valid.push(entry as PushCategory)
        } else {
          unknown.push(String(entry))
        }
      }
      if (unknown.length > 0) {
        problems.push(
          `categories: unknown ${unknown.join(", ")} (allowed: ${ALL_CATEGORIES.join(", ")})`,
        )
      } else {
        categories = valid
      }
    } else {
      problems.push("categories: must be an array")
    }
  }

  let contentLevel: ContentLevel = "minimal"
  if (raw["contentLevel"] !== undefined) {
    if (raw["contentLevel"] === "minimal" || raw["contentLevel"] === "summaries") {
      contentLevel = raw["contentLevel"]
    } else {
      problems.push("contentLevel: must be minimal or summaries")
    }
  }

  let defaultSessions: "all" | "none" = "all"
  if (raw["defaultSessions"] !== undefined) {
    if (raw["defaultSessions"] === "all" || raw["defaultSessions"] === "none") {
      defaultSessions = raw["defaultSessions"]
    } else {
      problems.push("defaultSessions: must be all or none")
    }
  }

  const pushTtlSeconds = numberOption(raw, "pushTtlSeconds", 3600, 60, 86_400, problems)

  let grantTtlSeconds: number | undefined
  if (raw["grantTtlSeconds"] !== undefined) {
    grantTtlSeconds = numberOption(raw, "grantTtlSeconds", 3600, 300, 604_800, problems)
  }

  if (missing.length > 0 || problems.length > 0) {
    return { ok: false, missing, problems }
  }
  return {
    ok: true,
    config: {
      relayUrl,
      app,
      tenant,
      autoRegister,
      categories,
      contentLevel,
      defaultSessions,
      pushTtlSeconds,
      grantTtlSeconds,
    },
  }
}
