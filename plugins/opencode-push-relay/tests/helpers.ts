// SPDX-License-Identifier: MPL-2.0

/**
 * Shared fixtures for the plugin test-suite: in-memory KV, deterministic
 * clocks, and a fake relay. Not a test file itself (`node --test` ignores
 * non-`*.test.ts` names).
 */

import { ALL_CATEGORIES, type PushDraft } from "../src/classifier.ts"
import type { PushConfig } from "../src/config.ts"
import type {
  BindingProbe,
  PushRequest,
  PushResponse,
  RelayApi,
  RelayedGrant,
  RotateResponse,
} from "../src/relay.ts"
import { RelayError } from "../src/relay.ts"
import { sha256hex } from "../src/signing.ts"
import type { Device, Kv, PushStore, Registration } from "../src/store.ts"
import { PushStore as Store } from "../src/store.ts"

export class MemoryKv implements Kv {
  private readonly map = new Map<string, unknown>()

  async get(key: string): Promise<unknown | undefined> {
    return this.map.get(key)
  }

  async set(key: string, value: any): Promise<void> {
    // Clone like real JSON storage would: catches shared-reference bugs.
    this.map.set(key, structuredClone(value))
  }

  async remove(key: string): Promise<void> {
    this.map.delete(key)
  }

  async scan(options: {
    prefix: string
    after?: string
    limit?: number
  }): Promise<{ entries: readonly { key: string; value: unknown }[]; next?: string }> {
    const keys = [...this.map.keys()].filter((key) => key.startsWith(options.prefix)).sort()
    const ranged =
      options.after === undefined ? keys : keys.filter((key) => key > (options.after as string))
    const limited = options.limit === undefined ? ranged : ranged.slice(0, options.limit)
    return { entries: limited.map((key) => ({ key, value: this.map.get(key) })) }
  }
}

export function makeStore(): PushStore {
  return new Store(new MemoryKv())
}

export function makeConfig(overrides: Partial<PushConfig> = {}): PushConfig {
  return {
    relayUrl: "https://relay.test",
    app: "opencode",
    tenant: "host-a",
    autoRegister: true,
    categories: [...ALL_CATEGORIES],
    contentLevel: "minimal",
    defaultSessions: "all",
    pushTtlSeconds: 3600,
    grantTtlSeconds: undefined,
    ...overrides,
  }
}

export function makeDraft(overrides: Partial<PushDraft> = {}): PushDraft {
  const sessionID = overrides.sessionID ?? "ses_1"
  const transitionID = overrides.transitionID ?? "evt_1"
  return {
    category: "sessionCompleted",
    sessionID,
    ownerID: null,
    transitionID,
    ledgerKey: `host:host-a|session:${sessionID}|owner:-|transition:${transitionID}`,
    title: "Session completed",
    body: "The session finished successfully.",
    ...overrides,
  }
}

export function makeDevice(id: string, overrides: Partial<Device> = {}): Device {
  const now = 1_760_000_000_000
  const nowSeconds = Math.floor(now / 1000)
  return {
    id,
    destinationToken: "ab".repeat(16),
    grant: `v1.${id}-grant.fixture-sig`,
    grantExpiresAt: nowSeconds + 86_400,
    grantRenewAt: nowSeconds + 43_200,
    environment: "sandbox",
    prefs: { sessions: "all", categories: [...ALL_CATEGORIES], contentLevel: "minimal" },
    needsEnroll: false,
    createdAt: now,
    updatedAt: now,
    lastPushAt: undefined,
    lastResult: undefined,
    renewRetryAt: undefined,
    ...overrides,
  }
}

export function makeRegistration(overrides: Partial<Registration> = {}): Registration {
  return {
    tenant: "host-a",
    app: "opencode",
    token: "tnt_fixture-token-0001",
    privateKeyB64: "",
    publicB64: "FIXTURE_PUBKEY_BASE64URL",
    registeredAt: 1_760_000_000,
    rotatedAt: undefined,
    generation: 1,
    ...overrides,
  }
}

/** Build a syntactically valid `v1.<claims>.<sig>` grant from raw claims. */
export function makeGrant(claims: Record<string, unknown>): string {
  const payload = Buffer.from(JSON.stringify(claims)).toString("base64url")
  return `v1.${payload}.fixture-signature`
}

/** Claims matching `makeRegistration()` + `makeDevice()` token defaults. */
export function makeClaims(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  // Relative to real wall-clock time: validateEnrollment checks exp against it.
  const now = Math.floor(Date.now() / 1000)
  return {
    jti: "jti_fixture",
    ten: "host-a",
    tpk: "FIXTURE_PUBKEY_BASE64URL",
    app: "opencode",
    kinds: ["alert"],
    env: "sandbox",
    tok: `sha256:${sha256hex("ab".repeat(16))}`,
    iat: now - 60,
    exp: now + 86_400,
    ttl: 86_400,
    ...overrides,
  }
}

export class FakeRelay implements RelayApi {
  readonly pushes: PushRequest[] = []
  readonly renewCalls: Array<{ grant: string; ttl: number | undefined }> = []
  readonly revoked: string[] = []
  pushQueue: Array<PushResponse | Error> = []
  renewResponse: RelayedGrant | undefined
  renewError: Error | undefined

  async push(request: PushRequest): Promise<PushResponse> {
    this.pushes.push(request)
    const next = this.pushQueue.shift()
    if (next instanceof Error) throw next
    if (next !== undefined) return next
    return { result: "accepted", apnsId: `apns-${this.pushes.length}` }
  }

  async renew(grant: string, ttl?: number): Promise<RelayedGrant> {
    this.renewCalls.push({ grant, ttl })
    if (this.renewError) throw this.renewError
    return (
      this.renewResponse ?? {
        grant: `${grant}.renewed`,
        expiresAt: Math.floor(Date.now() / 1000) + 86_400,
      }
    )
  }

  async revoke(grant: string): Promise<{ revoked: string }> {
    this.revoked.push(grant)
    return { revoked: "fixture" }
  }
}

/** Adds the RelayClient-only surface (health/probe/rotate) for status + commands. */
export class FakeRelayClient extends FakeRelay {
  probe: BindingProbe = { state: "bound" }
  healthError: Error | undefined
  rotateQueue: Array<RotateResponse | Error> = []
  readonly rotatedPubkeys: string[] = []

  async health(): Promise<{ status: string }> {
    if (this.healthError) throw this.healthError
    return { status: "ok" }
  }

  async probeBinding(): Promise<BindingProbe> {
    return this.probe
  }

  async rotate(newPubkey: string): Promise<RotateResponse> {
    this.rotatedPubkeys.push(newPubkey)
    const next = this.rotateQueue.shift()
    if (next instanceof Error) throw next
    return (
      next ?? { tenant: "host-a", app: "opencode", token: "tnt_rotated-token", rotated_at: 1_760_000_600 }
    )
  }
}

export { RelayError }
