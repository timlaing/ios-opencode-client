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

A native iPhone and iPad client for working with your own OpenCode hosts, with an optional server plugin for APNs notifications. The app is completely free, with no ads, paid downloads, in-app purchases, or subscriptions.

## OpenCode Client

Connect to an OpenCode host, open a project, and continue your coding sessions from your phone or tablet. OpenCode runs on your host; the app provides the mobile interface.

- **Hosts and projects:** guided connection setup, manual host entry, pairing links and QR scanning, and password sign-in fallback.
- **Conversations:** create and resume sessions, compose messages, attach files and photos, and choose models and agents.
- **Session activity:** follow streamed responses and tool activity, answer questions, and respond to permission requests.
- **Files and changes:** browse project files and review changes alongside the conversation.
- **iPad workspace:** native layouts and support for multiple windows.
- **Local controls:** offline drafts, cache management, optional Face ID/Touch ID lock, and optional iCloud sync for appearance and host addresses. Credentials are entered separately on each device.

The app targets **iOS and iPadOS 18 or later** and connects directly to macOS or Linux OpenCode hosts over authenticated HTTPS, including through your VPN. You need your own reachable OpenCode host.

Diagnostics stay local until you review and explicitly share a redacted report. There are no automatic telemetry or crash uploads. External Markdown images load only after a tap, and offline drafts require manual sending after reconnection.

Foreground notifications and local Live Activities provide session updates. Live Activities show stale state when the app cannot update them. Background APNs delivery is a separate integration described below.

The repository contains the native app and its supporting Swift packages. Availability of a screen or implementation does not establish real-host compatibility or physical-device validation; see [verification and release evidence](docs/verification.md).

## OpenCode push-relay plugin

[opencode-push-relay](plugins/opencode-push-relay/README.md) is the optional companion plugin for an OpenCode server. It connects the host to an [APNs push relay](https://github.com/timlaing/apns-push-relay) to deliver alerts for completed or failed sessions, permission requests, and questions.

The plugin provides paired-device enrollment, notification preferences, a persistent delivery queue with retries, and commands for status, test alerts, and signing-key rotation. Core app operation is independent of the plugin and relay.

The plugin stays inactive until a relay URL and app identifier are configured. It has automated coverage and has been verified to load inertly in OpenCode v2.0.30. Live relay, APNs, and device delivery remain unverified. See the [plugin setup and compatibility guide](plugins/opencode-push-relay/README.md#loading-verified-against-opencode-v2030) before configuring it; project-level plugin options are not loaded by that OpenCode version.

## Build and develop

### iOS app

Use Xcode and XcodeGen on macOS. Generate the project from its checked-in specification:

```sh
cd OpenCodeRemote
xcodegen generate
open OpenCodeRemote.xcodeproj
```

Build and run the **OpenCodeRemote** scheme on an iPhone or iPad simulator, or a device with suitable signing. Edit `OpenCodeRemote/project.yml` for project configuration and regenerate the project.

Run the shared Swift package tests from the repository root:

```sh
swift test --package-path Packages/OpenCodeKit
```

Run app unit and UI tests through the OpenCodeRemote scheme on both an iPhone and an iPad destination.

### Reference mock

The dependency-free Python mock provides repeatable projects, sessions, attachments, events, and failure scenarios for client development. It requires Python 3.11 or later:

```sh
python3 -m mock.server --port 4097
```

The mock listens on loopback by default and executes no real tools, shell commands, or providers. Connection details, synthetic credentials, and device setup are in the [mock guide](docs/testing-mock.md).

To regenerate and validate the committed contracts and fixtures:

```sh
python3 -m mock.fixtures
python3 scripts/build_contracts.py
python3 -m unittest discover -s tests -v
```

### Server plugin

```sh
cd plugins/opencode-push-relay
npm install
npm run typecheck
npm run build
npm test
```

## Compatibility and verification

The client API contract is pinned to **OpenCode v2.0.25**, commit `b44eea9e204024db2b480a136ece29d790d5f593`. The plugin's verified loading version is separately documented above. Compatibility with other server versions requires validation.

The repository includes the pinned OpenAPI snapshot, workflow mappings, generated fixtures, and a synthetic reference mock. Passing mock tests proves mock behavior, not real-server fidelity. Archive and restore mutations are unsupported in the pinned API baseline. The [verification report](docs/verification.md) records checks and outstanding real-host and device evidence.

## Documentation

| Guide | Contents |
| --- | --- |
| [App features](docs/app-design.md) | Feature checklist and staged scope |
| [Screens and navigation](docs/navigation-screens.md) | Native screens, actions, and state handling |
| [Defaults and settings](docs/implementation-defaults.md) | Storage, privacy, security, sync, and user controls |
| [Notifications](docs/notifications.md) | Live Activities and remote push architecture |
| [API contract](docs/api-contract.md) | Workflows, payloads, events, errors, and baseline limitations |
| [API route catalog](docs/api-route-catalog.md) | Pinned operations, scope, and mock coverage |
| [Mock development](docs/testing-mock.md) | Fixtures, scenarios, test commands, and fidelity limits |
| [Verification](docs/verification.md) | Recorded checks and outstanding release evidence |
| [Implementation guide](docs/implementation-guide.md) | Integration boundaries and release criteria |
| [Implementation decisions](docs/implementation-decisions.md) | Engineering choices and verification dependencies |
| [Design review](docs/design-review.md) | Outstanding compatibility, accessibility, and release work |
| [Free app decision](docs/monetisation.md) | Free model and inactive earlier analysis |
| [Server plugin](plugins/opencode-push-relay/README.md) | Configuration, commands, enrollment, delivery, and loading compatibility |

## Contributing

Use the repository’s issue and pull request templates for contributions. See [SECURITY.md](SECURITY.md) for private vulnerability reporting. CI covers Python, the server plugin, the Swift package, and iPhone/iPad simulator tests. Publishing is managed through the repository’s release workflows.

## Support and licence

Use [GitHub issues](https://github.com/timlaing/ios-opencode-client/issues) for public bug reports and feature requests.

Original code is licensed under [MPL-2.0](LICENSE). The vendored OpenCode API snapshot retains its [upstream MIT licence](contracts/UPSTREAM-LICENSE).
