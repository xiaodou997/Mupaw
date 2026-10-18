# Mupaw

[![License: PolyForm Noncommercial 1.0.0](https://img.shields.io/badge/license-PolyForm%20Noncommercial%201.0.0-5b5b5b.svg)](LICENSE)

Mupaw is a source-available native macOS 26+ screenshot and screen-recording application designed for both people and Agents.

Mupaw currently includes the M0 foundation and the M1a screenshot-mode layer:

- explicit full-screen, window, and region PNG capture;
- a native AppKit region-selection overlay with cancellation and multi-display selection;
- a structured Agent region contract that does not simulate UI clicks;
- Retina-aware, bounded multi-display region planning and composition;
- global shortcuts for full screen, frontmost window, and region selection;
- ScreenCaptureKit source discovery and a single application-owned capture service;
- a local authenticated RPC bridge and MCP stdio server using the same capture path;
- English and Simplified Chinese localization from the first version;
- deterministic project files, tests, and local validation commands.

Long scrolling screenshots, annotations, OCR, visual styling, audio/video recording, camera overlay, GIF export, click highlights, keystroke display, and automatic zoom remain planned. They are not part of M1a.

## Screenshot modes

The app provides three explicit modes:

- **Full Screen** captures an exact display returned by ScreenCaptureKit. Mupaw windows are excluded by default.
- **Window** captures an exact independent window returned by source discovery.
- **Region** lets a person drag across one or more displays, or lets an Agent provide a structured rectangle.

Default global shortcuts are:

```text
Control + Option + Command + 1   Full screen under the pointer
Control + Option + Command + 2   Frontmost eligible window
Control + Option + Command + 3   Interactive region selection
```

Shortcut conflicts are shown in the app and can be retried. Interactive region selection can be cancelled with `Esc` or a right-click and creates no artifact when cancelled.

Agent region coordinates use the stable `global_display_points` coordinate space: macOS global display coordinates measured in points, with a top-left origin. `mupaw_sources_list` returns global frames and point-to-pixel scales for displays and windows.

## Requirements

- macOS 26 or later
- Xcode 27 or later for the current development environment
- XcodeGen

## Build

```bash
make generate
make localization-check
make lint
make build
make test
```

Install the signed development app at a stable path and open it:

```bash
make run
```

The stable development path is:

```text
~/Applications/Mupaw.app
```

macOS privacy permissions are tied to the app's code identity. The default local build is ad-hoc signed, so replacing it can require granting Screen & System Audio Recording permission again. To keep a stable identity, copy `.mupaw.local.mk.example` to `.mupaw.local.mk` and set an Apple Development or Developer ID Application identity available in your keychain:

```make
DEV_CODE_SIGN_IDENTITY := Apple Development: Your Name (TEAMID)
```

The local signing file is ignored by Git. Configure the identity before granting screen-recording permission for the most stable development workflow.

Open the macOS Screen & System Audio Recording settings pane:

```bash
make open-screen-recording-settings
```

Validate the MCP executable without requiring the app to be open:

```bash
make mcp-smoke
```

After Mupaw is running, validate the live app bridge as well:

```bash
make mcp-smoke-running
```

After granting Screen & System Audio Recording permission, run real MCP window and structured-region captures and validate their files, hashes, metadata, and previews:

```bash
make mcp-smoke-capture
```

A full-screen MCP smoke test is intentionally separate because it captures the current display. Cover the display with non-sensitive test content before running it:

```bash
make mcp-smoke-full-screen
```

Exercise MCP argument failures and recovery, then exercise the authenticated loopback RPC directly with invalid tokens, unknown methods, malformed JSON, oversized frames, disconnects, and concurrent calls:

```bash
make mcp-negative-smoke
make rpc-negative-smoke
```

Run the complete M1a non-full-screen acceptance sequence. It checks formatting and localization, runs all unit tests, rebuilds and restarts the stably signed development app, performs negative RPC/MCP checks, and validates real window and structured-region captures:

```bash
make m1a-acceptance
```

`make m1a-acceptance` expects the stable signing identity in `.mupaw.local.mk` and Screen & System Audio Recording permission to have been granted to `~/Applications/Mupaw.app`. The historical M0-only gate remains available as `make m0-acceptance`.

To validate UI/MCP conflict handling, begin an interactive region selection and, before completing it, run:

```bash
make mcp-capture-conflict-smoke
```

The MCP request must return `capture_in_progress`; cancel the overlay with `Esc` afterward.

Open the generated project when UI debugging is needed:

```bash
open Mupaw.xcodeproj
```

## Localization

The first version ships with English (`en`) and Simplified Chinese (`zh-Hans`). Mupaw follows the language selected by macOS, including the per-application language override in System Settings. UI strings and privacy usage descriptions are localized; MCP tool names and protocol identifiers remain stable English identifiers.

Run `make localization-check` after changing translations. It verifies that both languages contain the same keys and that required privacy descriptions are present. See `docs/LOCALIZATION.md` for the extension workflow.

## Repository layout

- `Sources/MupawCore`: shared capture geometry, models, bounded RPC codec, storage paths, and client code
- `Sources/MupawCapture`: ScreenCaptureKit source, full-screen/window/region capture, composition, and permission services
- `Sources/MupawApp`: native macOS UI, region overlay, global shortcuts, and local RPC server
- `Sources/MupawMCP`: MCP stdio bridge for Agent clients
- `Resources/MupawApp`: localized UI and Info.plist resources
- `Tests`: deterministic unit tests
- `scripts`: reproducible localization, MCP, raw RPC, and real-capture smoke tests
- `docs`: architecture, localization, MCP contract, and milestone acceptance criteria

## Licensing

Mupaw is source-available under the [PolyForm Noncommercial License 1.0.0](LICENSE), identified by SPDX as `PolyForm-Noncommercial-1.0.0`.

You may inspect, use, modify, and redistribute Mupaw only for purposes permitted by `LICENSE`. The public license does not grant commercial-use rights. Commercial use requires separate written permission from the copyright holder, and Mupaw does not currently offer a commercial license.

PolyForm Noncommercial is not an OSI-approved open-source license, so Mupaw must be described as **source-available**, not open source. Copies and distributions must preserve the `Required Notice:` line in `LICENSE`. Third-party dependencies retain their own license terms.

See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution and copyright rules.
