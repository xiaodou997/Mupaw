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
    ├── ScreenCaptureKit capture service
    └── artifact store
```

The helper never performs screen capture itself. This avoids a second TCC identity and keeps permissions attached to `Mupaw.app`.

## Targets

### MupawCore

Pure shared types and local transport support:

- capability and permission models;
- source and artifact descriptors;
- RPC request/response envelopes;
- connection descriptor storage;
- bounded local RPC client;
- filename validation.

### MupawCapture

Application-owned platform services:

- ScreenCaptureKit source enumeration;
- still-image capture;
- image encoding and preview generation;
- screen, microphone, camera, accessibility, and input-monitoring permission snapshots.

### Mupaw.app

- SwiftUI application shell;
- lifecycle for the local RPC listener;
- routing RPC methods to the capture service;
- artifact/status presentation.

### mupaw-mcp

- official Swift MCP SDK over stdio;
- a small, stable tool catalog;
- conversion between MCP values and Mupaw RPC values;
- actionable errors when the app is not running or permission is absent.

## Local RPC security

- bind only to loopback;
- use an ephemeral port;
- generate a random bearer token per app launch;
- save the descriptor under the user's Application Support directory;
- set descriptor permissions to owner read/write only;
- cap a request or response frame at 4 MiB;
- accept one newline-delimited JSON request per connection in M0;
- validate protocol version before dispatch.

This is a local development contract, not a remote API. A later XPC migration remains possible because the domain request/response types are transport-neutral.

## Milestone evolution

- M0: source enumeration, screenshot, permissions, RPC, MCP.
- M1: region/fullscreen/window UX, annotations, crop, OCR, color sampling, base MP4.
- M2: scrolling capture, background/rounded-corner/shadow styling, GIF.
- M3: system audio, microphone, camera overlay, click and keystroke events, manual zoom timeline.
- M4: automatic focus/zoom suggestions and editable super-recording workflow.
