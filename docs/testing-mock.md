# Generated test data and reference mock

## Purpose and boundaries

The mock implements synthetic behavior for every operation mapped to initial mobile workflows, plus a few later/read-only helper operations. It uses the real pinned OpenAPI routes/shapes, existing authentication/pairing model, server SSE framing, and representative server state transitions. It is a reference for implementing/testing the mobile adapter and UI, not a substitute for OpenCode or proof of real-server/device behavior.

All project names, paths, prompts, credentials, tokens, files, outputs and errors are generated. The virtual `/srv/demo` and `/tmp/opencode-mock` paths refer to in-memory mock state, not files on the machine running the mock. No model/provider calls, tool execution, actual shell commands, MCP processes, or project-filesystem writes occur. The mock uses only Python 3.11+ standard-library modules.

## Artefacts and repeatable commands

| Artefact                                                                                                       | Purpose                                                                                    |
| -------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| [OpenAPI snapshot](../contracts/opencode-v2.0.25.openapi.json)                                                 | Authoritative pinned wire definitions                                                      |
| [Source manifest](../contracts/source-manifest.json)                                                           | Version/commit, hash, operation counts, upstream licence                                   |
| [Mobile scope](../contracts/mobile-scope.json)                                                                 | Workflow → screen → operation bindings and initial/later scope                             |
| [Route catalog](../contracts/route-catalog.json)                                                               | All operations, schemas, parameters, status codes, mock coverage                           |
| [Generated demo fixture](../fixtures/generated/demo.json)                                                      | Deterministic read models and fictional file content                                       |
| [Generated HTTP cases](../fixtures/generated/http-cases.json)                                                  | Example requests and expected responses/statuses validated through HTTP tests              |
| [Generated SSE frames](../fixtures/generated/events.sse) / [decoded trace](../fixtures/generated/events.jsonl) | Deterministic streaming fixtures for native decoder/reducer tests without a running server |
| [Fixture generator](../mock/fixtures.py)                                                                       | Repeatable seed-based generation                                                           |
| [Mock server](../mock/server.py)                                                                               | Stateful JSON/binary/SSE behavior and scenario controls                                    |
| [Contract guards](../mock/contract.py)                                                                         | Snapshot-derived route and schema checks; source-derived event subset guard                |
| [Automated tests](../tests/test_mock.py)                                                                       | Contract and loopback HTTP integration checks                                              |

From the workspace root:

```sh
python3 -m mock.fixtures
python3 scripts/build_contracts.py
python3 -m unittest discover -s tests -v
python3 -m mock.server --port 4097
```

The listener defaults to loopback. Development-only credentials are username `opencode`, password `mock-password`. Mock controls require `X-Mock-Control: mock-control`. These are public synthetic demo values, not secrets or production defaults. The native production app must never automatically use these values on a real host.

```sh
curl -u opencode:mock-password http://127.0.0.1:4097/api/info
curl -u opencode:mock-password -X POST http://127.0.0.1:4097/api/pair
curl -u opencode:mock-password -N http://127.0.0.1:4097/api/event
```

Redeem the returned code with a JSON-accepting GET to `/auth/connect/<code>`, then use the returned token as the Basic password. Codes are single-use with a five-minute expiry. Tokens use the pinned password-derived HMAC approach and a 30-day lifetime; rotating the mock password invalidates them. Browser HTML pairing returns a redirect/cookie. Cookie/redirect fidelity is intentionally narrower than production and described below.

For physical-device transport testing, explicitly bind a reachable interface and provide a trusted certificate/key:

```sh
python3 -m mock.server --host 0.0.0.0 --port 4097 \
  --tls-cert /path/to/trusted-local-cert.pem \
  --tls-key /path/to/local-key.pem
```

Use an actual trusted certificate for the chosen hostname, and network access under the existing VPN/host setup. Certificate files are local deployment inputs and are not committed. Set a different mock control key when exposing the listener to other devices. HTTP loopback is a development-only transport profile, not an exception to production HTTPS validation. A sandbox may require permission to bind the local test listener.

## Generated session fixtures

| Session        | Generated content/state                                                               | Screen assertions                                                                                             |
| -------------- | ------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| `ses_demo_001` | Rich Markdown, Unicode, reasoning/tool card, completed response, changed file         | S08 text selection/copy/source; S13 file preview; S14 usage; S15 diff                                         |
| `ses_demo_002` | Pending `per_demo` shell approval                                                     | S11 Once/Always/Reject and stale second reply                                                                 |
| `ses_demo_003` | Pending `frm_demo`, options/multiselect/boolean/conditions/integer/external reference | S12 typed answers, visibility/validation, external browser, already-settled recovery                          |
| `ses_demo_004` | Assistant retry state                                                                 | S08 retry presentation; generated timestamps are fixed, so use an injected demo clock for countdown snapshots |
| `ses_demo_005` | Failed execution/provider error                                                       | S08 terminal failure presentation, recoverable draft state                                                    |
| `ses_demo_006` | 120 generated chronological messages                                                  | S08 pagination, prepend position preservation, limits and duplicate prevention                                |
| `ses_demo_007` | Empty session                                                                         | Empty transcript and first-send flow                                                                          |
| `ses_demo_008` | Existing transcript available for queue tests                                         | Submit `resume:false,delivery:"queue"`, inspect/edit/cancel inbox                                             |

There are two projects, native-capable synthetic model/agent records, a connected MCP and an authentication-required MCP, plugin inventory/config JSONC, a real patch string, a valid tiny PNG and generated one-page PDF, generated text and a large text file. Agent/model names explicitly identify demo content.

Use `generate(seed=..., long_count=...)` in Python for stress fixtures; do not generate 10,000 real network messages just to test scrolling. The app should consume injected fixture snapshots through the same repository models. All fixture timestamps are synthetic; they are not current activity evidence. The network mock uses wall-clock timestamps for newly admitted work.

## Scenario controls — mock only

These `/__mock/*` URLs do not exist in OpenCode and must be excluded from the production adapter. Controls are not advertised as server capabilities.

| Request                                                        | Effect                                                                                                                        |
| -------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `GET /__mock/status`                                           | Scenario, recent redacted operation/status list, recent generated events, and modelled operation IDs                          |
| `POST /__mock/reset` with `{}`                                 | Recreate seed data, discard synthetic codes/state, close streams; running generation threads stop through generation identity |
| `POST /__mock/scenario` with `{name}`                          | Set the next prompt scenario listed below                                                                                     |
| `POST /__mock/latency` with `{milliseconds:0..5000}`           | Add request latency for loading/cancellation tests                                                                            |
| `POST /__mock/disconnect` with `{}`                            | Close live SSE subscriptions; subsequent connections open a fresh non-replaying stream                                        |
| `POST /__mock/password` with `{password}`                      | Rotate synthetic password; existing tokens fail authorization                                                                 |
| `POST /__mock/emit` with `{type:"rpc.demo.<name>",data:{...}}` | Inject a synthetic extension event for forward-compatibility handling                                                         |

Example:

```sh
curl -H 'X-Mock-Control: mock-control' -H 'Content-Type: application/json' \
  -d '{"name":"approval"}' http://127.0.0.1:4097/__mock/scenario
curl -u opencode:mock-password -H 'Content-Type: application/json' \
  -d '{"id":"msg_demo_request","text":"Run the generated workflow"}' \
  http://127.0.0.1:4097/api/session/ses_demo_007/prompt
```

| Scenario               | State transitions / expected app behavior                                                                                          |
| ---------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| `normal`               | Admit prompt → execution/step start → reasoning/text chunks → ended/full-value boundaries → succeeded/idle; one completed response |
| `approval`             | Admit/start → permission.asked → wait for exact session/request reply; stale repeat becomes 404                                    |
| `question`             | Admit/start → form.created → wait; invalid answer stays pending, valid answer settles, stale second answer becomes 409             |
| `failure`              | Stream representative content then terminal step/execution failure; no success notification                                        |
| `retry`                | Emit retry status, then continue; display retry without creating another user message                                              |
| `timeout-after-commit` | Admit input then close HTTP without acknowledgement; reconcile stable ID against inbox/message; do not resend                      |
| `duplicate-events`     | Repeat identical event IDs on delta frames; reducer must not append twice                                                          |
| `unknown-event`        | Inject `rpc.demo.future` during normal execution; unknown extension data must not crash the chat                                   |

Set `resume:false` to keep a prompt visibly in inbox and test cancellation/delivery edits deterministically. Queue-versus-steering scheduling boundaries are simplified by the mock and must also be tested against the real server.

## Contract and transport assertions

The dependency-free guard covers every assertion keyword occurring in the pinned snapshot. Its vocabulary check fails on an unrecognised future assertion; it is not a general-purpose JSON Schema implementation. Format/content annotations are not semantic validators. HTTP request JSON and declared path/query parameters are checked; query constraints expressed only in TypeScript handlers may require explicit additional checks. Successful JSON responses are checked against their operation/status schema. A mock response violating a schema produces a visible MockContractViolation rather than a normal success.

OpenAPI's event payload is an encoded JSON-string type, not the decoded union. The mock therefore has a separate explicitly limited event guard derived from pinned event/session/form/permission definitions; it does not claim schema coverage for every upstream event. Native tests must include unknown event types and decode frames split across arbitrary byte chunks.

Test fixture validity, authentication/challenge, one-time pairing, expiry/rotation, native response envelopes, cursor/type consistency, duplicate admission IDs, invalid input, file writes/read ranges/ETags, JSONC comments, plugin readback, runtime MCP distinction, stale approvals/forms, typed conditional answers, live streaming, and post-disconnect authoritative recovery. Unsupported baseline operations such as archive must never be made to succeed in the mock.

## Fidelity and limits

- All initial operation IDs have a synthetic handler, not all server semantics. The [route index](api-route-catalog.md) distinguishes modelled operations from unmodelled ones; unmodelled routes return explicit mock-only 501. Unknown routes return mock-only 404. These mock error tags are not production OpenCode DTOs.
- The mock does not execute commands/skills or model reasoning. Invocations produce synthetic conversation activity. Initial fixture tool cards exercise rendering; tool execution engines, real provider retries, full compaction projection, and permission-save persistence are not emulated. Compaction admits a representative inbox response; canonical compaction execution/events need real-server tests.
- Pending inbox work is simplified. Steering during an active provider/tool step, interrupted control items, rejected tool continuation, multi-agent drains, child ownership and session moves require real-server checks. `resume=true` interrupt semantics are not fully reproduced; the initial Stop action uses resume=false.
- Locations/projects derive from virtual paths; file listing/find/VCS responses are synthetic, and project filesystem permissions/symlinks/platform differences are not emulated. File-find directories, every query filter/subpath, full contextual diff generation and binary VCS are not complete. Diff fixtures do not recalculate from modified in-memory files. Context returns the fixture transcript rather than reproducing compaction boundaries.
- Raw files support representative single ranges/ETag handling, not complete HTTP conditional/precondition behavior. Last-Modified, If-Range and Content-Type detection differ from a real host. The mock has a 64 MiB request-body limit for test-process protection; it is explicitly not an OpenCode limit. Uploads are buffered by the mock, so mock memory figures are not upload-performance evidence.
- Prompt fixtures accept inline data and already-staged file URIs only; arbitrary HTTP attachment fetching, file conversion/media limits, and model-native/tool-access distinctions need native server tests. Protected plugin policy, discovery precedence, config watcher/reload ordering, `location[directory]` scoping on `/api/plugin` (the mock answers its own fixed inventory location regardless of the query), MCP processes/auth and runtime reconfiguration are simplified. A raw JSONC write is retained exactly, but the mock is not an implementation of the app's JSONC editor.
- Auth reproduces Basic/password/token and main pair flow. It is not a complete browser security reference: cross-origin cookie checks, every proxy-prefix case, service restarts and passwordless server behavior require real-host verification. The mock's cookie helper assumes its local port and is not an app authorization design.
- Events are live-only and have representative frames/heartbeats; there is no durable-log replay implementation. Duplicate and unknown events are intentional scenarios. Actual queue overflow framing, all event inventories and long-lived proxy behavior require real-server tests.
- App lock, Keychain, iCloud, camera/photo permissions, backup protection, multi-window ownership, native rendering/accessibility, background transfers, Local Push Connectivity entitlement and Live Activities need Swift/device tests. Passing Python tests is not evidence that these iOS features work.

## Native UI test matrix

Inject repositories/transport, clock and connection status at the app composition root. Production code cannot enable `/__mock/*`; a separate development/demo configuration selects mock endpoints or in-process fixtures. Native preview/unit tests should load generated JSON using the same DTO decoders as real responses.

| Test group         | Cases / pass condition                                                                                                                                            |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Navigation         | Every S01–S20 destination reachable; Back preserves origin/draft; host switching never mixes IDs; notification tap refetches pending state                        |
| Transcript         | Both-role Markdown, partial fences, Unicode/RTL, copy/select, external tap-to-load, source mode, long history and stable prepend                                  |
| Execution          | Working before text, retry timing, reasoning/tool phases, stop, stale disconnected state, duplicate event suppression, ended full-value replacement               |
| Writes/recovery    | Project folder succeeds/session fails, prompt admitted/response lost, already-settled interaction, concurrent config read/change/write; no automatic replay       |
| Files/changes      | Large file expansion, range reads, binary preview, missing file, session-turn versus workspace scope, diff context and null base                                  |
| Attachments        | File/photo/camera, cancellation, unsupported input, staged URI, balanced/original image, missing restored attachment, pending background upload without auto-send |
| Privacy/storage    | 30-day boundary using injected clock; cache budget eviction preserves drafts; backup exclusions and restoration; diagnostic redaction; no secrets in URLs/sync    |
| iPad/accessibility | Two scenes on different/same drafts, Edit Here handoff, process/window restoration, VoiceOver, large text, reduced motion, keyboard focus                         |
| Local delivery     | Signed physical-device eligible Wi-Fi, main app suspended/locked, first unlock after reboot, VPN loss, token expiry/rotation, follow scope/dedup, stale activity  |

Release requires testing against actual OpenCode macOS/Linux hosts and signed iOS devices, then recording results per workflow. The mock supplies reproducible development coverage; it cannot close external entitlement or platform-runtime gates.

Native manager/provider tests should follow the [Home Assistant-derived local-push acceptance cases](local-push-implementation.md#implementation-sequence-and-acceptance), including preference-save/reload errors, stale manager recovery, overlapping updates, old-generation callbacks, stream loss and status freshness. Existing Python scenarios cover the event/feed side; they do not implement or prove those Apple lifecycle behaviors.
