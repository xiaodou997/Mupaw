# Mupaw

[![License: PolyForm Noncommercial 1.0.0](https://img.shields.io/badge/license-PolyForm%20Noncommercial%201.0.0-5b5b5b.svg)](LICENSE)

Mupaw is a source-available native macOS 26+ screenshot and screen-recording application designed for both people and Agents.

The first development milestone focuses on a reliable foundation:

- native SwiftUI/AppKit application shell;
- ScreenCaptureKit source discovery and still-image capture;
- a single application-owned capture service;
- a local authenticated RPC bridge;
- an MCP stdio server that exposes the same operations to Agents;
- English and Simplified Chinese localization from the first version;
- deterministic project files, tests, and local build commands.

Long scrolling screenshots, annotations, OCR, audio recording, camera overlay, GIF export, click highlights, keystroke display, and automatic zoom are planned on top of this foundation. They are intentionally not mixed into M0 before the capture and Agent control path is proven.

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

After granting Screen & System Audio Recording permission, run a real MCP screenshot and validate its file, hash, metadata, and image preview:

```bash
make mcp-smoke-capture
```

Exercise MCP argument failures and recovery, then exercise the authenticated loopback RPC directly with invalid tokens, unknown methods, malformed JSON, oversized frames, disconnects, and concurrent calls:

```bash
make mcp-negative-smoke
make rpc-negative-smoke
```

Run the complete M0 acceptance sequence. It checks formatting and localization, runs all unit tests, rebuilds and restarts the stably signed development app, waits for the bridge, performs negative RPC checks, and finishes with a real MCP screenshot:

```bash
make m0-acceptance
```

`make m0-acceptance` expects the stable signing identity in `.mupaw.local.mk` and Screen & System Audio Recording permission to have been granted to `~/Applications/Mupaw.app`.

Open the generated project when UI debugging is needed:

```bash
open Mupaw.xcodeproj
```

## Localization

The first version ships with English (`en`) and Simplified Chinese (`zh-Hans`). Mupaw follows the language selected by macOS, including the per-application language override in System Settings. UI strings and privacy usage descriptions are localized; MCP tool names and protocol identifiers remain stable English identifiers.

Run `make localization-check` after changing translations. It verifies that both languages contain the same keys and that required privacy descriptions are present. See `docs/LOCALIZATION.md` for the extension workflow.

## Repository layout

- `Sources/MupawCore`: shared models, bounded RPC codec, storage paths, and client code
- `Sources/MupawCapture`: ScreenCaptureKit and permission services owned by the app
- `Sources/MupawApp`: native macOS application and local RPC server
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
