// SPDX-License-Identifier: MPL-2.0

import assert from "node:assert/strict"
import { createServer } from "node:http"
import type { AddressInfo } from "node:net"
import { test } from "node:test"

import { RelayClient, RelayError } from "../src/relay.ts"
import { canonicalMessage, generateKeyPair, verifySignature } from "../src/signing.ts"

interface Captured {
  method: string
  path: string
  headers: Record<string, string | string[] | undefined>
  body: string
}

type Responder = (captured: Captured) => { status: number; body: unknown }

async function withServer(
  respond: Responder,
  fn: (base: string) => Promise<void>,
): Promise<Captured[]> {
  const captured: Captured[] = []
  const server = createServer((req, res) => {
    const chunks: Buffer[] = []
    req.on("data", (chunk: Buffer) => chunks.push(chunk))
    req.on("end", () => {
      const entry: Captured = {
        method: req.method ?? "",
        path: req.url ?? "",
        headers: req.headers,
        body: Buffer.concat(chunks).toString("utf8"),
      }
      captured.push(entry)
      const reply = respond(entry)
      res.statusCode = reply.status
      res.setHeader("content-type", "application/json")
      res.end(JSON.stringify(reply.body))
    })
  })
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve))
  const { port } = server.address() as AddressInfo
  try {
    await fn(`http://127.0.0.1:${port}`)
  } finally {
    await new Promise((resolve) => server.close(resolve))
  }
  return captured
}

test("RelayClient signs requests exactly the relay's way", async () => {
  const keypair = generateKeyPair()
  const creds = { token: "tnt_live-token-0001", privateKeyB64: keypair.privateKeyB64 }
  const captured = await withServer(
    () => ({ status: 200, body: { result: "accepted", apnsId: "apns-42" } }),
    async (base) => {
      const client = new RelayClient(`${base}/`, () => creds)
      const response = await client.push({
        grant: "v1.grant.sig",
        destinationToken: "ab".repeat(16),
        kind: "alert",
        eventId: "evt-1",
        content: { alert: { title: "t", body: "b" }, sealed: "c2VhbGVk" },
      })
      assert.equal(response.result, "accepted")
      assert.equal(response.apnsId, "apns-42")
    },
  )
  const [request] = captured
  assert.ok(request)
  assert.equal(request.method, "POST")
  assert.equal(request.path, "/v1/push")
  assert.equal(request.headers.authorization, "Bearer tnt_live-token-0001")
  const time = request.headers["x-relay-time"]
  const nonce = request.headers["x-relay-nonce"]
  const signature = request.headers["x-relay-signature"]
  assert.ok(typeof time === "string" && typeof nonce === "string" && typeof signature === "string")
  // The signature verifies under our pubkey over the relay's canonical form.
  const message = canonicalMessage({
    token: creds.token,
    method: "POST",
    path: "/v1/push",
    timestamp: time,
    nonce,
    body: request.body,
  })
  assert.ok(verifySignature(keypair.publicB64, message, signature))
  // The body reaches the relay byte-exact.
  const parsed = JSON.parse(request.body) as Record<string, unknown>
  assert.equal(parsed.eventId, "evt-1")
  assert.equal(parsed.destinationToken, "ab".repeat(16))
})

test("relay errors map to RelayError with the machine code and detail", async () => {
  await withServer(
    () => ({ status: 401, body: { error: "grant_expired", detail: "grant is expired" } }),
    async (base) => {
      const keypair = generateKeyPair()
      const client = new RelayClient(base, () => ({
        token: "tnt_t",
        privateKeyB64: keypair.privateKeyB64,
      }))
      await assert.rejects(
        client.push({ grant: "v1.x.y", destinationToken: "ab".repeat(16), kind: "alert", content: {} }),
        (error: unknown) =>
          error instanceof RelayError &&
          error.status === 401 &&
          error.code === "grant_expired" &&
          error.detail === "grant is expired",
      )
    },
  )
})

test("non-JSON error bodies degrade to a status-derived code", async () => {
  await withServer(
    () => ({ status: 502, body: "<html>bad gateway</html>" }),
    async (base) => {
      const keypair = generateKeyPair()
      const client = new RelayClient(base, () => ({
        token: "tnt_t",
        privateKeyB64: keypair.privateKeyB64,
      }))
      await assert.rejects(
        client.push({ grant: "v1.x.y", destinationToken: "ab".repeat(16), kind: "alert", content: {} }),
        (error: unknown) => error instanceof RelayError && error.code === "http_502" && error.status === 502,
      )
    },
  )
})

test("unsigned routes: register and health carry no signature", async () => {
  const captured = await withServer(
    (request) =>
      request.path === "/health"
        ? { status: 200, body: { status: "ok" } }
        : { status: 201, body: { tenant: "host-a", app: "opencode", token: "tnt_new", quota: 10, registered_at: 1, expires_at: 2 } },
    async (base) => {
      const client = new RelayClient(base, () => undefined)
      assert.deepEqual(await client.health(), { status: "ok" })
      const registered = await client.register({ id: "host-a", app: "opencode" })
      assert.equal(registered.token, "tnt_new")
    },
  )
  const [health, register] = captured
  assert.ok(health && register)
  assert.equal(health.headers.authorization, undefined)
  assert.equal(register.headers["x-relay-signature"], undefined)
  assert.deepEqual(JSON.parse(register.body), { id: "host-a", app: "opencode" })
})

test("signed route bodies carry the documented field names", async () => {
  const captured = await withServer(
    () => ({ status: 200, body: { grant: "v1.renewed", expiresAt: 99 } }),
    async (base) => {
      const keypair = generateKeyPair()
      const client = new RelayClient(base, () => ({ token: "tnt_t", privateKeyB64: keypair.privateKeyB64 }))
      await client.renew("v1.g.s", 7200)
      await client.renew("v1.g.s")
      await client.revoke("v1.g.s")
      await client.rotate("NEW_PUBKEY")
    },
  )
  const bodies = captured.map((request) => JSON.parse(request.body) as Record<string, unknown>)
  assert.deepEqual(bodies[0], { grant: "v1.g.s", ttl: 7200 })
  assert.deepEqual(bodies[1], { grant: "v1.g.s" })
  assert.deepEqual(bodies[2], { grant: "v1.g.s" })
  assert.deepEqual(bodies[3], { pubkey: "NEW_PUBKEY" })
  assert.deepEqual(
    captured.map((request) => request.path),
    ["/v1/enroll/renew", "/v1/enroll/renew", "/v1/revoke", "/v1/rotate"],
  )
})

test("probeBinding disambiguates binding states from signed auth outcomes", async () => {
  const keypair = generateKeyPair()
  const creds = () => ({ token: "tnt_t", privateKeyB64: keypair.privateKeyB64 })
  const probeWith = async (status: number, body: unknown) => {
    let state: unknown
    await withServer(
      () => ({ status, body }),
      async (base) => {
        state = await new RelayClient(base, creds).probeBinding()
      },
    )
    return state
  }
  assert.deepEqual(await probeWith(401, { error: "unknown_tenant" }), { state: "no-binding" })
  assert.deepEqual(await probeWith(401, { error: "enrollment_required" }), { state: "unbound" })
  assert.deepEqual(await probeWith(401, { error: "invalid_signature" }), {
    state: "rejected",
    code: "invalid_signature",
  })
  assert.deepEqual(await probeWith(401, { error: "invalid_timestamp" }), {
    state: "rejected",
    code: "invalid_timestamp",
  })
  // Auth passed; the fake grant itself was rejected → the binding is ours.
  assert.deepEqual(await probeWith(400, { error: "invalid_grant" }), { state: "bound" })
})

test("probeBinding surfaces unreachable relays instead of guessing", async () => {
  // Port 1 on loopback: connection refused.
  const client = new RelayClient("http://127.0.0.1:1", () => ({
    token: "tnt_t",
    privateKeyB64: generateKeyPair().privateKeyB64,
  }))
  await assert.rejects(client.probeBinding(), (error: unknown) => error instanceof RelayError && error.status === 0)
})

test("signed calls without stored credentials fail as not_configured", async () => {
  const client = new RelayClient("http://127.0.0.1:1", () => undefined)
  await assert.rejects(
    client.push({ grant: "v1.x.y", destinationToken: "ab".repeat(16), kind: "alert", content: {} }),
    (error: unknown) => error instanceof RelayError && error.code === "not_configured",
  )
})
