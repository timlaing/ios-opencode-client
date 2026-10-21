// SPDX-License-Identifier: MPL-2.0

import { randomUUID } from "node:crypto"

import type { ContentLevel, PushDraft } from "./classifier.ts"
import type { PushConfig } from "./config.ts"
import {
  RelayError,
  type PushContent,
  type PushRequest,
  type PushResponse,
  type RelayApi,
} from "./relay.ts"
import { sha256hex } from "./signing.ts"
import type { Device, OutboxItem, PushStore } from "./store.ts"

/**
 * Durable delivery engine (notifications.md §"Plugin behavior"):
 * persist before transmit, one installation-level delivery lease, backoff on
 * transients, `invalidDestination` → re-enrollment, grant renewal by
 * half-life. Delivery never throws into OpenCode: failures are logged,
 * counted, and retried by the interval tick.
 */

export interface EngineHooks {
  /** A device can no longer receive pushes until it re-pairs. */
  onDeviceNeedsEnroll(deviceID: string): void
  /** The tenant binding vanished or no longer matches our signing key. */
  onRegistrationLost(code: string): void
  /** New work is waiting — schedule a tick soon. */
  kick(): void
  log(message: string): void
}

export interface TestResult {
  readonly deviceID: string
  readonly ok: boolean
  /** Machine outcome: relay result, `needsEnroll`, or an error code. */
  readonly result?: string
  readonly apnsId?: string | null
  /** Diagnostic text — server log only, never rendered into prompt reports. */
  readonly detail?: string
  readonly ms: number
}

/** Stable identity per canonical transition: APNs collapse id + local dedupe. */
export function eventIdFor(ledgerKey: string): string {
  return sha256hex(ledgerKey).slice(0, 48)
}

/** Exponential backoff, 15s base, 5 minutes cap. */
export function backoffMs(attempts: number): number {
  return Math.min(300_000, 15_000 * 2 ** Math.max(0, attempts - 1))
}

const LEASE_MS = 30_000
const MAX_PER_TICK = 20
const MAX_ATTEMPTS = 12
const RETRY_WINDOW_MS = 6 * 60 * 60 * 1000
const SENT_RETENTION_MS = 24 * 60 * 60 * 1000
const RENEW_RETRY_MS = 60_000

// Relay codes meaning "this stored grant can never deliver again as-is":
// policy failures surface as their own 403 code, while malformed grants and
// bad signatures collapse to 400 `invalid_grant` (_map_grant_error). All of
// them send the device back to re-enrollment instead of dying silently.
const GRANT_PROBLEMS = [
  "grant_expired",
  "grant_revoked",
  "grant_mismatch",
  "tenant_mismatch",
  "app_mismatch",
  "destination_mismatch",
  "kind_not_allowed",
  "invalid_grant",
]
const BINDING_PROBLEMS = ["unknown_tenant", "invalid_signature", "enrollment_required"]

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

export class DeliveryEngine {
  readonly instanceID: string
  private readonly config: PushConfig
  private readonly store: PushStore
  private readonly relay: RelayApi
  private readonly hooks: EngineHooks
  private readonly now: () => number

  constructor(
    config: PushConfig,
    store: PushStore,
    relay: RelayApi,
    hooks: EngineHooks,
    now?: () => number,
  ) {
    this.instanceID = randomUUID()
    this.config = config
    this.store = store
    this.relay = relay
    this.hooks = hooks
    this.now = now ?? Date.now
  }

  /** Persist the fan-out for one canonical transition. Returns queued count. */
  async enqueue(draft: PushDraft): Promise<number> {
    const eventId = eventIdFor(draft.ledgerKey)
    if (await this.store.isSent(eventId)) return 0
    const now = this.now()
    let queued = 0
    for (const device of await this.store.listDevices()) {
      if (!this.matches(device, draft)) continue
      const item: OutboxItem = {
        id: `${eventId}::${device.id}`,
        eventId,
        deviceID: device.id,
        ledgerKey: draft.ledgerKey,
        // Content is per device: each alert body honours that device's own
        // contentLevel (minimal copy vs server-provided failure summary).
        content: this.buildContent(draft, device.prefs.contentLevel),
        createdAt: now,
        nextAttemptAt: now,
        attempts: 0,
        lastError: undefined,
      }
      if (await this.store.enqueueItem(item)) queued += 1
    }
    if (queued > 0) {
      const stats = await this.store.getStats()
      await this.store.updateStats({ enqueued: stats.enqueued + queued })
      this.hooks.kick()
    }
    return queued
  }

  private matches(device: Device, draft: PushDraft): boolean {
    if (device.needsEnroll) return false
    if (!device.prefs.categories.includes(draft.category)) return false
    if (device.prefs.sessions === "all") return true
    return device.prefs.sessions.includes(draft.sessionID)
  }

  private buildContent(draft: PushDraft, level: ContentLevel): PushContent {
    const body =
      level === "summaries" && draft.failureSummary !== null ? draft.failureSummary : draft.body
    // Standard base64 alphabet: the relay validates sealed with
    // b64decode(validate=True). Decoded size must stay ≤1024 bytes.
    const sealed = Buffer.from(
      JSON.stringify({
        v: 1,
        host: this.config.tenant,
        category: draft.category,
        sessionID: draft.sessionID,
        ownerID: draft.ownerID,
        transitionID: draft.transitionID,
        ledgerKey: draft.ledgerKey,
      }),
      "utf8",
    ).toString("base64")
    return { alert: { title: draft.title, body, category: draft.category }, sealed }
  }

  /** One lease-governed pass: drain, prune, renew. Never throws. */
  async tick(): Promise<void> {
    try {
      const now = this.now()
      const owner = await this.store.lease(this.instanceID, now, LEASE_MS)
      if (!owner) return
      await this.drain(now)
      await this.renewDueGrants(now)
      await this.prune(now)
    } catch (error) {
      this.hooks.log(`tick failed: ${messageOf(error)}`)
    }
  }

  private async drain(now: number): Promise<void> {
    const due = (await this.store.listOutbox())
      .filter((item) => item.nextAttemptAt <= now)
      .sort((a, b) => a.createdAt - b.createdAt)
      .slice(0, MAX_PER_TICK)
    for (const item of due) {
      const device = await this.store.getDevice(item.deviceID)
      if (device === undefined || device.needsEnroll) {
        await this.store.removeOutbox(item.id)
        const stats = await this.store.getStats()
        await this.store.updateStats({ dropped: stats.dropped + 1, lastError: "device unavailable" })
        continue
      }
      const request: PushRequest = {
        grant: device.grant,
        destinationToken: device.destinationToken,
        kind: "alert",
        eventId: item.eventId,
        expiresAt: Math.floor(this.now() / 1000) + this.config.pushTtlSeconds,
        content: item.content,
      }
      try {
        const response = await this.relay.push(request)
        await this.handleResult(item, device, response)
      } catch (error) {
        if (error instanceof RelayError) await this.handleRelayError(item, device, error)
        else await this.retryOrDrop(item, this.now(), messageOf(error))
      }
    }
  }

  private async handleResult(
    item: OutboxItem,
    device: Device,
    response: PushResponse,
  ): Promise<void> {
    const now = this.now()
    const stats = await this.store.getStats()
    switch (response.result) {
      case "accepted": {
        await this.store.removeOutbox(item.id)
        await this.store.markSent(item.eventId, now)
        await this.store.patchDevice(device.id, {
          lastPushAt: now,
          lastResult: "accepted",
          updatedAt: now,
        })
        await this.store.updateStats({ accepted: stats.accepted + 1, lastPushAt: now, lastError: undefined })
        return
      }
      case "invalidDestination": {
        // notifications.md: the plugin removes or replaces the token — the
        // app re-pairs with a fresh destination token.
        await this.store.removeOutbox(item.id)
        await this.markNeedsEnroll(device, "invalidDestination")
        await this.store.updateStats({ invalidDestination: stats.invalidDestination + 1, lastError: "invalidDestination" })
        return
      }
      case "retryable": {
        // stats/outbox keep the machine code; the relay's free-text detail
        // goes to the server log only (prompt reports must not carry it).
        if (response.detail !== undefined && response.detail !== null && response.detail !== "") {
          this.hooks.log(`relay retryable for ${device.id}: ${response.detail}`)
        }
        await this.store.updateStats({ retryable: stats.retryable + 1, lastError: "retryable" })
        await this.retryOrDrop(item, now, "retryable")
        return
      }
      case "rejected": {
        // No automatic retry until corrected; the transition stays deduped.
        if (response.detail !== undefined && response.detail !== null && response.detail !== "") {
          this.hooks.log(`relay rejected for ${device.id}: ${response.detail}`)
        }
        await this.store.removeOutbox(item.id)
        await this.store.markSent(item.eventId, now)
        await this.store.patchDevice(device.id, { lastResult: "rejected", updatedAt: now })
        await this.store.updateStats({ rejected: stats.rejected + 1, lastError: "rejected" })
        return
      }
      default: {
        // A 2xx whose result we do not recognise: never leave the item
        // immediately due forever — route it through retry/backoff like a
        // transient, and record the attempt (malformed-success finding).
        await this.store.updateStats({ retryable: stats.retryable + 1, lastError: "unexpected_result" })
        await this.retryOrDrop(item, now, "unexpected_result")
        return
      }
    }
  }

  private async handleRelayError(
    item: OutboxItem,
    device: Device,
    error: RelayError,
  ): Promise<void> {
    const now = this.now()
    const stats = await this.store.getStats()
    if (error.status === 0) {
      const retryStats = await this.store.getStats()
      await this.store.updateStats({ retryable: retryStats.retryable + 1, lastError: error.code })
      await this.retryOrDrop(item, now, `${error.code}`)
      return
    }
    if (GRANT_PROBLEMS.includes(error.code)) {
      // The grant no longer verifies against the current binding.
      await this.store.removeOutbox(item.id)
      await this.markNeedsEnroll(device, error.code)
      await this.store.updateStats({ dropped: stats.dropped + 1, lastError: error.code })
      return
    }
    if (BINDING_PROBLEMS.includes(error.code)) {
      await this.store.removeOutbox(item.id)
      await this.store.updateStats({ dropped: stats.dropped + 1, lastError: `${error.status} ${error.code}` })
      this.hooks.onRegistrationLost(error.code)
      return
    }
    if (error.status === 429) {
      await this.store.updateStats({ retryable: stats.retryable + 1, lastError: error.code })
      await this.retryOrDrop(item, now, error.code)
      return
    }
    if (error.status >= 400 && error.status < 500) {
      await this.store.removeOutbox(item.id)
      await this.store.markSent(item.eventId, now)
      await this.store.updateStats({ rejected: stats.rejected + 1, lastError: `${error.status} ${error.code}` })
      return
    }
    await this.store.updateStats({ retryable: stats.retryable + 1, lastError: `${error.status} ${error.code}` })
    await this.retryOrDrop(item, now, `${error.status} ${error.code}`)
  }

  private async retryOrDrop(item: OutboxItem, now: number, error: string): Promise<void> {
    const attempts = item.attempts + 1
    if (attempts >= MAX_ATTEMPTS || now - item.createdAt > RETRY_WINDOW_MS) {
      await this.store.removeOutbox(item.id)
      const stats = await this.store.getStats()
      await this.store.updateStats({ dropped: stats.dropped + 1, lastError: error })
      return
    }
    await this.store.updateOutbox(item.id, {
      attempts,
      nextAttemptAt: now + backoffMs(attempts),
      lastError: error,
    })
  }

  private async markNeedsEnroll(device: Device, reason: string): Promise<void> {
    // Patch (never snapshot-write): a device removed meanwhile is not
    // resurrected, and concurrent enrollment/prefs writes are preserved.
    const updated = await this.store.patchDevice(device.id, {
      needsEnroll: true,
      lastResult: reason,
      updatedAt: this.now(),
    })
    if (updated) this.hooks.onDeviceNeedsEnroll(device.id)
  }

  /** Renew grants at half-life (spec §2.4 keeps every other claim unchanged). */
  private async renewDueGrants(now: number): Promise<void> {
    const nowSeconds = Math.floor(now / 1000)
    for (const device of await this.store.listDevices()) {
      if (device.needsEnroll) continue
      if (device.grantRenewAt > nowSeconds) continue
      if ((device.renewRetryAt ?? 0) > now) continue
      try {
        const renewed = await this.relay.renew(device.grant, this.config.grantTtlSeconds)
        const renewAt = nowSeconds + Math.max(60, Math.floor((renewed.expiresAt - nowSeconds) / 2))
        await this.store.patchDevice(device.id, {
          grant: renewed.grant,
          grantExpiresAt: renewed.expiresAt,
          grantRenewAt: renewAt,
          renewRetryAt: undefined,
          updatedAt: now,
        })
        const stats = await this.store.getStats()
        await this.store.updateStats({ renewals: stats.renewals + 1 })
      } catch (error) {
        if (error instanceof RelayError && GRANT_PROBLEMS.includes(error.code)) {
          await this.markNeedsEnroll(device, error.code)
          continue
        }
        if (error instanceof RelayError && BINDING_PROBLEMS.includes(error.code)) {
          this.hooks.onRegistrationLost(error.code)
          continue
        }
        await this.store.patchDevice(device.id, {
          renewRetryAt: now + RENEW_RETRY_MS,
          updatedAt: now,
        })
        this.hooks.log(`grant renewal for ${device.id} failed: ${messageOf(error)}`)
      }
    }
  }

  private async prune(now: number): Promise<void> {
    await this.store.pruneSent(now - SENT_RETENTION_MS)
    const stale = await this.store.pruneOutbox(now - RETRY_WINDOW_MS)
    if (stale > 0) this.hooks.log(`dropped ${stale} stale outbox item(s) past the retry window`)
  }

  /**
   * Explicit test alert to paired devices, bypassing subscription filters
   * (an operator asked for it). One collapse id per attempt.
   */
  async sendTest(deviceIDs?: readonly string[]): Promise<TestResult[]> {
    const now = this.now()
    const eventId = `test-${Math.floor(now / 1000)}`
    const sealed = Buffer.from(
      JSON.stringify({ v: 1, host: this.config.tenant, test: true }),
      "utf8",
    ).toString("base64")
    const results: TestResult[] = []
    for (const device of await this.store.listDevices()) {
      if (deviceIDs !== undefined && !deviceIDs.includes(device.id)) continue
      if (device.needsEnroll) {
        results.push({ deviceID: device.id, ok: false, result: "needsEnroll", ms: 0 })
        continue
      }
      const started = Date.now()
      try {
        const response = await this.relay.push({
          grant: device.grant,
          destinationToken: device.destinationToken,
          kind: "alert",
          eventId,
          expiresAt: Math.floor(now / 1000) + Math.min(this.config.pushTtlSeconds, 120),
          content: {
            alert: {
              title: "Push test",
              body: `Test push from ${this.config.tenant}`,
              category: "pushTest",
            },
            sealed,
          },
        })
        results.push({
          deviceID: device.id,
          ok: response.result === "accepted",
          result: response.result,
          apnsId: response.apnsId ?? null,
          detail: response.detail ?? undefined,
          ms: Date.now() - started,
        })
      } catch (error) {
        results.push({
          deviceID: device.id,
          ok: false,
          result: error instanceof RelayError ? error.code : "failed",
          detail: messageOf(error),
          ms: Date.now() - started,
        })
      }
    }
    return results
  }
}
