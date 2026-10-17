# App design and feature checklist

## Goal

Provide a native mobile interface to OpenCode on the user's own macOS/Linux hosts. Preserve browser-client capabilities in staged releases, adapting navigation and interaction to the phone rather than reducing the product to chat.

The initial app connects directly to OpenCode. Local push is part of that release. An optional host plugin and Cloudflare Worker add remote push in a later release.

See [design gaps and release decisions](design-review.md) for outstanding implementation/security work. The selected commercial model is [completely free](monetisation.md): no advertising, purchases, or subscriptions. Earlier commercial options are inactive reference material.

## Feature coverage

An unchecked requirement below is planned, not implemented. Later-stage requirements remain part of the parity roadmap.

| Area | Initial release | Later parity work |
| --- | --- | --- |
| Hosts | Named hosts; HTTPS credentials; connection/version checks; visible status | Additional browser-supported connection workflows |
| Projects | Browse directories; open existing folders; create a project folder and initial configuration | Additional project administration |
| Sessions | Create, resume, title search, rename, local pin/follow/hide; host/project filters; show baseline archive limitation | Fork, export/import, revert; server archive/restore only when a supported contract exists |
| Conversation | Streaming; full history; drafts; copy; Markdown for both roles | Remaining browser conversation actions |
| Composer | Markdown source editing and preview; attachments; model/agent selection | Additional browser context controls |
| Execution | Stop; follow-ups; accurate steering/queue states; supported Plan/Build selection | Advanced browser execution controls |
| Thinking | Animated working/thinking state; elapsed time; retry/wait states | Additional diagnostics |
| Tools | Expand arguments, commands, outputs, failures, and affected files | Additional browser diagnostic views |
| Approvals | Allow/deny choices supported by the host; structured questions | Saved-permission administration |
| Attachments | Files, photo library, camera capture; multiple attachments; workspace references; preview/remove/cancel/retry | Additional browser attachment workflows |
| Files | Read-only native project tree; source/Markdown/image/PDF previews | Native editing and saving where practical |
| Changes | Changed files and unified diffs; distinguish session changes from workspace changes | Advanced review and revert workflows |
| Usage | Context indicator; token categories; estimated cost; compaction visibility | Additional usage/debug views |
| Plugins | Inventory; project enable/disable; effective status and errors | Install/remove and further configuration controls |
| MCP | Project connect/disconnect; effective status; authentication-required indication | Add/remove/configuration and full authentication workflows |
| Models/providers | Select configured host models and agents | Native provider setup/authentication |
| Skills/commands | Discover/invoke those exposed by the supported server | Remaining browser management controls |
| Git/workspaces | Branch/workspace identity | Browser-supported branch/worktree operations |
| Terminal | View agent command output | Interactive terminal in a native screen; web renderer permitted |
| Local push | Background completion/failure/approval/question alerts on configured Wi-Fi | Expanded delivery diagnostics |
| Live Activities | User-started activity; local updates; stale indicator | APNs updates/end while app is suspended |
| Remote push | Architecture documented; not required to use the app | Optional plugin + stateless Cloudflare Worker + APNs |
| Todos | Deferred | Separate future decision; absent from stock v2.0.25 |
| Voice | Deferred | Separate future decision |

Do not infer browser functionality from API endpoints or source-directory names alone. Maintain a parity matrix identifying each actual web action, source implementation, release stage, native/web destination, and verification status.

The [API contract](api-contract.md), [generated route catalog](api-route-catalog.md), and [S01–S20 navigation/screens](navigation-screens.md) now provide concrete initial bindings and state behavior. The pinned web controller explicitly reports archiving unavailable; do not infer an archive mutation from the read-only `time.archived` field.

## Navigation and native views

Use Projects, Sessions, and Settings as primary destinations. On iPad, use sidebar/detail navigation with optional adjacent file/change panels.

Host connection follows the existing OpenCode web flow in native views: scan its QR code or paste an `opencode pair` link, with manual address/password sign-in as the fallback. Reuse the server's session-token exchange rather than introducing app-specific host accounts or pairing codes.

The initial iPad release supports multiple app windows so different projects/sessions can remain open side by side. Keep navigation and restoration state per window, show host/project/session identity clearly, and coordinate shared session state and drafts across windows.

- **Projects:** group by host; New Project and Open Existing Folder actions; project settings.
- **Sessions:** pinned, running, needs-attention, and recent sessions; search and filters.
- **Session detail:** conversation, composer, tool activity, pending interactions, usage, Files, and Changes.
- **Settings:** guided host setup and connection checks, appearance, cache/privacy, optional Face ID/Touch ID app lock, local-push configuration/status, Live Activities, and local diagnostics with reviewed support exports. Future remote-push settings are separate.

Prefer native implementations for chat, project/session navigation, files, diffs, approvals, attachments, usage, and integration settings. Prefer native editing, provider setup, and workspace controls when those stages are implemented. Use WKWebView for specific complex panels only after documenting why a native view is unsuitable initially. An interactive terminal may use a web terminal renderer inside a native screen.

Keep host/project/workspace/session identity consistent between views. A fallback must preserve context and refresh native state after changes. Do not treat a general web wrapper as completion of the native requirement.

## New project flow

1. Select host and choose New Folder or Existing Folder.
2. Browse available parent directories and choose/enter a project directory.
3. Check whether the destination already exists; never overwrite existing project configuration as a creation shortcut.
4. For a new project, use the native file-write API to create its initial valid `opencode.jsonc`, which also creates missing parent directories.
5. Resolve/open the project location and offer Start First Session.

This uses an existing filesystem API, not a dedicated mkdir/project-create endpoint. Validate the flow against a disposable host project before claiming runtime support.

## Session interaction

```text
‹ Sessions    Project / Session title       Files · Changes · …
              Host · Branch · Connection

User Markdown
[Attachments]

Assistant Markdown
◉ Thinking / Working · elapsed time
▸ Tool activity
[Permission request or question]

────────────────────────────────────────────────────────────
Context used/limit · Estimated session cost
[+] Message…                                      [Send/Stop]
    Agent · Model · Integrations
```

- Use the same Markdown capabilities for both roles: headings, emphasis, links, lists, tables, task-list syntax, blockquotes, and fenced code. Task-list Markdown rendering is independent of the deferred agent todo feature.
- Preserve original Markdown source for copy/edit; provide composer source and preview modes.
- Render streaming/incomplete Markdown without dropping text or forcing scroll jumps. Provide Jump to Latest.
- Show Thinking only when the host exposes that state; otherwise use Working or Waiting for Model. Show only reasoning content actually provided by the host.
- Distinguish model generation, tool execution, retries, queued input, waiting for permission, waiting for an answer, idle, and disconnected states.
- Keep pending follow-ups visible according to the server's actual steer/queue semantics.

## Files, usage, and integrations

Render source with syntax highlighting, Markdown in rendered/source modes, and images/PDFs with native previews. A preview capability does not imply model ingestion support. Validate attachments against the selected model/server and explain unsupported formats before sending.

Label the context indicator as last-reported usage. In v2.0.25, the web client sums the latest assistant message's input, output, reasoning, cache-read, and cache-write tokens, divided by the model context limit. Separate this indicator from cumulative session token/cost totals. Unknown limits must remain unknown. Cost is calculated from model pricing and must be labelled estimated.

Plugin/MCP rows show configuration source/scope, requested state, actual state, pending operation, and error/authentication requirement. Native MCP connect/disconnect does not by itself establish persistence across restarts; verify that behavior separately from persistent configuration settings.

For persistent plugin changes, edit the appropriate project JSONC document using the existing filesystem API, preserve unrelated settings/comments, and verify the effective plugin list after reload. In v2.0.25 the configuration PATCH endpoint only updates the global shell setting. Protected policy plugins remain unavailable for disabling.

## Accessibility and review

Support VoiceOver, Dynamic Type, light/dark appearance, hardware keyboards, and reduced motion. Avoid colour-only statuses. Preserve reading position and unsent drafts across navigation/reconnect.

## Evidence

- [OpenCode v2.0.25 filesystem routes](https://github.com/anomalyco/opencode/blob/b44eea9e204024db2b480a136ece29d790d5f593/packages/protocol/src/groups/fs.ts)
- [Web context indicator](https://github.com/anomalyco/opencode/blob/b44eea9e204024db2b480a136ece29d790d5f593/packages/gui-extensions/src/context/indicator.tsx)
- [Web context detail](https://github.com/anomalyco/opencode/blob/b44eea9e204024db2b480a136ece29d790d5f593/packages/gui-extensions/src/context/tab.tsx)
- [Plugin directives](https://github.com/anomalyco/opencode/blob/b44eea9e204024db2b480a136ece29d790d5f593/packages/core/src/config/plugin/source.ts)
- [Configuration PATCH schema](https://github.com/anomalyco/opencode/blob/b44eea9e204024db2b480a136ece29d790d5f593/packages/schema/src/config.ts)
- [MCP web controls](https://github.com/anomalyco/opencode/blob/b44eea9e204024db2b480a136ece29d790d5f593/packages/app/src/providers/connect/mcp.ts)
