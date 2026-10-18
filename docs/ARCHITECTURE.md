# Mupaw architecture

## Product invariant

A human and an Agent operate the same capture engine. A screenshot made through MCP must appear in the same artifact store and carry the same metadata as one made from the UI.

## Process model

```text
Agent client
    │ MCP over stdio
    ▼
mupaw-mcp helper
    │ authenticated, versioned JSON line RPC on 127.0.0.1
    ▼
Mupaw.app
    ├── permission service
    ├── capture source registry
    ├── native region-selection overlay and global shortcuts
    ├── ScreenCaptureKit full-screen/window/region capture service
    ├── multi-display region planner and compositor
    └── artifact store
```

The helper never performs screen capture itself. This avoids a second TCC identity and keeps permissions attached to `Mupaw.app`.

## Targets

### MupawCore

Pure shared types and local transport support:

- capability and permission models;
- explicit screenshot modes and global point/pixel geometry;
- source and artifact descriptors;
- deterministic multi-display region planning;
- RPC request/response envelopes;
- a strict request decoder and bounded response-frame encoder;
- connection descriptor storage;
- bounded local RPC client;
- filename validation.

### MupawCapture

Application-owned platform services:

- ScreenCaptureKit source enumeration with display/window frames and scale metadata;
- explicit full-screen and independent-window capture;
- structured region capture split across displays and composed into one bounded image;
- image encoding and preview generation;
- screen, microphone, camera, accessibility, and input-monitoring permission snapshots.

### Mupaw.app

- SwiftUI application shell with explicit screenshot modes;
- AppKit multi-display region-selection overlay with `Esc`/right-click cancellation;
- Carbon global shortcuts with visible conflict state;
- lifecycle for the local RPC listener;
- routing UI and RPC requests to the same capture service;
- artifact/status presentation.

### mupaw-mcp

- official Swift MCP SDK over stdio;
- a small, stable tool catalog;
- conversion between MCP values and Mupaw RPC values;
- actionable errors when the app is not running or permission is absent.

## M1a screenshot contract

`ScreenshotRequest` carries one explicit mode:

- `full_screen` requires an exact `display:` source ID;
- `window` requires an exact `window:` source ID;
- `region` requires a `CaptureRegion` and does not accept a source ID.

Human and Agent region capture intentionally differ only at the input boundary. The UI obtains a rectangle from a native AppKit overlay. MCP accepts a structured rectangle directly. Both then call the same `CaptureService.capture` method and produce the same artifact model.

Region coordinates use `global_display_points`: macOS global display coordinates measured in points with a top-left origin. Each display descriptor includes its global frame and `pointPixelScale`. The planner intersects the requested rectangle with every display, chooses the highest participating scale for the output canvas, requests display-local `sourceRect` slices from ScreenCaptureKit, and composites them into the requested union rectangle. Transparent pixels remain where a rectangular request spans a physical gap between displays. A global pixel-count limit prevents unbounded allocations.

Full-screen and region capture exclude Mupaw's own windows by default. Independent window capture uses the exact returned window. Only one capture operation may own the app at a time; concurrent Agent requests receive `capture_in_progress` while an interactive selection or another capture is active.

## Local RPC security

- bind only to loopback;
- use an ephemeral port;
- generate a random bearer token per app launch;
- save the descriptor under the user's Application Support directory;
- set descriptor permissions to owner read/write only;
- cap every newline-delimited request or response frame at 4 MiB, including the delimiter;
- accept exactly one JSON request per connection in M0;
- decode the wire method as a string first so an unsupported method returns `unknown_method` instead of collapsing into a generic decoding error;
- preserve a bounded, valid request ID on structured errors; use `unknown` when no safe ID can be trusted;
- validate the protocol version and bearer token before resolving or dispatching the requested method;
- replace an oversized encoded response with a small `frame_too_large` response carrying the same safe request ID;
- tolerate interrupted system calls and peer disconnects without terminating the app.

This is a local development contract, not a remote API. A later XPC migration remains possible because the domain request/response types are transport-neutral.

The deterministic codec tests cover malformed structures and oversized-response fallback. A raw loopback smoke test additionally exercises the running app with bad tokens, unknown methods, malformed JSON, oversized frames, early disconnects, and concurrent connections.

## Milestone evolution

- M0: source enumeration, base screenshot, permissions, RPC, MCP — complete.
- M1a: explicit full-screen/window/region capture, native selection overlay, global shortcuts, structured Agent regions — complete.
- M1b+: annotations, crop, OCR, color sampling, and base MP4 remain planned.
- M2: scrolling capture, background/rounded-corner/shadow styling, GIF.
- M3: system audio, microphone, camera overlay, click and keystroke events, manual zoom timeline.
- M4: automatic focus/zoom suggestions and editable super-recording workflow.
