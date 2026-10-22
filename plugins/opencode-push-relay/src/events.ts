// SPDX-License-Identifier: MPL-2.0

/**
 * Durable subscription to the host event stream (finding: "event
 * notifications stop").
 *
 * `ctx.event.subscribe()` yields an iterator that can end or throw while the
 * server is still running; if nobody resubscribes, notifications stop for
 * the rest of the process lifetime. `pumpEvents` owns that lifecycle: it
 * resubscribes whenever the iterator ends or throws (unless the signal was
 * aborted), with capped exponential backoff between attempts, and resets the
 * backoff once the stream is delivering again.
 */

const BASE_DELAY_MS = 1_000
const MAX_DELAY_MS = 30_000

/** Delay before resubscribe attempt `attempt` (1-based): 1s, 2s, … 30s cap. */
export function retryDelay(attempts: number): number {
  return Math.min(MAX_DELAY_MS, BASE_DELAY_MS * 2 ** Math.max(0, attempts - 1))
}

export function sleepWithSignal(ms: number, signal: AbortSignal): Promise<void> {
  return new Promise<void>((resolve) => {
    if (signal.aborted) {
      resolve()
      return
    }
    const done = (): void => {
      clearTimeout(timer)
      signal.removeEventListener("abort", done)
      resolve()
    }
    const timer = setTimeout(done, ms)
    signal.addEventListener("abort", done, { once: true })
  })
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error)
}

/**
 * Run `handle` over every event from `subscribe`, forever until `signal`
 * aborts. Subscription-level failures are logged and retried; handler
 * failures are logged and skipped (one bad event never kills the stream).
 */
export async function pumpEvents<T>(
  subscribe: (signal: AbortSignal) => AsyncIterable<T>,
  handle: (event: T) => Promise<void>,
  signal: AbortSignal,
  log: (message: string) => void,
  sleep: (ms: number, signal: AbortSignal) => Promise<void> = sleepWithSignal,
): Promise<void> {
  let attempts = 0
  while (!signal.aborted) {
    try {
      for await (const event of subscribe(signal)) {
        // The stream is live again — future failures start from a short delay.
        attempts = 0
        try {
          await handle(event)
        } catch (error) {
          log(`event handling failed: ${messageOf(error)}`)
        }
      }
      if (!signal.aborted) log("event stream ended — resubscribing")
    } catch (error) {
      if (signal.aborted) return
      log(`event stream error: ${messageOf(error)} — resubscribing`)
    }
    if (signal.aborted) return
    attempts += 1
    await sleep(retryDelay(attempts), signal)
  }
}
