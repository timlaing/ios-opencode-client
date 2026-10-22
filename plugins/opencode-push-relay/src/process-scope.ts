// SPDX-License-Identifier: MPL-2.0

import { createServer, type Server } from "node:net"

// Hold claims until process exit, including during setup failures and shutdown:
// asynchronous sends may still be in flight after a plugin disposer returns.
const claims = new Map<string, Promise<Server>>()

/** One local OS process per configured scope; no reliance on non-atomic KV writes. */
export async function claimProcessScope(scope: string): Promise<void> {
  if (!/^[a-f0-9]{16}$/.test(scope)) throw new Error("Invalid push-relay scope")
  let claim = claims.get(scope)
  if (claim === undefined) {
    claim = new Promise<Server>((resolve, reject) => {
      const server = createServer((socket) => socket.destroy())
      const name = `opencode-push-${process.getuid?.() ?? "user"}-${scope}`
      const path = process.platform === "win32" ? `\\\\.\\pipe\\${name}` : `/tmp/${name}.sock`
      server.once("error", (error) => {
        reject(new Error(
          `Cannot claim push-relay scope ${scope}: another process may own it (${error.message}). ` +
          "Run this scope in one process only. A stale socket after a crash must be removed only after all owners have stopped.",
        ))
      })
      server.listen(path, () => {
        server.unref()
        resolve(server)
      })
    })
    claims.set(scope, claim)
  }
  await claim
}
