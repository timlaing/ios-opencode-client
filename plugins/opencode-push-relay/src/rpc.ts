// SPDX-License-Identifier: MPL-2.0

import { Rpc } from "@opencode/plugin"

/**
 * The narrow host↔client push contract (`id: "push"`).
 *
 * Deliberately narrow per docs/notifications.md: enrollment, preferences,
 * status, revocation. No agent tools, no general remote-command channel —
 * this is the only surface the iOS app may call on the OpenCode host.
 *
 * The `./rpc` export lets clients and other plugins import the contract
 * without loading the implementation.
 */

const prefsSessionsSchema = {
  oneOf: [
    { type: "string", const: "all" },
    { type: "array", items: { type: "string", minLength: 1, maxLength: 128 }, maxItems: 500 },
  ],
}

const prefsSchema = {
  type: "object",
  properties: {
    sessions: prefsSessionsSchema,
    categories: {
      type: "array",
      items: {
        type: "string",
        enum: ["sessionCompleted", "sessionFailed", "permissionRequested", "formRequested"],
      },
      maxItems: 4,
    },
    contentLevel: { type: "string", enum: ["minimal", "summaries"] },
  },
  additionalProperties: false,
}

const prefsResultSchema = {
  type: "object",
  properties: {
    sessions: prefsSessionsSchema,
    categories: { type: "array", items: { type: "string" } },
    contentLevel: { type: "string" },
  },
  required: ["sessions", "categories", "contentLevel"],
  additionalProperties: false,
}

/** Errors carrying no structured data. */
const bareError = {}

export const PushRpc = Rpc.define({
  id: "push",
  methods: {
    /**
     * Unauthenticated-shape info fetch: the iOS app reads this before pairing
     * to learn the relay URL, tenant id, and the host's Ed25519 public key
     * (the relay TOFU-binds it at first enrollment).
     */
    info: {
      input: { type: "object", properties: {}, additionalProperties: false },
      output: {
        type: "object",
        properties: {
          configured: { type: "boolean" },
          relayUrl: { type: "string" },
          app: { type: "string" },
          tenant: { type: "string" },
          registered: { type: "boolean" },
          tenantPubkey: { type: ["string", "null"] },
          generation: { type: ["integer", "null"] },
          binding: { type: ["string", "null"] },
          categories: { type: "array", items: { type: "string" } },
          contentLevel: { type: "string" },
          defaultSessions: { type: "string" },
          devices: { type: "integer" },
          needsEnroll: { type: "array", items: { type: "string" } },
        },
        required: [
          "configured",
          "relayUrl",
          "app",
          "tenant",
          "registered",
          "tenantPubkey",
          "generation",
          "binding",
          "categories",
          "contentLevel",
          "defaultSessions",
          "devices",
          "needsEnroll",
        ],
        additionalProperties: false,
      },
      errors: {
        not_configured: bareError,
      },
    },

    /**
     * Pair (or re-pair) one device: the client delivers a grant obtained from
     * the relay's enrollment flow. The grant must be bound to this tenant,
     * this host's current pubkey, and exactly this destination token — the
     * same three claims the relay enforces on `/v1/push`.
     */
    enroll: {
      input: {
        type: "object",
        properties: {
          destinationToken: { type: "string", pattern: "^[0-9a-fA-F]{32,2000}$" },
          grant: { type: "string", minLength: 8, maxLength: 8192 },
          deviceID: { type: "string", pattern: "^[A-Za-z0-9._:-]{1,64}$" },
          prefs: prefsSchema,
        },
        required: ["destinationToken", "grant"],
        additionalProperties: false,
      },
      output: {
        type: "object",
        properties: {
          deviceID: { type: "string" },
          grantExpiresAt: { type: "integer" },
          environment: { type: ["string", "null"] },
          sessions: prefsSessionsSchema,
          categories: { type: "array", items: { type: "string" } },
          contentLevel: { type: "string" },
        },
        required: [
          "deviceID",
          "grantExpiresAt",
          "environment",
          "sessions",
          "categories",
          "contentLevel",
        ],
        additionalProperties: false,
      },
      errors: {
        not_configured: bareError,
        registration_missing: bareError,
        invalid_grant: {
          type: "object",
          properties: { problem: { type: "string" } },
          required: ["problem"],
          additionalProperties: false,
        },
        bad_device_id: bareError,
        bad_destination_token: bareError,
      },
    },

    /** Update a paired device's delivery preferences. */
    update: {
      input: {
        type: "object",
        properties: {
          deviceID: { type: "string", pattern: "^[A-Za-z0-9._:-]{1,64}$" },
          prefs: prefsSchema,
        },
        required: ["deviceID", "prefs"],
        additionalProperties: false,
      },
      output: {
        type: "object",
        properties: {
          deviceID: { type: "string" },
          sessions: prefsSessionsSchema,
          categories: { type: "array", items: { type: "string" } },
          contentLevel: { type: "string" },
        },
        required: ["deviceID", "sessions", "categories", "contentLevel"],
        additionalProperties: false,
      },
      errors: {
        not_configured: bareError,
        registration_missing: bareError,
        unknown_device: bareError,
      },
    },

    /** Structured status, mirroring `/push-status` (no credentials beyond fingerprints). */
    status: {
      input: { type: "object", properties: {}, additionalProperties: false },
      output: {
        type: "object",
        properties: {
          configured: { type: "boolean" },
          missing: { type: "array", items: { type: "string" } },
          problems: { type: "array", items: { type: "string" } },
          relayUrl: { type: ["string", "null"] },
          app: { type: ["string", "null"] },
          tenant: { type: ["string", "null"] },
          registered: { type: "boolean" },
          tenantPubkey: { type: ["string", "null"] },
          probe: { type: ["string", "null"] },
          health: {
            type: ["object", "null"],
            properties: {
              ok: { type: "boolean" },
              latencyMs: { type: "integer" },
              error: { type: "string" },
            },
          },
          devices: {
            type: "array",
            items: {
              type: "object",
              properties: {
                id: { type: "string" },
                needsEnroll: { type: "boolean" },
                grantExpiresAt: { type: "integer" },
                environment: { type: ["string", "null"] },
                lastResult: { type: ["string", "null"] },
                sessions: prefsSessionsSchema,
                categories: { type: "array", items: { type: "string" } },
              },
              required: [
                "id",
                "needsEnroll",
                "grantExpiresAt",
                "environment",
                "lastResult",
                "sessions",
                "categories",
              ],
              additionalProperties: false,
            },
          },
          outboxDepth: { type: "integer" },
          stats: {
            type: "object",
            properties: {
              enqueued: { type: "integer" },
              accepted: { type: "integer" },
              rejected: { type: "integer" },
              retryable: { type: "integer" },
              invalidDestination: { type: "integer" },
              dropped: { type: "integer" },
              renewals: { type: "integer" },
            },
            required: [
              "enqueued",
              "accepted",
              "rejected",
              "retryable",
              "invalidDestination",
              "dropped",
              "renewals",
            ],
            additionalProperties: false,
          },
          notes: { type: "array", items: { type: "string" } },
        },
        required: [
          "configured",
          "missing",
          "problems",
          "relayUrl",
          "app",
          "tenant",
          "registered",
          "tenantPubkey",
          "probe",
          "health",
          "devices",
          "outboxDepth",
          "stats",
          "notes",
        ],
        additionalProperties: false,
      },
      errors: {},
    },

    /** Remove a paired device locally and revoke its grant on the relay. */
    revoke: {
      input: {
        type: "object",
        properties: { deviceID: { type: "string", pattern: "^[A-Za-z0-9._:-]{1,64}$" } },
        required: ["deviceID"],
        additionalProperties: false,
      },
      output: {
        type: "object",
        properties: {
          deviceID: { type: "string" },
          relayRevoked: { type: "boolean" },
        },
        required: ["deviceID", "relayRevoked"],
        additionalProperties: false,
      },
      errors: {
        not_configured: bareError,
        unknown_device: bareError,
      },
    },
  },
  events: {
    /** Registration changed (first register, rotation, re-bind). Apps re-fetch info + re-enroll. */
    config: {
      schema: {
        type: "object",
        properties: {
          reason: { type: "string", enum: ["registered", "rotated", "rebound"] },
          tenant: { type: "string" },
          tenantPubkey: { type: "string" },
          generation: { type: "integer" },
        },
        required: ["reason", "tenant", "tenantPubkey", "generation"],
        additionalProperties: false,
      },
    },
    /** A device's enrollment state changed. */
    device: {
      schema: {
        type: "object",
        properties: {
          deviceID: { type: "string" },
          state: { type: "string", enum: ["needsEnroll", "removed", "ok"] },
        },
        required: ["deviceID", "state"],
        additionalProperties: false,
      },
    },
  },
})
