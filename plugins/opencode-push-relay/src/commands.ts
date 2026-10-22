// SPDX-License-Identifier: MPL-2.0

import type { PushConfig } from "./config.ts"
import type { DeliveryEngine } from "./engine.ts"
import { describeError, RelayError, type RelayClient } from "./relay.ts"
import { formatStatus, type StatusReport } from "./status.ts"
import { generateKeyPair, sha256hex } from "./signing.ts"
import type { PushStore, Registration } from "./store.ts"

/**
 * The three slash commands: `/push-status`, `/push-key-rotate`, `/push-test`.
 *
 * Each command computes a report and submits it back through the session
 * (via `io.submit`, wired to `ctx.session.prompt` in index.ts) — no TUI
 * output, no blocking prompts. The local shapes below keep this module
 * independent of OpenCode's plugin types so tests can drive it directly.
 */

export interface CommandIo {
  submit(sessionID: string, delivery: unknown, report: string): Promise<void>
}

export interface CommandInvocationLike {
  readonly sessionID: string
  readonly prompt: unknown
  readonly delivery: unknown
}

export interface CommandDefinitionLike {
  readonly name: string
  readonly description: string
  execute(input: CommandInvocationLike): Promise<void>
}

export interface CommandDeps {
  config(): PushConfig | undefined
  readonly store: PushStore
  engine(): DeliveryEngine | undefined
  relay(): RelayClient | undefined
  ensureRegistration(): Promise<Registration | undefined>
  /** Adopt a rotated registration into the live credentials cache. */
  adoptRegistration(registration: Registration): void
  buildStatusReport(): Promise<StatusReport>
  emitConfig(reason: "registered" | "rotated" | "rebound"): void
  readonly io: CommandIo
  log(message: string): void
}

/**
 * Reports from these commands are submitted as session prompt text (see
 * index.ts `io.submit`), so relay-controlled strings must never appear in
 * them: machine codes only (`describeError`), and free-text details are
 * routed to `deps.log` (the server log — a non-LLM path).
 */

function pushStatusCommand(deps: CommandDeps): CommandDefinitionLike {
  return {
    name: "push-status",
    description: "Show apns-push-relay registration, binding, devices, and delivery stats",
    execute: async (input) => {
      let text: string
      try {
        text = formatStatus(await deps.buildStatusReport())
      } catch (error) {
        text = `push-status failed: ${describeError(error)}`
      }
      await deps.io.submit(input.sessionID, input.delivery, text)
    },
  }
}

function pushKeyRotateCommand(deps: CommandDeps): CommandDefinitionLike {
  return {
    name: "push-key-rotate",
    description: "Rotate this host's relay token and Ed25519 signing key (devices re-pair)",
    execute: async (input) => {
      let text: string
      try {
        const config = deps.config()
        const relay = deps.relay()
        if (config === undefined || relay === undefined) {
          text = `Cannot rotate: the plugin is not configured.\n${formatStatus(await deps.buildStatusReport())}`
        } else {
          const registration = await deps.ensureRegistration()
          if (registration === undefined) {
            text =
              "No registration to rotate. Fix the /push-status issues first — this host registers with the relay automatically at startup when autoRegister is on."
          } else {
            text = await rotate(registration, config, relay, deps)
          }
        }
      } catch (error) {
        if (error instanceof RelayError && error.status === 404) {
          text =
            "The relay does not expose POST /v1/rotate — it predates credential rotation (enrollment spec v1.2). Update the relay, then retry."
        } else if (error instanceof RelayError && error.code === "invalid_signature") {
          text =
            "The relay rejected the rotation signature: the stored key no longer matches this host's key. The relay operator must run `relay tenant revoke <tenant-id>` on the relay host, then restart OpenCode to re-register."
        } else {
          text = `Rotation failed: ${describeError(error)}`
        }
      }
      await deps.io.submit(input.sessionID, input.delivery, text)
    },
  }
}

async function rotate(
  registration: Registration,
  config: PushConfig,
  relay: RelayClient,
  deps: CommandDeps,
): Promise<string> {
  const probe = await relay.probeBinding()

  if (probe.state === "rejected") {
    return [
      `Cannot rotate from here: the relay rejects this host's stored signing key (${probe.code}).`,
      `The relay operator must run: relay tenant revoke ${config.tenant}`,
      "Then restart OpenCode (autoRegister re-registers with a fresh keypair).",
    ].join("\n")
  }

  const nowSeconds = Math.floor(Date.now() / 1000)

  if (probe.state === "unbound") {
    // No signing key is bound on the relay yet (no device enrolled):
    // replacing the local keypair outright is free — no rotate call needed.
    const next = generateKeyPair()
    const updated: Registration = {
      ...registration,
      privateKeyB64: next.privateKeyB64,
      publicB64: next.publicB64,
      rotatedAt: nowSeconds,
      generation: registration.generation + 1,
    }
    await deps.store.saveRegistration(updated)
    deps.adoptRegistration(updated)
    deps.emitConfig("rotated")
    return [
      "Rotated the local signing keypair.",
      "  binding       none yet (no device enrolled) — the relay never saw the old key",
      `  key           ed25519:${next.publicB64.slice(0, 12)}… (gen ${updated.generation})`,
      "  effect        the new key takes effect at first enrollment — nothing to re-pair",
    ].join("\n")
  }

  // bound (or no-binding handled by ensureRegistration re-registering first):
  // proof-of-possession rotation replaces token + key atomically (spec §2.7).
  const next = generateKeyPair()
  const rotated = await relay.rotate(next.publicB64)
  const keyChanged = next.publicB64 !== registration.publicB64
  const updated: Registration = {
    ...registration,
    token: rotated.token,
    privateKeyB64: next.privateKeyB64,
    publicB64: next.publicB64,
    rotatedAt: typeof rotated.rotated_at === "number" ? rotated.rotated_at : nowSeconds,
    generation: registration.generation + 1,
  }
  await deps.store.saveRegistration(updated)
  deps.adoptRegistration(updated)
  let reenrolled = 0
  if (keyChanged) {
    reenrolled = await deps.store.markAllDevicesNeedsEnroll(Date.now())
  }
  deps.emitConfig("rotated")
  deps.log(
    `rotation complete (gen ${updated.generation}${keyChanged ? `; ${reenrolled} device(s) flagged for re-enrollment` : "; token-only"})`,
  )
  return [
    "Push credentials rotated.",
    `  tenant        ${rotated.tenant} (app ${rotated.app})`,
    `  key           ${
      keyChanged
        ? "new Ed25519 key bound — outstanding grants stop verifying; re-pair devices"
        : "unchanged (token-only rotation) — no re-pair needed"
    }`,
    `  token         replaced (fingerprint ${sha256hex(rotated.token).slice(0, 12)}…)`,
    `  generation    ${updated.generation}`,
    keyChanged
      ? "  devices       flagged for re-enrollment — open the iOS app to re-pair"
      : "  devices       unchanged",
  ].join("\n")
}

function pushTestCommand(deps: CommandDeps): CommandDefinitionLike {
  return {
    name: "push-test",
    description: "Send a test push to every paired device through the relay",
    execute: async (input) => {
      let text: string
      try {
        const config = deps.config()
        const engine = deps.engine()
        if (config === undefined || engine === undefined) {
          text = "Push test: the plugin is not configured."
        } else {
          const results = await engine.sendTest()
          if (results.length === 0) {
            text =
              "Push test: no paired devices — pair the iOS app first (its enrollment delivers a grant through the push RPC)."
          } else {
            const header = `Push test → ${config.relayUrl} (app ${config.app}, tenant ${config.tenant})`
            // Report rows carry machine outcomes only; relay detail text goes
            // to the server log (it would otherwise reach the model prompt).
            const rows = results.map((result) =>
              result.ok
                ? `  ${result.deviceID.padEnd(12)} accepted (${result.ms} ms)${
                    result.apnsId ? ` · apns-id ${result.apnsId}` : ""
                  }`
                : `  ${result.deviceID.padEnd(12)} FAILED ${
                    result.result !== undefined ? result.result : "error"
                  } (${result.ms} ms)`,
            )
            for (const result of results) {
              if (!result.ok && result.detail !== undefined && result.detail !== "") {
                deps.log(`push-test ${result.deviceID}: ${result.detail}`)
              }
            }
            text = [header, ...rows].join("\n")
          }
        }
      } catch (error) {
        text = `Push test failed: ${describeError(error)}`
      }
      await deps.io.submit(input.sessionID, input.delivery, text)
    },
  }
}

export function pushCommandDefinitions(deps: CommandDeps): CommandDefinitionLike[] {
  return [pushStatusCommand(deps), pushKeyRotateCommand(deps), pushTestCommand(deps)]
}
