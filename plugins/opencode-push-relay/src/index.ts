// SPDX-License-Identifier: MPL-2.0

import { Plugin } from "@opencode/plugin"

import { classify } from "./classifier.ts"
import type { CommandDeps } from "./commands.ts"
import { pushCommandDefinitions } from "./commands.ts"
import { parseConfig, type ConfigResult } from "./config.ts"
import { DeliveryEngine } from "./engine.ts"
import type { HandlerDeps } from "./handlers.ts"
import { makeRpcHandlers } from "./handlers.ts"
import { PushRpc } from "./rpc.ts"
import { RelayClient, RelayError } from "./relay.ts"
import { generateKeyPair } from "./signing.ts"
import { buildStatus, type StatusReport } from "./status.ts"
import { PushStore, withLock, type Registration } from "./store.ts"

/**
 * OpenCode server plugin for one apns-push-relay instance.
 *
 * - Registers this host (tenant) with the relay on startup when configured;
 *   inert until `options.relayUrl` and `options.app` are set in opencode.json(c).
 * - Exposes the narrow `push` RPC (info/enroll/update/status/revoke + config/
 *   device events) so paired iOS clients can enroll and manage prefs.
 * - Classifies the host event stream and delivers notifications through a
 *   durable, lease-governed outbox (engine.ts).
 * - Commands: /push-status, /push-key-rotate, /push-test.
 *
 * Storage is one server-global KV table namespaced by plugin id, so all
 * project locations share one registration, device set, and outbox; the
 * delivery lease keeps a single instance draining at a time.
 */

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

export default Plugin.define({
  id: "opencode-push-relay",
  async setup(ctx) {
    const log = (message: string): void => console.log(`[opencode-push-relay] ${message}`)

    const configResult: ConfigResult = parseConfig(ctx.options)
    const store = new PushStore(ctx.storage)

    let registration: Registration | undefined = await store.getRegistration()
    let ensureOutcome: string | undefined

    const config = configResult.ok ? configResult.config : undefined
    const relay =
      config === undefined
        ? undefined
        : new RelayClient(config.relayUrl, () =>
            registration === undefined
              ? undefined
              : { token: registration.token, privateKeyB64: registration.privateKeyB64 },
          )

    // Assigned right after the RPC registration below; command/RPC/event
    // paths only run after setup completes, so the closures are always live.
    let emitConfig: (reason: "registered" | "rotated" | "rebound") => void = () => {}
    let emitDevice: (deviceID: string, state: "needsEnroll" | "removed" | "ok") => void =
      () => {}

    const register = async (): Promise<Registration> => {
      if (config === undefined || relay === undefined) throw new Error("not configured")
      const response = await relay.register({ id: config.tenant, app: config.app })
      const keypair = generateKeyPair()
      const nowSeconds = Math.floor(Date.now() / 1000)
      const stored: Registration = {
        tenant: response.tenant,
        app: response.app,
        token: response.token,
        privateKeyB64: keypair.privateKeyB64,
        publicB64: keypair.publicB64,
        registeredAt:
          typeof response.registered_at === "number" ? response.registered_at : nowSeconds,
        rotatedAt: undefined,
        generation: 1,
      }
      await store.saveRegistration(stored)
      registration = stored
      log(`registered with the relay as tenant ${stored.tenant} (app ${stored.app})`)
      return stored
    }

    /**
     * Ensure usable credentials exist. With no stored registration this
     * registers (when autoRegister is on); with a registration whose binding
     * vanished from the relay (idle-expired or revoked) it re-registers and
     * flags paired devices for re-enrollment. Serialized per process; other
     * processes converge because re-registering an existing tenant id yields
     * unknown_tenant-ish failures that simply retry next tick.
     */
    const ensureRegistration = async (): Promise<Registration | undefined> => {
      if (config === undefined || relay === undefined) return undefined
      return withLock("opencode-push-relay:ensure", async () => {
        const existing = await store.getRegistration()
        if (existing !== undefined) {
          registration = existing
          try {
            const probe = await relay.probeBinding()
            if (probe.state === "no-binding" && config.autoRegister) {
              const fresh = await register()
              await store.markAllDevicesNeedsEnroll(Date.now())
              emitConfig("registered")
              return fresh
            }
          } catch (error) {
            log(`binding probe failed: ${messageOf(error)}`)
          }
          return existing
        }
        if (!config.autoRegister) {
          ensureOutcome = "autoRegister is off and no credentials are stored"
          return undefined
        }
        try {
          const fresh = await register()
          emitConfig("registered")
          return fresh
        } catch (error) {
          if (error instanceof RelayError && error.code === "id_exists") {
            ensureOutcome =
              "the tenant id is already registered on this relay, but this host holds no token for it — restore this plugin's storage, set a distinct options.tenant, or have the relay operator run `relay tenant revoke`"
          } else {
            ensureOutcome = `registration failed: ${messageOf(error)}`
          }
          log(ensureOutcome)
          return undefined
        }
      })
    }

    /**
     * A signed request failed with a binding-level code: re-read credentials
     * from storage (another instance may have rotated/re-registered) and
     * probe; re-register when the binding is gone.
     */
    const recoverRegistration = (code: string): void => {
      log(`relay rejected a signed request (${code}) — re-reading credentials`)
      void (async () => {
        const fresh = await store.getRegistration()
        if (fresh === undefined) return
        registration = fresh
        if (relay === undefined || config === undefined) return
        try {
          const probe = await relay.probeBinding()
          if (probe.state === "no-binding" || probe.state === "unbound") {
            await ensureRegistration()
            const after = await store.getRegistration()
            if (after !== undefined && after.token !== fresh.token) {
              await store.markAllDevicesNeedsEnroll(Date.now())
              emitConfig("registered")
            }
          } else if (probe.state === "rejected") {
            log(
              "stored signing key does not match the relay's — /push-key-rotate cannot fix this; see /push-status",
            )
          }
        } catch (error) {
          log(`recovery probe failed: ${messageOf(error)}`)
        }
      })()
    }

    let engine: DeliveryEngine | undefined
    let kickEngine: () => void = () => {}

    const buildStatusReport = async (): Promise<StatusReport> => {
      const lease = await store.getLease()
      return buildStatus({
        config,
        missing: configResult.ok ? [] : configResult.missing,
        problems: configResult.ok ? [] : configResult.problems,
        store,
        relay,
        ensureOutcome,
        instanceHoldsLease:
          engine !== undefined && lease !== undefined && lease.owner === engine.instanceID,
      })
    }

    // RPC surface for paired iOS clients (and the app's pre-pair info fetch).
    const handlerDeps: HandlerDeps = {
      config,
      store,
      relay,
      ensureRegistration,
      buildStatusReport,
    }
    const rpcRegistration = await ctx.rpc.register(PushRpc, makeRpcHandlers(handlerDeps) as never)

    emitConfig = (reason) => {
      void rpcRegistration.events
        .emit("config", {
          reason,
          tenant: registration?.tenant ?? config?.tenant ?? "",
          tenantPubkey: registration?.publicB64 ?? "",
          generation: registration?.generation ?? 0,
        })
        .catch((error) => log(`config event failed: ${messageOf(error)}`))
    }
    emitDevice = (deviceID, state) => {
      void rpcRegistration.events
        .emit("device", { deviceID, state })
        .catch((error) => log(`device event failed: ${messageOf(error)}`))
    }

    // Commands: compute a report, hand it back through the session prompt.
    const commandDeps: CommandDeps = {
      config: () => config,
      store,
      engine: () => engine,
      relay: () => relay,
      ensureRegistration,
      adoptRegistration: (updated) => {
        registration = updated
      },
      buildStatusReport,
      emitConfig: (reason) => emitConfig(reason),
      io: {
        submit: async (sessionID, delivery, report) => {
          await ctx.session.prompt({
            sessionID,
            delivery,
            text: `${report}\n\n(The lines above came from the push-relay plugin — present them verbatim; no tools or analysis needed.)`,
          } as never)
        },
      },
      log,
    }
    await ctx.command.transform((editor) => {
      for (const definition of pushCommandDefinitions(commandDeps)) {
        editor.add(definition)
      }
    })

    if (config !== undefined && relay !== undefined) {
      engine = new DeliveryEngine(config, store, relay, {
        onDeviceNeedsEnroll: (deviceID) => emitDevice(deviceID, "needsEnroll"),
        onRegistrationLost: (code) => recoverRegistration(code),
        kick: () => kickEngine(),
        log,
      })
      const created = engine
      kickEngine = () => {
        void created.tick()
      }

      await ensureRegistration().catch((error) =>
        log(`startup registration failed: ${messageOf(error)}`),
      )

      // Classify the host event stream into the durable outbox.
      const controller = new AbortController()
      void (async () => {
        try {
          for await (const event of ctx.event.subscribe({ signal: controller.signal })) {
            try {
              const draft = classify(event, config.tenant, {
                categories: config.categories,
                contentLevel: config.contentLevel,
              })
              if (draft !== null) await created.enqueue(draft)
            } catch (error) {
              log(`event handling failed: ${messageOf(error)}`)
            }
          }
        } catch (error) {
          if (!controller.signal.aborted) log(`event stream ended: ${messageOf(error)}`)
        }
      })()

      const timer = setInterval(() => {
        void created.tick()
      }, 15_000)
      timer.unref?.()
      void created.tick()

      log(
        `active: ${config.relayUrl} (app ${config.app}, tenant ${config.tenant}) — /push-status for details`,
      )
      return () => {
        clearInterval(timer)
        controller.abort()
        void store.releaseLease(created.instanceID).catch(() => undefined)
      }
    }

    const issues = [
      ...(configResult.ok ? [] : configResult.missing.map((entry) => `missing ${entry}`)),
      ...(configResult.ok ? [] : configResult.problems),
    ]
    log(
      `inactive: ${issues.join("; ") || "not configured"} — set plugins[].options.relayUrl and .app in opencode.json(c), then /push-status`,
    )
  },
})
