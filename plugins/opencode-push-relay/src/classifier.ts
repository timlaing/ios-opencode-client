// SPDX-License-Identifier: MPL-2.0

/**
 * Maps the host-wide OpenCode event stream to push drafts.
 *
 * This is the TypeScript mirror of the iOS app's `EventClassifier`
 * (`Packages/OpenCodeKit/Sources/OpenCodeDomain/NotificationClassifier.swift`):
 * same categories, same copy, same ledger-key identity. Keep the two in step —
 * the APNs `aps.category` and the `sealed` routing blob must match what the
 * app already classifies locally.
 *
 * Privacy rule (docs/notifications.md): category copy only — never transcript
 * text, tool arguments, or file content. The `summaries` level may carry a
 * short server-provided failure summary, exactly like the local classifier.
 */

export const ALL_CATEGORIES = [
  "sessionCompleted",
  "sessionFailed",
  "permissionRequested",
  "formRequested",
] as const

export type PushCategory = (typeof ALL_CATEGORIES)[number]

export type ContentLevel = "minimal" | "summaries"

/** One deduplicated notification decision for a canonical transition. */
export interface PushDraft {
  category: PushCategory
  sessionID: string
  /** Permission requestID or form ID when the category routes to its owner. */
  ownerID: string | null
  transitionID: string
  /** Stable identity: host, session, owner, canonical transition. */
  ledgerKey: string
  title: string
  body: string
}

/** Shape of one `ctx.event.subscribe()` item, narrowed defensively. */
export interface RawEvent {
  readonly type?: unknown
  readonly id?: unknown
  readonly data?: unknown
}

export interface ClassifyOptions {
  readonly categories: readonly PushCategory[]
  readonly contentLevel: ContentLevel
}

function stringOf(value: unknown): string | null {
  return typeof value === "string" && value.length > 0 ? value : null
}

/**
 * Short failure reason at the `summaries` level, tolerating string and object
 * error shapes; falls back to `null` when nothing usable is present (mirrors
 * `failureSummary` in Swift).
 */
function failureSummary(data: Record<string, unknown>): string | null {
  const error = data["error"]
  if (error === undefined || error === null) return null
  if (typeof error === "string") return error.length > 0 ? error : null
  if (typeof error === "object") {
    const object = error as Record<string, unknown>
    const message = stringOf(object["message"])
    if (message !== null) return message
    const nested = object["data"]
    if (nested !== null && typeof nested === "object") {
      const nestedMessage = stringOf((nested as Record<string, unknown>)["message"])
      if (nestedMessage !== null) return nestedMessage
    }
  }
  return null
}

/** Stable ledger/notification identity for one canonical transition. */
export function ledgerKey(
  hostID: string,
  sessionID: string,
  ownerID: string | null,
  transitionID: string,
): string {
  return `host:${hostID}|session:${sessionID}|owner:${ownerID ?? "-"}|transition:${transitionID}`
}

/**
 * Classify one stream event, or return `null` when it is not alert material:
 * wrong shape, untracked session, missing transition identity (repeats could
 * not be deduplicated), or a category the host has disabled.
 */
export function classify(
  event: RawEvent,
  hostID: string,
  options: ClassifyOptions,
): PushDraft | null {
  const type = stringOf(event.type)
  const data =
    event.data !== null && typeof event.data === "object"
      ? (event.data as Record<string, unknown>)
      : {}
  const sessionID = stringOf(data["sessionID"])
  if (type === null || sessionID === null) return null

  // No canonical transition identity means no stable ledger key, and
  // therefore no banner (repeats could not be deduplicated).
  const transitionID = stringOf(event.id)
  if (transitionID === null) return null

  let category: PushCategory
  let ownerID: string | null
  let title: string
  let body: string
  switch (type) {
    case "session.execution.succeeded":
      category = "sessionCompleted"
      ownerID = null
      title = "Session completed"
      body = "The session finished successfully."
      break
    case "session.execution.failed":
      category = "sessionFailed"
      ownerID = null
      title = "Session failed"
      if (options.contentLevel === "summaries") {
        body = failureSummary(data) ?? "The session stopped with an error."
      } else {
        body = "The session stopped with an error."
      }
      break
    case "permission.asked":
      category = "permissionRequested"
      ownerID = stringOf(data["requestID"])
      title = "Permission needed"
      body = "A tool permission request is waiting for your reply."
      break
    case "form.created":
      category = "formRequested"
      ownerID = stringOf(data["id"])
      title = "Question waiting"
      body = "A question needs your answer."
      break
    default:
      // Deltas, tool traffic, status, inbox, config: not alert material.
      return null
  }

  if (!options.categories.includes(category)) return null

  // Owner-routed categories need their owner: without it there is no target
  // and no stable ledger identity (mirrors the Swift classifier).
  if ((category === "permissionRequested" || category === "formRequested") && ownerID === null) {
    return null
  }

  return {
    category,
    sessionID,
    ownerID,
    transitionID,
    ledgerKey: ledgerKey(hostID, sessionID, ownerID, transitionID),
    title,
    body,
  }
}
