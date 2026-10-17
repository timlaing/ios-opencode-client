# Native OpenCode API contract

## Authority, scope, and generated artefacts

Use the vendored [OpenAPI 3.1 snapshot](../contracts/opencode-v2.0.25.openapi.json) from OpenCode v2.0.25, commit `b44eea9e204024db2b480a136ece29d790d5f593`. It defines 141 operations and 256 component schemas, including exact parameter names, union variants, body fields, response envelopes, and status codes. Its `info.version` is `0.0.1`, the API document version, not the OpenCode release. The [source manifest](../contracts/source-manifest.json) records provenance and SHA-256. Preserve [upstream MIT notices](../contracts/UPSTREAM-LICENSE).

The [full route index](api-route-catalog.md) and [machine-readable route catalog](../contracts/route-catalog.json) are generated from that snapshot. [Mobile scope](../contracts/mobile-scope.json) maps every initial workflow to operations and screen IDs. Unassigned operations are outside current mobile scope, not automatically promised later functionality.

This is an implementation contract derived from pinned source, not a claim of live-server equivalence. The mock behavior is tested against this contract and has explicit limits. A server upgrade requires a new snapshot, contract comparison, fixture updates, and host/device verification.

## Transport and decoding rules

- Use the user-reviewed HTTPS host origin over the configured VPN. Use existing pairing/password authentication, documented below. No companion plugin is required for these routes.
- Use JSON UTF-8 for JSON requests and accept JSON for normal responses. Binary file routes use raw bytes. SSE is a separate long-lived response. Percent-encode path components and query values independently; encode file-path segments without accidentally treating `#`, `?`, spaces, or Unicode as URL syntax.
- Location-scoped calls encode `location[directory]=/absolute/project/path` as a deep-object query, normally `location%5Bdirectory%5D=%2Fabsolute%2Fproject%2Fpath`. Do not send a JSON-string `location`, a V1 directory header, or a session location query on routes that do not declare one. Session routes resolve placement from the session ID.
- Preserve native response shapes. `project.list` and `config.get` return arrays directly; `location.get` returns its object directly; most session mutations/reads return `{data: ...}` or 204; location-scoped inventories usually return `{location: {directory}, data: ...}`. There is no universal response envelope.
- The generated document has `security: []` even on protected routes; runtime authorization middleware is authoritative. Attach `Authorization: Basic <base64(opencode:credential)>` to authenticated requests. Do not infer anonymous access from this OpenAPI security annotation.
- Store server IDs as opaque strings and timestamps as epoch milliseconds where the schema says number; do not parse IDs to infer chronology. `Session.Info.id` begins with `ses`; message IDs begin with `msg_`; form IDs with `frm_`; permission IDs with `per`. Use actual server ordering/cursors.
- Decode tagged message/content unions, optional fields, and null only where permitted. Ignore unknown object keys for forward-compatible reads and preserve unknown metadata. Never ignore an unknown mutation response and assume success. Unknown content/event types get a readable generic presentation or trigger targeted refresh, not a crash.
- A 204 has no JSON body. A JSON error uses `_tag`, `message`, and tag-specific fields. Binary `304` and `416` are not JSON-error envelopes. Do not force every error response through one successful-response model.

## W01: Pairing and host connection — S02/S03

| Step | Native operation | Request and response |
| --- | --- | --- |
| Generate on already-authenticated host | `POST /api/pair` (`server.pair`) | No JSON body. Returns `{code, expires_in}`. Existing `opencode pair` invokes it and prints links/QR; the unpaired phone does not need permission to issue a code |
| Parse existing link/QR | Local parser | `/auth/connect/<code>` URL or existing JSON `{code, urls:[...]}`; no new QR schema |
| Redeem | `GET /auth/connect/{code}` (`server.connect`) | `Accept: application/json`; returns `{token}`. No prior Basic credential. HTML navigation instead sets a cookie and redirects |
| Verify and save | `GET /api/info` (`server.info`) | Basic credential is returned token or manually entered password; response `{version,pid,urls,paths:{tmp},capabilities?}` |

Pair codes are one-use, five-minute codes in this release. Token lifetime is 30 days. Rotating the host password revokes existing signed tokens; there is no independently verified per-device revoke/refresh API. Store the token in Keychain, never iCloud settings. A failed health check after redemption must reuse the token; consuming the code again is not a valid retry. Keep expired/spent links distinct from unreachable hosts. Follow web multi-address behavior within the agreed HTTPS/VPN trust policy; never replay credentials onto an unreviewed origin.

Authentication errors pause writes and open native re-pair/password entry. Restoring credentials must not resend a prompt or approval automatically.

## W02: Open/create projects — S04/S05/S06

1. `GET /api/project` lists `Project` objects with `id`, `canonical`, `time`, `sandboxes`, and optional name/VCS/icon. The API canonical path is not a ChatGPT cloud project ID.
2. `GET /api/location?location[directory]=...` resolves the selected existing directory into `{directory, project:{id,directory,canonical}}`. Store this resolved identity with the host UUID.
3. Browse parent/sibling folders with `GET /api/fs/list?...&path=<absolute-or-relative-path>`; entries are `{path,type:"file"|"directory"}` with paths relative to the selected location. `GET /api/fs/find?...&query=...&type=file|directory&limit=...` is file/directory name discovery, not a full-text source-search API.
4. For a new folder, resolve an existing parent location, list/check the target, and preview the exact destination and initial configuration. `POST /api/experimental/fs/write?location[directory]=<existing-parent>&path=<absolute-target>/opencode.jsonc` with raw `application/octet-stream` bytes writes an empty valid JSONC object such as `{}` and creates missing parents. There is no `POST /api/project` or mkdir endpoint in this baseline.
5. Re-resolve the new location and then create the session. Do not initialise Git, clone a repository, or execute shell commands implicitly. Those remain separate later workflows.

Check for an existing target/configuration before writing; offer Open Existing rather than overwriting. There is no verified atomic create-if-absent guarantee, so explain a detected race rather than inventing one. If session creation fails after the folder/config file was created, report the created path and offer retry/open; no filesystem-delete rollback endpoint exists in the pinned contract. `PATCH /api/project/{projectID}` updates supported metadata; it does not create the directory.

## W03/W04: Sessions and history — S07/S08

| Action | Operation | Exact behavior |
| --- | --- | --- |
| List/search | `GET /api/session` (`session.list`) | Optional `directory`, `project`, `subpath`, `search`, `parentID`, `limit`, `order`, `cursor`; do not combine incompatible filter scopes. `parentID=null` filters root sessions. Response `{data:[Session.Info],cursor:{previous?,next?}}` |
| Create | `POST /api/session` (`session.create`) | `{id?,title?,agent?,model?,location?:{directory},metadata?,permissions?,parentID?}` → `{data:Session.Info}` |
| Read | `GET /api/session/{sessionID}` (`session.get`) | `{data:Session.Info}` with model/agent, cumulative cost/tokens, outcome, time, location |
| Rename | `PATCH /api/session/{sessionID}` (`session.update`) | `{title}` → 204. Metadata/permissions may be patched only deliberately, preserving unrelated metadata |
| Delete | `DELETE /api/session/{sessionID}` (`session.remove`) | 204; includes children. Explicit confirmation names the session and child impact |
| Unread state | `POST /api/session/{sessionID}/view` (`session.view`) | `{idle:<observed-idle-epoch-ms>}` → 204. Do not substitute the current phone time |
| Active sessions | `GET /api/session/active` (`session.active`) | `{data:{[sessionID]:{type:"running"}}}`; absence means not actively drained by this server process, not proof of successful completion |
| History page | `GET /api/session/{sessionID}/message` (`session.message.list`) | `limit` 1..200, first-page `order=asc|desc`, optional type filter; response `{data:[Session.Message.Info],cursor:{previous?,next?}}` |
| One message | `GET /api/session/{sessionID}/message/{messageID}` | `{data:Session.Message.Info}` |
| Active model context | `GET /api/session/{sessionID}/context` (`session.context`) | `{data:[messages after last compaction]}`; distinct from full paged transcript |

Default mobile list/page size is 50. Consume cursors as opaque values. History explicitly forbids combining cursor and order; preserve the type filter when paging. Avoid duplicating overlapping records across refreshes/pages. The mock's cursor contents are synthetic and must not be decoded by the app.

`Session.Message.Info` is a type union, not a V1 role/parts object. It includes `user`, `assistant`, agent/model/location switches, synthetic/system/skill/shell entries, compaction, and idle markers. User Markdown is `text`. Assistant `content` is an ordered array of `text`, `reasoning`, and `tool` items. Tools have `id`, `name`, `time`, and state `streaming|running|completed|error`. Terminal tool content is structured content; retain errors and metadata. Keep hidden bookkeeping records for state even when they are not rendered as chat bubbles.

**Confirmed gap:** the pinned web controller's Archive action rejects with “Session archiving is unavailable”; there is no archive/restore operation in this snapshot. Disable Archive/Restore with a capability explanation. Optional Hide on This Device is clearly labelled local and reversible; it must not masquerade as server archiving. Pin/unpin and follow/unfollow are app-local host/session preferences. Read pre-existing `time.archived` if supplied but do not invent a write to it.

## W05: Prompt, inbox, steering, stopping — S08/S09

Create a stable client message ID before submission and preserve it through reconciliation. The schema accepts `msg_<UUID>`; the exact opaque ID should be used when checking for admission. No custom Idempotency-Key header is assumed.

```http
POST /api/session/ses_example/prompt
Content-Type: application/json
Authorization: Basic <credential>

{"id":"msg_example","text":"Review **these changes**","delivery":"steer","resume":true}
```

`session.prompt` returns `{data:Session.Inbox.User}` after durable admission, not a completed assistant answer. Prompt fields are `id?`, `text` (required), `files?`, `agents?`, `skills?`, `metadata?`, `delivery?:"steer"|"queue"`, `resume?`. Model/agent selection uses its own operations, not invented prompt fields. Default delivery follows the server; an explicit mobile choice uses the two native values.

- `GET /api/session/{sessionID}/inbox` lists admitted work not yet delivered, including user, synthetic, compaction, and move items.
- `PATCH /api/session/{sessionID}/inbox/{inboxID}` with `{delivery:"steer"|"queue"}` updates pending delivery. `DELETE` cancels a not-yet-delivered item; an unavailable item is a no-op.
- `POST /api/session/{sessionID}/interrupt?resume=false` stops active execution and returns `{interrupted:boolean}`. Do not equate false with a failed request. `resume=true` has specific control/steering behavior; use only for an explicit matching control, not the ordinary Stop button.
- Follow execution through events and authoritative reads. On timeout/disconnect after submission, search inbox and projected message by the stable message ID before offering retry. A 409 is reconciled, not blindly retried. No exactly-once delivery guarantee is added by the app.
- Disconnected Send preserves a draft and requires manual Send after reconnection. This is independent of the server's connected-session queue.

## W06/W07: Models, agents, skills, commands — S10

`GET /api/model` returns a location-wrapped model list; `/api/model/default` returns the location-wrapped default when available. Use `Model.Ref = {id,providerID,variant?}`, not `modelID` as the selection field. Input capabilities in the native `Model.Info` are arrays such as `["text","image","pdf"]`; map these to UI booleans explicitly. Use `enabled`, variants, context/output limits, and pricing from the supplied model, with unknowns represented as unknowns.

`GET /api/agent`, and `GET /api/agent/{agentID}`, return location-wrapped agent information. Offer visible primary/all agents; show Plan/Build only if the host actually exposes them. `POST /api/session/{sessionID}/agent` with `{agent:<id>}` and `/model` with `{model:Model.Ref}` affect subsequent turns and return 204. For a new session, submit the chosen agent/model in session.create.

`GET /api/skill` and `/api/command` discover available actions. Invoke a command with `POST /api/session/{sessionID}/command`, `{name,text,files?,agents?,skills?,delivery?}`. Activate a skill with `POST /api/experimental/session/{sessionID}/skill`, `{id,resume?}`. Never infer that a discovered skill or command can be installed/edited through these routes. Command/template management and arbitrary shell/terminal controls remain later scope.

## W08/W11: Attachments and files — S09/S13

Follow the web routing rule: supported native images/PDFs up to the client's 20 MiB inline threshold use a data URI; other/larger content is staged on the host and referenced by file URI. This threshold is not a general upload cap. The `PromptInput.FileAttachment` request is `{uri,name?,description?,mention?}`. The projected user message uses the different `Prompt.FileAttachment` shape with base64 `data`, `mime`, and `source`; do not reuse one DTO for both.

```json
{"text":"Explain this image","files":[{"uri":"data:image/png;base64,<bytes>","name":"diagram.png"}]}
```

For staging, obtain `paths.tmp` from `/api/info`, choose a unique upload directory, and send raw bytes to `POST /api/experimental/fs/write?location[directory]=...&path=<tmp>/uploads/<UUID>/<filename>`. Response is `{location,data:{path:<resolved-absolute-path>}}`. Use that returned path to construct a properly escaped `file:` URI in the prompt. Do not send an iOS sandbox URL as a host reference. Preserve progress, cancel/retry, pending state, and failed-draft attachment references.

`GET /api/fs/read/*` reads a file path relative to the chosen location (with properly encoded segments) and streams bytes. Its handler supports ETag/If-None-Match, Last-Modified, one HTTP byte range, 206/304/416. Invalid/multiple ranges fall back to 200. Do not assume multipart ranges, resumable writes, atomic writes, or project-directory confinement on the write endpoint. File listing may navigate outside the current directory; the UI's tree is not server authorization.

## W09/W10: Permissions and forms — S11/S12

- Reconcile pending permissions with `GET /api/session/{sessionID}/permission` or location-wide `/api/permission/request`; re-read one through `/api/session/{sessionID}/permission/{requestID}` before acting after a notification/reconnect.
- Reply with `POST .../{requestID}/reply`, `{decision:"once"|"always"|"reject",message?}` → 204. Present Always only with the host's actual save scope; never rename it “Allow everything.” On a stale 404, refresh and show Answered Elsewhere/No Longer Pending rather than successful local approval.
- Forms use `GET /api/session/{sessionID}/form`, `/api/session/{sessionID}/form/{formID}`, and location-wide `/api/form`. Detail includes `state` pending/answered/cancelled. `Form.Info.sessionID` is a string; the schema permits a non-session MCP owner sentinel, so do not enforce a `ses` prefix universally. Initial ordinary session forms use their actual owner; do not invent routing for later global auth flows.
- `POST .../{formID}/reply`, `{answer:{<field-key>:<typed-value>}}` → 204. `DELETE .../{formID}?message=...` cancels a form. Handle 400 FormInvalidAnswerError, 409 FormAlreadySettledError, and 404 FormNotFoundError distinctly.
- Render string/options/custom, number, integer, boolean, multiselect, and external fields. Preserve field keys. Apply required/hidden/when, numeric bounds, lengths/patterns, and selection bounds; `when` is an AND list referencing earlier fields. For multiselect comparisons, equality means inclusion. Inactive fields are omitted, not submitted with stale values. External fields open the system browser and are not answer values. Unsupported validation formats must still let the server return an accurate error rather than falsely claiming local validation covers everything.

## W12/W13: Changes, usage, compaction — S14/S15

- Session turn changes: `GET /api/session/{sessionID}/diff?from=<user-message-id>&to=<optional-later-user-id>&context=3`. Omit from for newest user turn; omit to for one turn; omit context for full-file patches. A turn includes steering prompts until next idle; this is not necessarily one prompt. A location-spanning range is invalid. Response `{data:[{file,patch,additions,deletions,status}]}`.
- Workspace changes: `/api/vcs`, `/api/vcs/status`, `/api/vcs/base`, and `/api/vcs/diff?location[directory]=...&mode=working|branch|committed&base=...&context=3`. Location wrapper applies. Show session/workspace scope explicitly; do not imply a workspace diff belongs solely to the agent. A null/ambiguous base asks for explicit review base or shows the unavailable state; it is not an empty successful diff.
- Context: derive last-reported assistant step usage from message tokens plus selected model context limit. Token fields are input/output/reasoning/cache.read/cache.write. Session.Info cost/tokens are cumulative, distinct from last-step context. Label costs estimated and limits unknown when absent. Never fabricate live context utilisation between reports.
- Manual compaction: `POST /api/session/{sessionID}/compact`, `{id?,delivery?}` → `{data:Session.Inbox.Compaction}`. Admission is not completion. Observe compaction events and refresh context/history; preserve the full transcript.

## W14/W15: Plugin/MCP controls — S16

`GET /api/config` returns ordered configuration entries from low to high precedence. Document entries have `{type:"document",path?,info}`; directory discoveries have `{type:"directory",path}`. Show effective inventory from `/api/plugin` and `/api/mcp` alongside source/scope and pending/error state. Do not infer a disabled plugin from its absence in runtime inventory alone: combine declared directives and discovered/runtime sources.

For a project plugin toggle, identify the project JSONC document, read its raw bytes, parse/edit only the ordered `plugins` directives, preserve comments/options/unrelated keys, compare the latest read, then write bytes through `experimental.fs.write`. Negative strings such as `-demo.audit` remove a plugin; enabling must remove the relevant negative directive and preserve a recoverable positive target/options. Protected/built-in policy plugins may not be disabled. Verify runtime inventory after config.updated/reload and expose ineffective overrides. Use `/api/location/reload` only when its server-supported reload is needed, not as an unverified per-plugin endpoint.

`PATCH /api/experimental/config` accepts only `{shell:string|null}` in this baseline. It is not a plugin/MCP patch API. No plugin enable/disable route is invented. The pinned global-config web query has a placeholder; the native config contract and raw document path are the explicit solution, with race limits documented.

MCP connect/disconnect is `POST /api/experimental/mcp/{server}/connect|disconnect` with location query, returning 204. These are runtime controls, with statuses connected/pending/disabled/failed/needs_auth. Show “Connect/Disconnect for this runtime,” not an invented persisted enabled flag. Persistent MCP editing/add/remove/authentication remain later scope as already selected. If sign-in is required, show that state and the current supported setup path rather than a nonfunctional success toggle.

## W16: Events and reconciliation — S08/S17

`GET /api/event` is a volatile SSE stream covering all locations. Actual frames are `data: <JSON-object>\n\n`; there is no required SSE `event:` or `id:` line. The opening server.connected object has `{id,type,data:{}}`; other native events normally carry `id`, `created`, `type`, `data`, optional location/metadata, and a durable envelope on durable events. A heartbeat is `: heartbeat\n\n` approximately every 15 seconds. Ignore comments; handle UTF-8 and frames split across transport chunks.

| Event family | Data needed by native reducers | UI/reconciliation |
| --- | --- | --- |
| `server.connected` | Empty data | Refresh active/visible/followed locations and sessions; never assume replay |
| `session.execution.started/succeeded/failed/interrupted` | sessionID; error/reason where defined | Working/completed/failed/stopped state; canonical notification transitions |
| `session.step.started/streamed/ended/failed` | sessionID, assistantMessageID; agent/model/start or usage/finish/error | Provider phase and last-step usage; refresh affected message |
| `session.text.started/delta/ended` | sessionID, assistantMessageID, ordinal; delta/text | Incremental text keyed by message/ordinal; ended full value replaces accumulated text |
| `session.reasoning.started/delta/ended` | Same keys; delta/text | Thinking phase; show only reasoning actually exposed by the server |
| `session.tool.input.*`, `session.tool.called/progress/success/failed` | sessionID, assistantMessageID, tool ID; input/content/metadata/error | Tool cards; success/failure boundaries are authoritative; preserve unknown content |
| `session.inbox.enqueued/delivered/cancelled/delivery.changed` | sessionID, inboxID; item/delivery where defined | Queue/steering chips and reconcile inbox |
| `session.status` | sessionID, status idle/busy/retry with attempt/message/next | Working/retry indicator; do not treat transport disconnect as completion |
| `permission.asked/replied` | Request fields / sessionID, requestID, reply | Pending dock and stale-answer reconciliation |
| `form.created/replied/cancelled` | form / id, sessionID, answer | Question dock and settled detail |
| `session.compaction.*`, `session.usage.updated` | Session-scoped native payload | Compaction state and usage refresh |
| `config.updated`, plugin/MCP/model/agent changes | Definition-specific data | Refresh inventories/configuration; tolerate unknown extensions |
| `rpc.*` | Plugin data plus location | Capability-scoped generic handling; never execute arbitrary payload instructions |

Durable events include `{aggregateID,seq,version}` under `durable`; `seq` is per aggregate, not a global stream cursor. The global stream does not implement replay through Last-Event-ID. Slow consumers can overflow and lose the stream. Reconnect by fetching state, not replaying writes. An experimental session log with `after`/`follow` exists in the full catalog, but using it is not required for the initial app's global-event reconciliation and it is not behaviorally modelled by this mock.

## Native repository interfaces

Use typed Swift structs generated/adapted from this snapshot behind protocols. Keep presentation independent of transport so the mock uses the same adapter as the real host. Suggested async operations:

```swift
protocol OpenCodeTransport: Sendable {
    func perform(_ request: APIRequest) async throws -> APIResponse
    func events() -> AsyncThrowingStream<OpenCodeEvent, Error>
}
// APIRequest carries a known operation ID, typed path/query/body and cancellation.
// APIResponse preserves status, headers and JSON/binary/no-content payload type.
```

Repositories expose the operations in mobile-scope.json rather than one giant untyped “call endpoint” interface to views. Scope every cache/draft/subscription by local host UUID + resolved project/location + server session ID. Keep binary reads/uploads, JSON DTOs, and SSE decoding separate. Mutations go through per-target coordination; permission/form pending state is refetched before resolving an uncertain action.

## Required acceptance flows

W01–W17 map to the initial screens and mock routes. Test create/open project → create session → attach → prompt → stream → approval/form → changes/context → plugin/MCP control → reconnect. Assert no duplicated prompt, approval, draft, or notification across scene changes and reconnect. Later W18–W20 do not become initial scope simply because their APIs are available.

Source verification and fixture/HTTP tests are recorded separately from real-host and signed-device verification. See [testing and mock guide](testing-mock.md) for repeatable commands, scenarios, and known fidelity differences.
