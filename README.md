# Mupaw

Mupaw is a native macOS 26+ screenshot and screen-recording application designed for both people and Agents.

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

Open the generated project when UI debugging is needed:

```bash
open Mupaw.xcodeproj
```

## Localization

The first version ships with English (`en`) and Simplified Chinese (`zh-Hans`). Mupaw follows the language selected by macOS, including the per-application language override in System Settings. UI strings and privacy usage descriptions are localized; MCP tool names and protocol identifiers remain stable English identifiers.

Run `make localization-check` after changing translations. It verifies that both languages contain the same keys and that required privacy descriptions are present. See `docs/LOCALIZATION.md` for the extension workflow.

## Repository layout

- `Sources/MupawCore`: shared models, local RPC protocol, storage paths, and client code
- `Sources/MupawCapture`: ScreenCaptureKit and permission services owned by the app
- `Sources/MupawApp`: native macOS application and local RPC server
- `Sources/MupawMCP`: MCP stdio bridge for Agent clients
- `Resources/MupawApp`: localized UI and Info.plist resources
- `Tests`: deterministic unit tests
- `scripts`: reproducible local validation and MCP protocol smoke tests
- `docs`: architecture, localization, MCP contract, and milestone acceptance criteria

## Licensing

No public license has been frozen yet. GPL-3.0 permits commercial use, while a strict “no commercial use by others” requirement needs a non-commercial source license and is not OSI open source. The repository must not add a misleading GPL notice until that choice is resolved explicitly.
