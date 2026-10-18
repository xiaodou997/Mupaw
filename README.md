# Mupaw

[![License: PolyForm Noncommercial 1.0.0](https://img.shields.io/badge/license-PolyForm%20Noncommercial%201.0.0-5b5b5b.svg)](LICENSE)

Mupaw is a source-available native macOS 26+ screenshot and screen-recording application designed for both people and Agents.

Mupaw currently includes the M0 foundation, M1a capture modes, and M1b screenshot editing:

- explicit full-screen, window, and region PNG capture;
- a native AppKit region-selection overlay with cancellation and multi-display-aware geometry;
- global shortcuts for full screen, frontmost window, and region selection;
- non-destructive, persisted, revisioned screenshot projects;
- crop, arrow, text, and mosaic editing with selection, movement, resizing, deletion, reset, undo, and redo;
- one shared renderer for UI preview, Agent preview, and final PNG export;
- structured Agent capture and editing tools that never simulate Mupaw UI clicks;
- ScreenCaptureKit capture owned by one stably signed app identity;
- a local authenticated RPC bridge and MCP stdio server;
- English and Simplified Chinese localization from the first version;
- deterministic models, tests, and local acceptance commands.

Long scrolling screenshots, OCR, color sampling, background/shadow styling, audio/video recording, camera overlay, GIF export, click highlights, keystroke display, and automatic zoom remain planned. They are not part of M1b.

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

## Screenshot editing

Every screenshot created through the app becomes an editable project without changing the original capture. Mupaw copies the original PNG into its project directory, records its SHA-256 and dimensions, and stores crop and annotation objects separately in a versioned JSON document.

Project creation accepts only files in Mupaw's capture directory and verifies the supplied SHA-256. Reading, previewing, and exporting a project recheck the copied original's hash and dimensions, so local corruption is reported instead of silently rendering a different source.

The editor currently supports:

- non-destructive crop;
- arrows with adjustable endpoints, color, and line width;
- text with editable content, color, frame, and font size;
- mosaic regions with adjustable frame and block size;
- object selection, movement, resizing, layer selection, deletion, reset, undo, and redo;
- PNG export while keeping the source capture and project editable.

Editing coordinates use original-image pixels with a top-left origin. Preview and export run through the same renderer, so a completed preview and export at the same project revision represent the same composed image.

Agents use `mupaw_project_create`, `mupaw_project_get`, `mupaw_project_apply_edits`, `mupaw_project_history`, `mupaw_project_preview`, and `mupaw_project_export`. Mutating calls require `expected_revision`; stale callers receive `project_version_conflict` rather than overwriting newer work.

A batch is bounded to 1,000 commands and is atomic: any invalid command rejects the entire batch without advancing the revision.

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

Run the complete M1b acceptance sequence. It checks formatting and localization, runs capture and editing tests, rebuilds and restarts the stably signed app, performs negative/concurrency checks, validates real captures, then creates, edits, previews, undoes, redoes, resets, restores, and exports a real project through MCP:

```bash
make m1b-acceptance
```

`make m1b-acceptance` expects the stable signing identity in `.mupaw.local.mk` and Screen & System Audio Recording permission to have been granted to `~/Applications/Mupaw.app`. Historical `m0-acceptance` and `m1a-acceptance` gates remain available.

The focused editing flow can be rerun with:

```bash
make m1b-smoke
```

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

- `Sources/MupawCore`: shared capture/editing models, geometry, bounded RPC codec, storage paths, and client code
- `Sources/MupawCapture`: ScreenCaptureKit source, full-screen/window/region capture, composition, and permission services
- `Sources/MupawEditing`: project persistence, edit validation, shared renderer, previews, history, and PNG export
- `Sources/MupawApp`: native capture/editor UI, region overlay, global shortcuts, and local RPC server
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
