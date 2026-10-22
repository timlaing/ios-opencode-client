// SPDX-License-Identifier: MPL-2.0

import type { PushConfig } from "./config.ts"
import { describeError, type BindingProbe, type RelayClient } from "./relay.ts"
import { sha256hex } from "./signing.ts"
import { emptyStats, type PushStore, type Stats } from "./store.ts"

/**
 * One structured view of plugin state, consumed by `/push-status` (formatted)
 * and the `status` RPC method (serialized). Nothing here touches credentials
 * beyond fingerprints.
 */

export interface DeviceStatus {
  readonly id: string
  readonly needsEnroll: boolean
  readonly lastResult: string | undefined
  readonly lastPushAt: number | undefined
  readonly grantExpiresAt: number
  readonly grantRenewAt: number
  readonly environment: string | null
  readonly sessions: "all" | readonly string[]
  readonly categories: readonly string[]
}

export interface StatusReport {
  readonly configured: boolean
  readonly missing: readonly string[]
  readonly problems: readonly string[]
  readonly config:
    | {
        relayUrl: string
        app: string
        tenant: string
        autoRegister: boolean
        contentLevel: string
        defaultSessions: string
      }
    | undefined
  readonly registration:
    | {
        tenant: string
        app: string
        registeredAt: number
        rotatedAt: number | undefined
        generation: number
        tokenFingerprint: string
        publicFingerprint: string
      }
    | undefined
  readonly probe: BindingProbe | undefined
  readonly health: { ok: boolean; latencyMs?: number; error?: string } | undefined
  readonly devices: readonly DeviceStatus[]
  readonly outboxDepth: number
  readonly stats: Stats
  readonly leaseHeldByCaller: boolean
  /** A live lease held by some other instance (not the caller). */
  readonly leaseHeldElsewhere: boolean
  readonly notes: readonly string[]
}

export interface StatusDeps {
  readonly config: PushConfig | undefined
  readonly missing: readonly string[]
  readonly problems: readonly string[]
  readonly store: PushStore
  readonly relay: RelayClient | undefined
  readonly ensureOutcome: string | undefined
  /** True when the calling instance currently holds the delivery lease. */
  readonly instanceHoldsLease?: boolean
}

export async function buildStatus(deps: StatusDeps): Promise<StatusReport> {
  const notes: string[] = []
  const registration = await deps.store.getRegistration()
  const devices = await deps.store.listDevices()
  const outbox = await deps.store.listOutbox()
  const stats = await deps.store.getStats()
  const lease = await deps.store.getLease()
  const leaseLive = lease !== undefined && lease.expiresAt > Date.now()

  if (deps.config === undefined || deps.relay === undefined) {
    const issues = [...deps.missing.map((entry) => `missing ${entry}`), ...deps.problems]
    return {
      configured: false,
      missing: deps.missing,
      problems: deps.problems,
      config: undefined,
      registration: undefined,
      probe: undefined,
      health: undefined,
      devices: [],
      outboxDepth: 0,
      stats: emptyStats(),
      leaseHeldByCaller: false,
      leaseHeldElsewhere: false,
      notes: [
        issues.length > 0 ? issues.join("; ") : "no relay configuration",
        "set plugins[].options.relayUrl and .app in opencode.json(c), then reload the project",
      ],
    }
  }

  const config = deps.config
  const relay = deps.relay

  let health: StatusReport["health"]
  try {
    const started = Date.now()
    const response = await relay.health()
    health = { ok: response.status === "ok", latencyMs: Date.now() - started }
    if (response.status !== "ok") health = { ok: false, error: `relay status: ${response.status}` }
  } catch (error) {
    health = { ok: false, error: describeError(error) }
  }

  let probe: BindingProbe | undefined
  if (registration !== undefined) {
    try {
      probe = await relay.probeBinding()
    } catch (error) {
      notes.push(`binding probe failed: ${describeError(error)}`)
    }
    if (probe?.state === "no-binding") {
      notes.push(
        config.autoRegister
          ? "relay binding gone (idle-expired or revoked) — re-registering automatically; paired devices re-enroll"
          : "relay binding gone (idle-expired or revoked) and autoRegister is off",
      )
    } else if (probe?.state === "rejected") {
      notes.push(
        `stored signing key does not match the relay's (${probe.code}) — the relay operator must run \`relay tenant revoke ${config.tenant}\`, then restart OpenCode to re-register`,
      )
    } else if (probe?.state === "unbound") {
      notes.push("registered but no device has enrolled yet — pair the iOS app to activate pushes")
    }
  } else {
    if (deps.ensureOutcome !== undefined) notes.push(deps.ensureOutcome)
    notes.push(
      "no credentials in plugin storage — pairing starts from the iOS app, which fetches this host's tenant id and pubkey via the push RPC",
    )
  }

  const needsEnroll = devices.filter((device) => device.needsEnroll)
  if (needsEnroll.length > 0) {
    notes.push(`${needsEnroll.length} device(s) need re-enrollment — open the iOS app to re-pair`)
  }
  if (registration !== undefined && probe?.state === "bound" && needsEnroll.length === 0 && devices.length === 0) {
    notes.push("bound, but no devices are paired yet — open the iOS app to enroll")
  }

  return {
    configured: true,
    missing: [],
    problems: [],
    config: {
      relayUrl: config.relayUrl,
      app: config.app,
      tenant: config.tenant,
      autoRegister: config.autoRegister,
      contentLevel: config.contentLevel,
      defaultSessions: config.defaultSessions,
    },
    registration:
      registration === undefined
        ? undefined
        : {
            tenant: registration.tenant,
            app: registration.app,
            registeredAt: registration.registeredAt,
            rotatedAt: registration.rotatedAt,
            generation: registration.generation,
            tokenFingerprint: sha256hex(registration.token).slice(0, 12),
            publicFingerprint: registration.publicB64.slice(0, 12),
          },
    probe,
    health,
    devices: devices.map((device) => ({
      id: device.id,
      needsEnroll: device.needsEnroll,
      lastResult: device.lastResult,
      lastPushAt: device.lastPushAt,
      grantExpiresAt: device.grantExpiresAt,
      grantRenewAt: device.grantRenewAt,
      environment: device.environment,
      sessions: device.prefs.sessions,
      categories: device.prefs.categories,
    })),
    outboxDepth: outbox.length,
    stats,
    // Only a LIVE lease counts: an expired record means the lease is free,
    // not "held elsewhere" — an operator chasing a stall must not be sent
    // after a phantom holder.
    leaseHeldByCaller: leaseLive && deps.instanceHoldsLease === true,
    leaseHeldElsewhere: leaseLive && deps.instanceHoldsLease !== true,
    notes,
  }
}

function inWords(fromSeconds: number, now: number): string {
  const delta = fromSeconds - Math.floor(now / 1000)
  const absolute = Math.abs(delta)
  const unit =
    absolute < 3600
      ? `${Math.max(1, Math.round(absolute / 60))}m`
      : absolute < 86_400
        ? `${(absolute / 3600).toFixed(1)}h`
        : `${(absolute / 86_400).toFixed(1)}d`
  return delta >= 0 ? `in ${unit}` : `${unit} ago`
}

function atWords(epochMs: number | undefined, now: number): string {
  if (epochMs === undefined) return "never"
  return `${Math.max(0, Math.round((now - epochMs) / 1000))}s ago`
}

function isoOrDash(epochSeconds: number | undefined): string {
  if (epochSeconds === undefined) return "-"
  return new Date(epochSeconds * 1000).toISOString().replace(".000Z", "Z")
}

export function formatStatus(report: StatusReport, now: number = Date.now()): string {
  const lines: string[] = ["Push relay status"]

  if (!report.configured) {
    lines.push("  state         inactive — the plugin is loaded but not configured")
    for (const note of report.notes) lines.push(`  note          ${note}`)
    return lines.join("\n")
  }

  const config = report.config
  if (config !== undefined) {
    lines.push(
      `  config        ${config.relayUrl}  app=${config.app}  tenant=${config.tenant}  autoRegister=${config.autoRegister ? "on" : "off"}`,
    )
  }

  const registration = report.registration
  if (registration === undefined) {
    lines.push("  registration  none")
  } else {
    const rotated = registration.rotatedAt === undefined ? "" : ` · rotated ${isoOrDash(registration.rotatedAt)}`
    lines.push(
      `  registration  tenant ${registration.tenant} (app ${registration.app}) · gen ${registration.generation} · token ${registration.tokenFingerprint}… · key ed25519:${registration.publicFingerprint}… · since ${isoOrDash(registration.registeredAt)}${rotated}`,
    )
  }

  lines.push(
    `  relay health  ${report.health?.ok ? `ok (${report.health.latencyMs ?? "?"} ms)` : `unreachable — ${report.health?.error ?? "unknown"}`}`,
  )
  lines.push(
    `  binding       ${report.probe === undefined ? "unknown" : report.probe.state === "rejected" ? `rejected (${report.probe.code})` : report.probe.state}`,
  )

  if (report.devices.length === 0) {
    lines.push("  devices       none paired")
  } else {
    lines.push(`  devices       ${report.devices.length} paired`)
    for (const device of report.devices) {
      const sessions = device.sessions === "all" ? "all" : device.sessions.length > 0 ? device.sessions.join(",") : "none"
      const categories = device.categories.length > 0 ? device.categories.join(",") : "none"
      const grant = device.needsEnroll
        ? `RE-ENROLL (${device.lastResult ?? "grant unusable"})`
        : `ok · grant expires ${inWords(device.grantExpiresAt, now)} (renews ${inWords(device.grantRenewAt, now)}) · last ${atWords(device.lastPushAt, now)}${device.lastResult ? ` (${device.lastResult})` : ""}`
      lines.push(`    ${device.id.padEnd(10)} ${grant} · sessions: ${sessions} · categories: ${categories}`)
    }
  }

  lines.push(`  outbox        ${report.outboxDepth} pending`)
  lines.push(
    `  stats         enqueued ${report.stats.enqueued} · accepted ${report.stats.accepted} · rejected ${report.stats.rejected} · retryable ${report.stats.retryable} · invalidDestination ${report.stats.invalidDestination} · dropped ${report.stats.dropped} · renewals ${report.stats.renewals}`,
  )
  lines.push(
    `  lease         ${
      report.leaseHeldByCaller
        ? "held by this instance"
        : report.leaseHeldElsewhere
          ? "held elsewhere (another project location is draining)"
          : "free"
    }`,
  )
  for (const note of report.notes) lines.push(`  note          ${note}`)

  return lines.join("\n")
}

/** Serialize a report for the `status` RPC output schema. */
export function statusToRpc(report: StatusReport): Record<string, unknown> {
  return {
    configured: report.configured,
    missing: [...report.missing],
    problems: [...report.problems],
    relayUrl: report.config?.relayUrl ?? null,
    app: report.config?.app ?? null,
    tenant: report.config?.tenant ?? null,
    registered: report.registration !== undefined,
    // Renamed from `tenantPubkey`: `info.tenantPubkey` is the FULL key, while
    // this status payload only ever carries the short fingerprint — one
    // meaning per field name (CodeRabbit finding).
    tenantPubkeyFingerprint:
      report.registration === undefined ? null : report.registration.publicFingerprint,
    probe:
      report.probe === undefined
        ? null
        : report.probe.state === "rejected"
          ? `rejected:${report.probe.code}`
          : report.probe.state,
    health:
      report.health === undefined
        ? null
        : report.health.ok
          ? { ok: true, latencyMs: report.health.latencyMs ?? 0 }
          : { ok: false, error: report.health.error ?? "unreachable" },
    devices: report.devices.map((device) => ({
      id: device.id,
      needsEnroll: device.needsEnroll,
      grantExpiresAt: device.grantExpiresAt,
      environment: device.environment,
      lastResult: device.lastResult ?? null,
      sessions: device.sessions === "all" ? "all" : [...device.sessions],
      categories: [...device.categories],
    })),
    outboxDepth: report.outboxDepth,
    stats: {
      enqueued: report.stats.enqueued,
      accepted: report.stats.accepted,
      rejected: report.stats.rejected,
      retryable: report.stats.retryable,
      invalidDestination: report.stats.invalidDestination,
      dropped: report.stats.dropped,
      renewals: report.stats.renewals,
    },
    notes: [...report.notes],
  }
}
