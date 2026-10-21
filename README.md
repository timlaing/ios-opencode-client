# OpenCode Client for iOS

[![License](https://img.shields.io/github/license/timlaing/ios-opencode-client)](LICENSE)

[![Lines of Code](https://sonarcloud.io/api/project_badges/measure?project=timlaing_ios-opencode-client&metric=ncloc)](https://sonarcloud.io/summary/new_code?id=timlaing_ios-opencode-client)
[![Duplicated Lines (%)](https://sonarcloud.io/api/project_badges/measure?project=timlaing_ios-opencode-client&metric=duplicated_lines_density)](https://sonarcloud.io/summary/new_code?id=timlaing_ios-opencode-client)
[![Coverage](https://sonarcloud.io/api/project_badges/measure?project=timlaing_ios-opencode-client&metric=coverage)](https://sonarcloud.io/summary/new_code?id=timlaing_ios-opencode-client)

[![Vulnerabilities](https://sonarcloud.io/api/project_badges/measure?project=timlaing_ios-opencode-client&metric=vulnerabilities)](https://sonarcloud.io/summary/new_code?id=timlaing_ios-opencode-client)
[![Security Rating](https://sonarcloud.io/api/project_badges/measure?project=timlaing_ios-opencode-client&metric=security_rating)](https://sonarcloud.io/summary/new_code?id=timlaing_ios-opencode-client)
[![Maintainability Rating](https://sonarcloud.io/api/project_badges/measure?project=timlaing_ios-opencode-client&metric=sqale_rating)](https://sonarcloud.io/summary/new_code?id=timlaing_ios-opencode-client)
[![Reliability Rating](https://sonarcloud.io/api/project_badges/measure?project=timlaing_ios-opencode-client&metric=reliability_rating)](https://sonarcloud.io/summary/new_code?id=timlaing_ios-opencode-client)
[![Quality Gate Status](https://sonarcloud.io/api/project_badges/measure?project=timlaing_ios-opencode-client&metric=alert_status)](https://sonarcloud.io/summary/new_code?id=timlaing_ios-opencode-client)
[![Code Smells](https://sonarcloud.io/api/project_badges/measure?project=timlaing_ios-opencode-client&metric=code_smells)](https://sonarcloud.io/summary/new_code?id=timlaing_ios-opencode-client)
[![Bugs](https://sonarcloud.io/api/project_badges/measure?project=timlaing_ios-opencode-client&metric=bugs)](https://sonarcloud.io/summary/new_code?id=timlaing_ios-opencode-client)
[![Technical Debt](https://sonarcloud.io/api/project_badges/measure?project=timlaing_ios-opencode-client&metric=sqale_index)](https://sonarcloud.io/summary/new_code?id=timlaing_ios-opencode-client)

Product design and implementation guide for a native iPhone/iPad client that preserves as much OpenCode web functionality as possible.

## Product decisions

- OpenCode web is the functional baseline. ChatGPT/Codex iOS is the interaction reference.
- Derive implementation behavior from existing web/server code wherever possible; retain explicit native UX and privacy choices, and record genuine gaps before designing alternatives.
- Deliver the fullest sensible functionality within the agreed staged scope, using documented defaults and useful user settings rather than removing capability to simplify implementation.
- Prefer native views. Embed web panels only where they preserve complex functionality that is impractical to reproduce initially.
- Connect directly to the user's OpenCode hosts over authenticated HTTPS through their VPN.
- Support macOS and Linux hosts; target iOS/iPadOS 18 initially.
- Local push notifications were removed by decision on 21 October 2026: no Local Push Connectivity extension, no entitlement request, foreground banners and Live Activities only.
- Include local Live Activities initially, with an honest stale-state display when the app cannot update them.
- Document an optional companion plugin and stateless Cloudflare Worker for a later release's APNs alerts and remote Live Activity updates.
- Keep core app operation independent of that plugin and Worker.
- Defer todo functionality and voice.
- The app is completely free: no ads, sponsorship placements, supporter purchases, paid downloads, or subscriptions.
- Provide guided host setup with instructions, connection checks, and troubleshooting.
- Offer an optional Face ID/Touch ID app lock.
- Keep diagnostics local; users review redacted reports before explicitly sharing them. No automatic telemetry or crash uploads.
- Cache the most recent 30 days of chat history with a Clear Cache control; host history is unaffected.
- Ask users to choose notification content privacy during onboarding.
- Load external Markdown images only after a tap.
- Exclude cached conversations and attachment copies from device/cloud backups.
- Show the current screen in the app switcher.
- Preserve offline drafts and require manual sending after reconnecting.
- Select MPL-2.0 for the app, future companion plugin, and Worker, subject to dependency compliance. Preserve notices and publish covered source for distributed releases; no mandatory resale royalties.
- Ask during onboarding which alert categories to enable and whether Live Activities start automatically or manually.
- Plan a shared hosted Worker relay for future remote push; operating costs and service limits remain to be defined.
- Offer optional iCloud sync for appearance and host addresses, with credentials entered separately on each device.
- Let users choose in Settings whether reopening restores the last screen/session or opens the project list.
- Support attachments from Files, the photo library, and camera capture.
- Keep drafts local to each device and open external chat links in the default system browser.
- Notify for sessions started from this app or explicitly followed; let users configure draft retention.
- Use GitHub issues for public support and a separate private route for security reports.
- Include unsent drafts in restoration backups; attachment copies remain excluded.
- Support manual host entry and QR scanning with documented QR generation.
- Reuse OpenCode's existing web authentication and pairing protocol: `opencode pair` links/QR codes, native token redemption, and password sign-in fallback.
- Treat unresolved shared-relay funding as a future remote-push launch blocker.
- Support multiple iPad windows in the initial release.
- Default to retaining drafts until sent or explicitly discarded; keep retention configurable.

## Documents

| Document                                                                              | Purpose                                                                                                                             |
| ------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| [App design and feature checklist](docs/app-design.md)                                | Review features, screens, native-view priorities, and staged web parity                                                             |
| [Notifications and Cloudflare Worker design](docs/notifications.md)                   | Live Activity limits and the future stateless APNs relay (local push removed 21 October 2026)                                       |
| [Implementation guide](docs/implementation-guide.md)                                  | Integration boundaries, build sequence, verification, and release criteria                                                          |
| [Remaining implementation decisions](docs/implementation-decisions.md)                | Web-derived solutions, native engineering choices, and separate verification dependencies                                           |
| [Implementation defaults and user controls](docs/implementation-defaults.md)          | Selected storage/rendering/security/sync defaults, complete interactions, resource budgets, and configurable preferences            |
| [Concrete API contract](docs/api-contract.md)                                         | Exact initial workflows, payloads, envelopes, event handling, errors, and known baseline gaps                                       |
| [Navigation and screen specification](docs/navigation-screens.md)                     | S01–S20 native screens, actions, layouts, navigation, restoration, and state handling                                               |
| [Generated route catalog](docs/api-route-catalog.md)                                  | All 141 pinned operations with initial/later scope and synthetic mock coverage                                                      |
| [Generated data and mock testing](docs/testing-mock.md)                               | Runnable reference mock, fixtures, scenarios, test commands, fidelity limits, and native acceptance cases                           |
| [Package verification](docs/verification.md)                                          | Passed contract/mock checks, reproducibility, and remaining real-host/device evidence                                               |
| [Design gaps and release decisions](docs/design-review.md)                            | Outstanding onboarding, security, compatibility, performance, and support work                                                      |
| [Free app decision and earlier monetisation analysis](docs/monetisation.md)           | Selected free model; earlier options retained as inactive reference                                                                 |

The commercial model is decided: completely free. Earlier monetisation analysis is reference material, not implementation scope. Future hosting costs still need an operating plan; no paid service has been authorised.

## Initial user journey

Select a host → create or open a project → create or resume a session → attach context → follow thinking/tool activity → answer questions or approvals → review files and changes.

Notifications while the main app is suspended were removed with local push (21 October 2026). What remains is honest foreground delivery: banners for turns that finish while the app is inactive but not yet suspended, and Live Activities that show their stale state when the app cannot update them.

## Version and evidence

The initial product decisions and routine implementation defaults are settled. The concrete API/workflow matrix, S01–S20 screen/state specifications, pinned OpenAPI snapshot, generated fixtures and runnable mock are now supplied as an implementation package. No routine initial-version preference questionnaire remains. Apple signing/team identifiers and live test hosts/devices are deployment inputs; real-host/physical-device evidence is the release gate. Future shared-relay decisions do not block the initial version.

The initial integration baseline is **OpenCode v2.0.25**, commit `b44eea9e204024db2b480a136ece29d790d5f593`, matching the user's reported version and installed package path. Relevant server and web-client source was inspected during design. Native server mutations and device delivery have not been tested against a running host.

Native app features remain requirements/designs; the Python mock, fixture generator, route catalog generator, and their tests are implemented. HTTP routes under the future Worker's `/v1/` namespace are proposed interfaces; they are not existing OpenCode endpoints. Archive/Restore is a confirmed unsupported mutation in the pinned web/API baseline, explicitly reflected in the screen/feature contracts.

## Start implementation

Read the API contract, screen specification, defaults, and mock guide together. `contracts/mobile-scope.json` is the machine-readable workflow/screen/operation map. Preserve the existing staged scope and explicit baseline limitations.

```sh
python3 -m mock.fixtures
python3 scripts/build_contracts.py
python3 -m unittest discover -s tests -v
python3 -m mock.server --port 4097
```

The mock uses generated data only, defaults to loopback, and never executes real tools/providers. Synthetic development credentials and HTTPS/device instructions are documented in the mock guide. The source snapshot retains its upstream MIT terms; original mock code is MPL-2.0.

## Key acceptance conditions

- Native views are the default. Every web fallback has a documented reason and an acceptance test.
- Reconnection does not duplicate prompts, configuration edits, or approvals.
- A server's API availability is distinguished from a feature being implemented in its web client and from verified mobile behavior.
- The Worker requires no device/session database. The optional plugin owns subscription, outbox, retry, and token state.
- Deferred parity work remains visible in the feature checklist. Todos remain explicitly deferred.
