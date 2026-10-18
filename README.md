# Mupaw

Mupaw is a native macOS 26+ screenshot and screen-recording application designed for both people and Agents.

The first development milestone focuses on a reliable foundation:

- native SwiftUI/AppKit application shell;
- ScreenCaptureKit source discovery and still-image capture;
- a single application-owned capture service;
- a local authenticated RPC bridge;
- an MCP stdio server that exposes the same operations to Agents;
- deterministic project files, tests, and local build commands.

Long scrolling screenshots, annotations, OCR, audio recording, camera overlay, GIF export, click highlights, keystroke display, and automatic zoom are planned on top of this foundation. They are intentionally not mixed into M0 before the capture and Agent control path is proven.

## Requirements

- macOS 26 or later
- Xcode 27 or later for the current development environment
- XcodeGen

## Build

```bash
make generate
make lint
make build
make test
```

Run the current development app:

```bash
make run
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

## Repository layout

- `Sources/MupawCore`: shared models, local RPC protocol, storage paths, and client code
- `Sources/MupawCapture`: ScreenCaptureKit and permission services owned by the app
- `Sources/MupawApp`: native macOS application and local RPC server
- `Sources/MupawMCP`: MCP stdio bridge for Agent clients
- `Tests`: deterministic unit tests
- `scripts`: reproducible local MCP protocol smoke tests
- `docs`: architecture, MCP contract, and milestone acceptance criteria

## Licensing

The public license is deliberately not frozen in M0. The intended product is free and source-available/open-source, with no commercial product planned by the maintainer. A standard open-source license and a strict non-commercial source license have different legal effects, so the choice must be fixed before the first public release or outside contribution.
