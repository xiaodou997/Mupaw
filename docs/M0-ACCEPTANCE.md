# M0 acceptance criteria

M0 is complete only when all of the following are true on a real macOS 26+ machine.

## Build and structure

- `make generate` succeeds from a clean checkout.
- the Mupaw app and `mupaw-mcp` helper compile with Swift 6 strict concurrency;
- deterministic unit tests pass;
- `make localization-check` confirms English and Simplified Chinese key parity;
- `make mcp-smoke` validates MCP initialization, tool discovery, and the app-status contract;
- the source tree contains no generated build artifacts or secrets.
- `LICENSE`, `README.md`, and `CONTRIBUTING.md` consistently identify `PolyForm-Noncommercial-1.0.0`, preserve the required notice, and describe Mupaw as source-available rather than OSI open source.

## Native app

- the app ships English and Simplified Chinese UI and privacy descriptions;
- the app follows the macOS system or per-application language selection;
- `make install-dev` creates a signed app at `~/Applications/Mupaw.app`;
- the app shows the current screen-recording permission state;
- the app can request screen-recording permission through an explicit user action;
- after authorization it lists active displays and eligible on-screen windows;
- selecting a source and capturing creates a PNG in the app-managed capture directory;
- the returned artifact has a stable ID, dimensions, byte count, SHA-256, and preview.

## Local Agent bridge

- the app starts a loopback-only authenticated RPC listener;
- the connection descriptor is owner-only and is removed on clean shutdown;
- malformed, oversized, unauthenticated, and unknown-method requests fail explicitly;
- accepted RPC sockets use bounded blocking I/O, retry interrupted calls, and do not inherit the listener's nonblocking mode;
- permission probes are cached briefly so concurrent Agent status checks do not hammer macOS TCC services;
- source enumeration is cached briefly so concurrent Agent discovery calls share one ScreenCaptureKit refresh;
- the MCP helper reports when Mupaw is not running rather than pretending success.

## MCP

A real MCP client can:

1. call `mupaw_app_status`;
2. call `mupaw_capabilities_get`;
3. call `mupaw_sources_list`;
4. call `mupaw_screenshot_capture` with a returned source ID;
5. receive structured artifact metadata and an image preview.

`make mcp-smoke-running` covers steps 1–3 against the live app bridge, including the explicit `permission_required` path before authorization. After authorization, `make mcp-smoke-capture` covers steps 4–5 and validates the real PNG file, SHA-256, metadata, and MCP image preview.

## Deferred

M0 does not claim completion for long screenshots, annotations, OCR, recording, audio, camera, GIF, click highlights, keystrokes, or automatic zoom.
