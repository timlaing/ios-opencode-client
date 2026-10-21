// SPDX-License-Identifier: MPL-2.0

import assert from "node:assert/strict"
import { test } from "node:test"

import { ALL_CATEGORIES } from "../src/classifier.ts"
import { parseConfig } from "../src/config.ts"

test("empty options: missing relayUrl and app, hostname tenant, inert", () => {
  const result = parseConfig({})
  assert.equal(result.ok, false)
  assert.ok(!result.ok)
  assert.deepEqual(result.missing, ["relayUrl", "app"])
  assert.deepEqual(result.problems, [])
})

test("valid options parse, normalize the URL, and keep declared values", () => {
  const result = parseConfig({
    relayUrl: "https://push.example.org/",
    app: "opencode",
    tenant: "mac.local",
    categories: ["sessionFailed"],
    contentLevel: "summaries",
    defaultSessions: "none",
    autoRegister: false,
    pushTtlSeconds: 600,
    grantTtlSeconds: 7200,
  })
  assert.ok(result.ok)
  assert.equal(result.config.relayUrl, "https://push.example.org")
  assert.equal(result.config.app, "opencode")
  assert.equal(result.config.tenant, "mac.local")
  assert.deepEqual(result.config.categories, ["sessionFailed"])
  assert.equal(result.config.contentLevel, "summaries")
  assert.equal(result.config.defaultSessions, "none")
  assert.equal(result.config.autoRegister, false)
  assert.equal(result.config.pushTtlSeconds, 600)
  assert.equal(result.config.grantTtlSeconds, 7200)
})

test("defaults: all categories, minimal content, all sessions, autoRegister on", () => {
  const result = parseConfig({ relayUrl: "https://relay.example", app: "opencode" })
  assert.ok(result.ok)
  assert.deepEqual(result.config.categories, [...ALL_CATEGORIES])
  assert.equal(result.config.contentLevel, "minimal")
  assert.equal(result.config.defaultSessions, "all")
  assert.equal(result.config.autoRegister, true)
  assert.equal(result.config.pushTtlSeconds, 3600)
  assert.equal(result.config.grantTtlSeconds, undefined)
  assert.ok(result.config.tenant.length > 0)
})

test("bad values accumulate every problem instead of failing fast", () => {
  const result = parseConfig({
    relayUrl: "ftp://push.example.org",
    app: "a".repeat(65),
    categories: ["nope", "sessionFailed"],
    contentLevel: "loud",
    defaultSessions: "some",
    autoRegister: "yes",
    pushTtlSeconds: 5,
    grantTtlSeconds: "long",
  })
  assert.equal(result.ok, false)
  assert.ok(!result.ok)
  const problems = result.problems.join("\n")
  assert.match(problems, /relayUrl: must be an http\(s\) URL/)
  assert.match(problems, /app: at most 64 characters/)
  assert.match(problems, /categories: unknown nope/)
  assert.match(problems, /contentLevel: must be minimal or summaries/)
  assert.match(problems, /defaultSessions: must be all or none/)
  assert.match(problems, /autoRegister: must be a boolean/)
  assert.match(problems, /pushTtlSeconds: integer seconds/)
  assert.match(problems, /grantTtlSeconds: integer seconds/)
})

test("categories must be an array when provided", () => {
  const result = parseConfig({
    relayUrl: "https://relay.example",
    app: "opencode",
    categories: "sessionFailed",
  })
  assert.equal(result.ok, false)
  assert.ok(!result.ok)
  assert.match(result.problems.join(" "), /categories: must be an array/)
})

test("http URLs are accepted (loopback relays during development)", () => {
  const result = parseConfig({ relayUrl: "http://127.0.0.1:8787", app: "opencode" })
  assert.ok(result.ok)
  assert.equal(result.config.relayUrl, "http://127.0.0.1:8787")
  // Loopback spellings all qualify.
  for (const url of ["http://localhost:8787", "http://[::1]:8787"]) {
    const loopback = parseConfig({ relayUrl: url, app: "opencode" })
    assert.ok(loopback.ok, url)
    assert.equal(loopback.config.relayUrl, url)
  }
})

test("cleartext http to non-loopback hosts is rejected", () => {
  const result = parseConfig({ relayUrl: "http://push.example.org", app: "opencode" })
  assert.equal(result.ok, false)
  assert.ok(!result.ok)
  assert.match(result.problems.join(" "), /relayUrl: must use https:\/\//)
})

test("relayUrl with a query string or fragment is rejected", () => {
  for (const url of [
    "https://push.example.org?tenant=host-a",
    "https://push.example.org/#frag",
    "http://127.0.0.1:8787?x=1",
  ]) {
    const result = parseConfig({ relayUrl: url, app: "opencode" })
    assert.equal(result.ok, false, url)
    assert.ok(!result.ok)
    assert.match(
      result.problems.join(" "),
      /relayUrl: must not include a query string or fragment/,
      url,
    )
  }
})
