// SPDX-License-Identifier: MPL-2.0

import assert from "node:assert/strict"
import { randomBytes } from "node:crypto"
import { spawnSync } from "node:child_process"
import { test } from "node:test"

import { claimProcessScope } from "../src/process-scope.ts"

const moduleUrl = new URL("../src/process-scope.ts", import.meta.url).href

function childClaim(scope: string) {
  return spawnSync(process.execPath, ["--input-type=module", "-e", `
    import { claimProcessScope } from ${JSON.stringify(moduleUrl)};
    try { await claimProcessScope(${JSON.stringify(scope)}); }
    catch (error) { console.error(error.message); process.exitCode = 2; }
  `], { encoding: "utf8", timeout: 5000 })
}

test("scope claims exclude another process but permit same-process instances and independent scopes", async () => {
  const scope = randomBytes(8).toString("hex")
  await Promise.all([claimProcessScope(scope), claimProcessScope(scope)])
  const blocked = childClaim(scope)
  assert.equal(blocked.error, undefined)
  assert.equal(blocked.status, 2)
  assert.match(blocked.stderr, /another process may own it/)
  const independent = childClaim(randomBytes(8).toString("hex"))
  assert.equal(independent.error, undefined)
  assert.equal(independent.status, 0)
})
