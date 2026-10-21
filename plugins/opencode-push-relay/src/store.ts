// SPDX-License-Identifier: MPL-2.0

import type { ContentLevel, PushCategory } from "./classifier.ts"
import type { PushContent } from "./relay.ts"
import type { Creds, StoredKeyPair } from "./signing.ts"

/**
 * Typed access over `ctx.storage`.
 *
 * Storage is one server-global KV table namespaced by plugin id. Keys are
 * `registration`, `device/<id>`, `outbox/<id>`, `sent/<eventId>`, `lease`
 * and `stats`; when constructed with a config scope every key is prefixed
 * `<scope>:` so setups with different relay/app/tenant options never share
 * registration, devices, outbox, dedupe markers, stats or the delivery lease
 * (identical options share one scope on purpose — one binding per tenant).
 * Values are JSON.
 */
export interface Kv {
  get(key: string): Promise<unknown | undefined>
  set(key: string, value: any): Promise<void>
  remove(key: string): Promise<void>
  scan(options: { prefix: string; after?: string; limit?: number }): Promise<{
    entries: readonly { key: string; value: unknown }[]
    next?: string
  }>
}

/** Alias matching what `ctx.storage` structurally satisfies. */
export type StorageLike = Kv

export interface Registration extends Creds, StoredKeyPair {
  readonly tenant: string
  readonly app: string
  /** Epoch seconds. */
  readonly registeredAt: number
  readonly rotatedAt: number | undefined
  /** Bumped on every successful rotation. */
  readonly generation: number
}

export interface DevicePrefs {
  readonly sessions: "all" | readonly string[]
  readonly categories: readonly PushCategory[]
  readonly contentLevel: ContentLevel
}

export interface Device {
  readonly id: string
  readonly destinationToken: string
  readonly grant: string
  /** Epoch seconds. */
  readonly grantExpiresAt: number
  /** Epoch seconds: renew at or after this (renew by half-life). */
  readonly grantRenewAt: number
  readonly environment: string | null
  readonly prefs: DevicePrefs
  readonly needsEnroll: boolean
  /** Epoch milliseconds. */
  readonly createdAt: number
  readonly updatedAt: number
  readonly lastPushAt: number | undefined
  readonly lastResult: string | undefined
  readonly renewRetryAt: number | undefined
}

export interface OutboxItem {
  /** `${eventId}::${deviceID}` — unique per (transition, device). */
  readonly id: string
  readonly eventId: string
  readonly deviceID: string
  readonly ledgerKey: string
  readonly content: PushContent
  /** Epoch milliseconds. */
  readonly createdAt: number
  readonly nextAttemptAt: number
  readonly attempts: number
  readonly lastError: string | undefined
}

export interface Stats {
  enqueued: number
  accepted: number
  rejected: number
  retryable: number
  invalidDestination: number
  dropped: number
  renewals: number
  lastPushAt: number | undefined
  lastError: string | undefined
}

export interface Lease {
  readonly owner: string
  /** Epoch milliseconds. */
  readonly expiresAt: number
}

export function emptyStats(): Stats {
  return {
    enqueued: 0,
    accepted: 0,
    rejected: 0,
    retryable: 0,
    invalidDestination: 0,
    dropped: 0,
    renewals: 0,
    lastPushAt: undefined,
    lastError: undefined,
  }
}

/**
 * In-process serialisation per storage key. Instances in other processes are
 * still safe: every mutation below is keyed and idempotent (same event +
 * device writes the same outbox key), and APNs collapse ids absorb duplicate
 * sends — the lease only reduces redundant work, correctness does not rest
 * on it.
 */
const locks = new Map<string, Promise<unknown>>()

export async function withLock<T>(key: string, fn: () => Promise<T>): Promise<T> {
  const previous = locks.get(key) ?? Promise.resolve()
  const next = previous.catch(() => undefined).then(fn)
  locks.set(key, next)
  try {
    return await next
  } finally {
    if (locks.get(key) === next) locks.delete(key)
  }
}

const KEY_REGISTRATION = "registration"
const KEY_DEVICE = "device/"
const KEY_OUTBOX = "outbox/"
const KEY_SENT = "sent/"
const KEY_LEASE = "lease"
const KEY_STATS = "stats"

/** Generous ceilings; a single host pairing more than this is not a case we model. */
const SCAN_LIMIT = 1000

export class PushStore {
  private readonly kv: Kv
  /** Config-scope prefix (`"<hash>:"`, or "" when unscoped). */
  private readonly scope: string

  constructor(kv: Kv, scope = "") {
    this.kv = kv
    this.scope = scope === "" ? "" : `${scope}:`
  }

  /** Fully qualified storage key for one unscoped base key. */
  private key(base: string): string {
    return this.scope + base
  }

  private async read<T>(base: string): Promise<T | undefined> {
    const value = await this.kv.get(this.key(base))
    if (value === undefined || value === null) return undefined
    return value as T
  }

  private async write(base: string, value: unknown): Promise<void> {
    await this.kv.set(this.key(base), value)
  }

  /**
   * Drain every page of a prefix scan: `kv.scan` may cap a page below the
   * requested limit and returns a continuation cursor — following it keeps
   * records beyond the first page from disappearing from fan-out, delivery,
   * status and pruning.
   */
  private async scanAll(base: string): Promise<{ key: string; value: unknown }[]> {
    const prefix = this.key(base)
    const entries: { key: string; value: unknown }[] = []
    let after: string | undefined
    for (;;) {
      const page = await this.kv.scan(
        after === undefined ? { prefix, limit: SCAN_LIMIT } : { prefix, after, limit: SCAN_LIMIT },
      )
      entries.push(...page.entries)
      const next = page.next
      // Stop on no cursor, a non-advancing cursor, or an empty page.
      if (next === undefined || next === after || page.entries.length === 0) return entries
      after = next
    }
  }

  // -- registration ---------------------------------------------------------

  async getRegistration(): Promise<Registration | undefined> {
    return this.read<Registration>(KEY_REGISTRATION)
  }

  async saveRegistration(registration: Registration): Promise<void> {
    await this.write(KEY_REGISTRATION, registration)
  }

  // -- devices --------------------------------------------------------------

  async getDevice(id: string): Promise<Device | undefined> {
    return this.read<Device>(KEY_DEVICE + id)
  }

  async listDevices(): Promise<Device[]> {
    const entries = await this.scanAll(KEY_DEVICE)
    return entries.map((entry) => entry.value as Device)
  }

  /** Full replace, serialised against `patchDevice`/`removeDevice`. */
  async saveDevice(device: Device): Promise<void> {
    await withLock(this.key(`push-store:device:${device.id}`), async () => {
      await this.write(KEY_DEVICE + device.id, device)
    })
  }

  async removeDevice(id: string): Promise<void> {
    await withLock(this.key(`push-store:device:${id}`), async () => {
      await this.kv.remove(this.key(KEY_DEVICE + id))
    })
  }

  /**
   * Merge `patch` into the CURRENTLY stored device — never a snapshot taken
   * earlier, and never a resurrection: returns false when the device no
   * longer exists (a revoke won the race). Delivery and renewal bookkeeping
   * use this so a delayed engine save cannot clobber newer enrollment,
   * preferences or revocation.
   */
  async patchDevice(id: string, patch: Partial<Device>): Promise<boolean> {
    return withLock(this.key(`push-store:device:${id}`), async () => {
      const current = await this.read<Device>(KEY_DEVICE + id)
      if (current === undefined) return false
      await this.write(KEY_DEVICE + id, { ...current, ...patch })
      return true
    })
  }

  async markAllDevicesNeedsEnroll(now: number): Promise<number> {
    return withLock("push-store:devices", async () => {
      const devices = await this.listDevices()
      let changed = 0
      for (const device of devices) {
        if (device.needsEnroll) continue
        if (await this.patchDevice(device.id, { needsEnroll: true, updatedAt: now })) changed += 1
      }
      return changed
    })
  }

  // -- outbox ---------------------------------------------------------------

  /** Persist before transmission (notifications.md). False when duplicate. */
  async enqueueItem(item: OutboxItem): Promise<boolean> {
    return withLock(`push-store:outbox:${item.id}`, async () => {
      const existing = await this.read<OutboxItem>(KEY_OUTBOX + item.id)
      if (existing !== undefined) return false
      await this.write(KEY_OUTBOX + item.id, item)
      return true
    })
  }

  async listOutbox(): Promise<OutboxItem[]> {
    const entries = await this.scanAll(KEY_OUTBOX)
    return entries.map((entry) => entry.value as OutboxItem)
  }

  async updateOutbox(id: string, patch: Partial<OutboxItem>): Promise<void> {
    await withLock(`push-store:outbox:${id}`, async () => {
      const item = await this.read<OutboxItem>(KEY_OUTBOX + id)
      if (item === undefined) return
      await this.write(KEY_OUTBOX + id, { ...item, ...patch })
    })
  }

  async removeOutbox(id: string): Promise<void> {
    await withLock(`push-store:outbox:${id}`, async () => {
      await this.kv.remove(this.key(KEY_OUTBOX + id))
    })
  }

  // -- transition dedupe ------------------------------------------------------

  async isSent(eventId: string): Promise<boolean> {
    return (await this.read<number>(KEY_SENT + eventId)) !== undefined
  }

  async markSent(eventId: string, now: number): Promise<void> {
    await this.write(KEY_SENT + eventId, now)
  }

  async pruneSent(olderThan: number): Promise<number> {
    const entries = await this.scanAll(KEY_SENT)
    let removed = 0
    for (const entry of entries) {
      if (typeof entry.value === "number" && entry.value < olderThan) {
        await this.kv.remove(entry.key)
        removed += 1
      }
    }
    return removed
  }

  async pruneOutbox(olderThan: number): Promise<number> {
    const items = await this.listOutbox()
    let removed = 0
    for (const item of items) {
      if (item.createdAt < olderThan) {
        await this.removeOutbox(item.id)
        removed += 1
      }
    }
    return removed
  }

  // -- delivery lease ----------------------------------------------------------

  /** True when this owner holds the lease after the call. */
  async lease(owner: string, now: number, ttlMs: number): Promise<boolean> {
    return withLock(KEY_LEASE, async () => {
      const current = await this.read<Lease>(KEY_LEASE)
      if (current !== undefined && current.expiresAt > now && current.owner !== owner) {
        return false
      }
      await this.write(KEY_LEASE, { owner, expiresAt: now + ttlMs })
      return true
    })
  }

  async releaseLease(owner: string): Promise<void> {
    await withLock(KEY_LEASE, async () => {
      const current = await this.read<Lease>(KEY_LEASE)
      if (current?.owner === owner) await this.kv.remove(this.key(KEY_LEASE))
    })
  }

  async getLease(): Promise<Lease | undefined> {
    return this.read<Lease>(KEY_LEASE)
  }

  // -- stats ---------------------------------------------------------------------

  async getStats(): Promise<Stats> {
    return (await this.read<Stats>(KEY_STATS)) ?? emptyStats()
  }

  async updateStats(patch: Partial<Stats>): Promise<void> {
    await withLock(KEY_STATS, async () => {
      const current = (await this.read<Stats>(KEY_STATS)) ?? emptyStats()
      await this.write(KEY_STATS, { ...current, ...patch })
    })
  }
}
