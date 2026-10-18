# OpenCode Client graphics

The selected direction takes inspiration from [OpenCode's official brand assets](https://opencode.ai/brand): strong rectangular geometry, square corners, and charcoal/stone tones. The offset client tile distinguishes this app's mark. OpenCode Client is an independent client, not an official OpenCode product.

## Deliverables

- `icon-light.png`: opaque 1024 × 1024 default app icon.
- `icon-dark.png`: opaque 1024 × 1024 dark app icon.
- `icon-tinted.png`: monochrome source for system tinting.
- `header.png`: promotional header artwork, not a screenshot of a running app or a guarantee of App Store featuring. Confirm requested placement dimensions before submission.
- `banner-2x1.png`: 1536 × 768 crop for wide promotional placements.
- `onboarding.png` / `onboarding-light.png`: transparent host-connection artwork. The welcome view inverts the same grayscale artwork in dark mode, preserving identical alpha edges and geometry across appearances. Empty areas reveal the native page background; no background colour matching is needed. The previous opaque version is preserved as `masters/onboarding-opaque-original.png`.
- `connect-background-light.png` / `connect-background-dark.png`: portrait connect-screen backgrounds with quiet central space for native fields. The `ConnectBackground` image asset selects the system appearance automatically.
- `prompts.json`: exact prompts and built-in image generation provenance for the icons, header, onboarding and tinted assets.
- `dark-refinement-prompt.txt`: recolour prompt that produced `icon-dark.png` from the final light icon.
- `onboarding-transparency-prompts.json`: alpha-extraction edit prompts for the transparent onboarding artwork.
- `connect-background-prompts.json`: prompts for the light and dark connect-screen backgrounds.

App icon files are connected to the existing Xcode asset catalog. Original-resolution generated artwork lives in `masters/`. Earlier terminal-based concepts are retained in `explorations/` and are not used by the catalog.

These are raster assets generated with the built-in image generation tool. Inspect final appearance on device before release; generated variants can have small geometric differences. No real-host or device behavior is established by this artwork.

## Interface icons

Use native SF Symbols for interface controls rather than rasterising them. This preserves Dynamic Type, weight, accessibility contrast, and appearance adaptation. Symbol availability must be checked against the deployment target when implementing views.

| Purpose                | SF Symbol                                            |
| ---------------------- | ---------------------------------------------------- |
| Projects / files       | `folder` / `doc.text`                                |
| Sessions / new session | `bubble.left.and.bubble.right` / `square.and.pencil` |
| Hosts / connect        | `server.rack` / `link`                               |
| Scan pairing code      | `qrcode.viewfinder`                                  |
| Changes / branch       | `arrow.triangle.branch`                              |
| Approvals              | `checkmark.shield`                                   |
| Attach / send / stop   | `paperclip` / `arrow.up` / `stop.fill`               |
| Notifications          | `bell`                                               |
| Settings               | `gearshape`                                          |
| Terminal / tools       | `terminal` / `wrench.and.screwdriver`                |

Give each control a text or accessibility label. Do not encode connection or approval state through colour alone.

## Connect background

Use `Image("ConnectBackground").resizable().scaledToFill()` inside a container that constrains and clips the image to the screen bounds. Let the background ignore safe areas; keep the actual form within safe areas and scrollable above the keyboard. Mark the background `.accessibilityHidden(true)`. Keep fields on a readable native material or solid surface instead of relying on image contrast. The portrait art can crop on iPad; keep form layout independent of the decorative image. This adds an appearance-aware asset, not a new connection screen implementation.
