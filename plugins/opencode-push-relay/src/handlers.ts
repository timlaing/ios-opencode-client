// SPDX-License-Identifier: MPL-2.0

import { randomUUID } from "node:crypto"

import { ALL_CATEGORIES, type PushCategory } from "./classifier.ts"
import type { PushConfig } from "./config.ts"
import { validateEnrollment } from "./grant.ts"
import { RelayError, type RelayClient } from "./relay.ts"
import { statusToRpc, type StatusReport } from "./status.ts"
import type { Device, DevicePrefs, PushStore, Registration } from "./store.ts"

/**
 * RPC handlers for the `push` contract, free of any OpenCode context so they
 * can be exercised directly in tests. `index.ts` wires the real context in.
 *
 * Handlers return `context.error(...)` (the documented failure path); thrown
 * errors surface as opaque `rpc.internal` failures, so every declared error
 * goes through the factory.
 */

export interface HandlerContext {
  error(type: string, message: string, data?: unknown): unknown
}

export type PushRpcHandlers = Record<
  string,
  (input: unknown, context: HandlerContext) => Promise<unknown>
>

export interface HandlerDeps {
  readonly config: PushConfig | undefined
  readonly store: PushStore
  readonly relay: RelayClient | undefined
  ensureRegistration(): Promise<Registration | undefined>
  buildStatusReport(): Promise<StatusReport>
}

const DEVICE_ID_PATTERN = /^[A-Za-z0-9._:-]{1,64}$/
const DESTINATION_TOKEN_PATTERN = /^[0-9a-fA-F]{32,2000}$/

/**
 * Merge a prefs patch over the plugin defaults (enroll) or the device's
 * current prefs (update). Unknown categories/levels are dropped, not fatal —
 * the schema already rejects them host-side; this is defense in depth for
 * older app versions.
 */
function parsePrefs(raw: unknown, config: PushConfig, base?: DevicePrefs): DevicePrefs {
  const input =
    raw !== null && typeof raw === "object" ? (raw as Record<string, unknown>) : {}
  const fallback: DevicePrefs = base ?? {
    sessions: config.defaultSessions === "all" ? "all" : [],
    categories: config.categories,
    contentLevel: config.contentLevel,
  }
  let sessions = fallback.sessions
  const rawSessions = input["sessions"]
  if (rawSessions === "all") {
    sessions = "all"
  } else if (Array.isArray(rawSessions)) {
    sessions = rawSessions
      .filter(
        (entry): entry is string =>
          typeof entry === "string" && entry.length > 0 && entry.length <= 128,
      )
      .slice(0, 500)
  }
  let categories = fallback.categories
  const rawCategories = input["categories"]
  if (Array.isArray(rawCategories)) {
    categories = rawCategories.filter(
      (entry): entry is PushCategory =>
        typeof entry === "string" && (ALL_CATEGORIES as readonly string[]).includes(entry),
    )
  }
  let contentLevel = fallback.contentLevel
  if (input["contentLevel"] === "minimal" || input["contentLevel"] === "summaries") {
    contentLevel = input["contentLevel"]
  }
  return { sessions, categories, contentLevel }
}

function prefsResult(prefs: DevicePrefs): Record<string, unknown> {
  return {
    sessions: prefs.sessions === "all" ? "all" : [...prefs.sessions],
    categories: [...prefs.categories],
    contentLevel: prefs.contentLevel,
  }
}

export function makeRpcHandlers(deps: HandlerDeps): PushRpcHandlers {
  return {
    info: async (_input, context) => {
      const { config, relay } = deps
      if (config === undefined || relay === undefined) {
        return context.error(
          "not_configured",
          "This OpenCode host has no relay configured (set options.relayUrl and options.app).",
        )
      }
      const registration = await deps.store.getRegistration()
      const devices = await deps.store.listDevices()
      let binding: string | null = null
      if (registration !== undefined) {
        try {
          const probe = await relay.probeBinding()
          binding = probe.state === "rejected" ? `rejected:${probe.code}` : probe.state
        } catch {
          binding = null
        }
      }
      return {
        configured: true,
        relayUrl: config.relayUrl,
        app: config.app,
        tenant: config.tenant,
        registered: registration !== undefined,
        tenantPubkey: registration?.publicB64 ?? null,
        generation: registration?.generation ?? null,
        binding,
        categories: [...config.categories],
        contentLevel: config.contentLevel,
        defaultSessions: config.defaultSessions,
        devices: devices.length,
        needsEnroll: devices.filter((device) => device.needsEnroll).map((device) => device.id),
      }
    },

    enroll: async (raw, context) => {
      const input = (raw ?? {}) as Record<string, unknown>
      const { config, relay } = deps
      if (config === undefined || relay === undefined) {
        return context.error(
          "not_configured",
          "This OpenCode host has no relay configured (set options.relayUrl and options.app).",
        )
      }
      const registration = await deps.ensureRegistration()
      if (registration === undefined) {
        return context.error(
          "registration_missing",
          "This host has no relay registration — /push-status explains why.",
        )
      }
      const destinationToken =
        typeof input["destinationToken"] === "string" ? input["destinationToken"] : ""
      if (!DESTINATION_TOKEN_PATTERN.test(destinationToken)) {
        return context.error(
          "bad_destination_token",
          "destinationToken must be 32..2000 hex characters.",
        )
      }
      const grant = typeof input["grant"] === "string" ? input["grant"] : ""
      const check = validateEnrollment(grant, {
        tenant: registration.tenant,
        app: config.app,
        publicB64: registration.publicB64,
        destinationToken,
      })
      if (!check.ok) {
        return context.error(
          "invalid_grant",
          `Grant does not match this host's current binding (${check.problem}). Re-fetch tenant info and re-enroll.`,
          { problem: check.problem },
        )
      }
      return deps.store.withEnrollmentLock(destinationToken, async () => {
        // One active record per destination token: a client that re-pairs
        // without a stored deviceID (retry, reinstall) must reuse its
        // existing record — a second record for the same token would make
        // the engine fan out every event to the same phone twice.
        const sameToken = (await deps.store.listDevices()).filter(
          (entry) => entry.destinationToken === destinationToken,
        )
        const deviceID =
          typeof input["deviceID"] === "string" && input["deviceID"].length > 0
            ? input["deviceID"]
            : (sameToken[0]?.id ?? `dev_${randomUUID().replaceAll("-", "").slice(0, 12)}`)
        if (!DEVICE_ID_PATTERN.test(deviceID)) {
          return context.error("bad_device_id", "deviceID must match [A-Za-z0-9._:-]{1,64}.")
        }
        // Signature verification happens THROUGH the relay: v1 deliberately never
        // ships the grant-issuer key to tenants (enrollment-spec A15), so a
        // signed renew is the only verifier. Success also means the grant we
        // store was minted by the relay for our authenticated call — a forged
        // grant with plausible claims can never replace a working device's grant.
        let verifiedGrant: string
        let expiresAt: number
        try {
          const renewed = await relay.renew(grant, config.grantTtlSeconds)
          verifiedGrant = renewed.grant
          expiresAt = renewed.expiresAt
        } catch (error) {
          const problem = error instanceof RelayError ? error.code : "verification_unavailable"
          return context.error(
            "invalid_grant",
            `The relay could not verify this grant (${problem}). Check /push-status, re-fetch a grant from the relay's enrollment flow, then retry.`,
            { problem },
          )
        }
        const previous = await deps.store.getDevice(deviceID)
        const prefs = parsePrefs(input["prefs"], config, previous?.prefs)
        const now = Date.now()
        const nowSeconds = Math.floor(now / 1000)
        const renewAt = nowSeconds + Math.max(60, Math.floor((expiresAt - nowSeconds) / 2))
        const device: Device = {
          id: deviceID,
          destinationToken,
          grant: verifiedGrant,
          grantExpiresAt: expiresAt,
          grantRenewAt: renewAt,
          environment: typeof check.claims.env === "string" ? check.claims.env : null,
          prefs,
          needsEnroll: false,
          createdAt: previous?.createdAt ?? now,
          updatedAt: now,
          lastPushAt: previous?.lastPushAt,
          lastResult: previous?.lastResult,
          renewRetryAt: undefined,
        }
        await deps.store.saveDevice(device)
        // Whether the id was reused or explicitly supplied, this pairing
        // supersedes any other record bound to the same token: keep exactly
        // one active record per destination token.
        for (const stale of sameToken) {
          if (stale.id !== deviceID) await deps.store.removeDevice(stale.id)
        }
        return { deviceID, grantExpiresAt: expiresAt, environment: device.environment, ...prefsResult(prefs) }
      })
    },

    update: async (raw, context) => {
      const input = (raw ?? {}) as Record<string, unknown>
      const { config, relay } = deps
      if (config === undefined || relay === undefined) {
        return context.error("not_configured", "This OpenCode host has no relay configured.")
      }
      const registration = await deps.store.getRegistration()
      if (registration === undefined) {
        return context.error(
          "registration_missing",
          "This host has no relay registration — /push-status explains why.",
        )
      }
      const deviceID = typeof input["deviceID"] === "string" ? input["deviceID"] : ""
      const device = await deps.store.getDevice(deviceID)
      if (device === undefined) {
        return context.error("unknown_device", `No paired device ${deviceID} — enroll first.`)
      }
      const prefs = parsePrefs(input["prefs"], config, device.prefs)
      // Patch only the prefs — never rewrite delivery/renewal fields from a
      // snapshot that may have gone stale while this handler ran.
      const applied = await deps.store.patchDevice(deviceID, { prefs, updatedAt: Date.now() })
      if (!applied) {
        return context.error("unknown_device", `No paired device ${deviceID} — enroll first.`)
      }
      return { deviceID, ...prefsResult(prefs) }
    },

    status: async () => statusToRpc(await deps.buildStatusReport()),

    revoke: async (raw, context) => {
      const input = (raw ?? {}) as Record<string, unknown>
      const { config, relay } = deps
      if (config === undefined || relay === undefined) {
        return context.error("not_configured", "This OpenCode host has no relay configured.")
      }
      const deviceID = typeof input["deviceID"] === "string" ? input["deviceID"] : ""
      const device = await deps.store.getDevice(deviceID)
      if (device === undefined) {
        return context.error("unknown_device", `No paired device ${deviceID}.`)
      }
      await deps.store.removeDevice(deviceID)
      let relayRevoked = false
      try {
        await relay.revoke(device.grant)
        relayRevoked = true
      } catch {
        // Local removal always wins; the relay drops revoked/expired grants anyway.
        relayRevoked = false
      }
      return { deviceID, relayRevoked }
    },
  }
}
