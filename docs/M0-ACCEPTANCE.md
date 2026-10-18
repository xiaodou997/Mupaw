# M0 acceptance criteria

M0 is complete only when all of the following are true on a real macOS 26+ machine.

This document preserves the historical M0 scope. The current screenshot-mode gate is [M1A-ACCEPTANCE.md](M1A-ACCEPTANCE.md); current smoke commands may exercise stronger M1a paths without expanding what M0 originally claimed.

## Build and structure

- `make generate` succeeds from a clean checkout.
- the Mupaw app and `mupaw-mcp` helper compile with Swift 6 strict concurrency;
- deterministic unit tests pass;
- `make localization-check` confirms English and Simplified Chinese key parity;
- `make mcp-smoke` validates MCP initialization, tool discovery, and the app-status contract;
- `make m0-acceptance` runs the deterministic checks, restarts the signed app, exercises negative RPC/MCP paths, and validates a real screenshot;
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
- malformed, empty, oversized, unauthenticated, protocol-mismatched, and unknown-method requests fail with stable error codes;
- authentication is checked before method resolution, so an invalid token cannot probe the supported method catalog;
- accepted RPC sockets use bounded blocking I/O, retry interrupted calls, and do not inherit the listener's nonblocking mode;
- safe request identifiers are preserved on errors, while malformed JSON, oversized identifiers, and oversized frames use the bounded `unknown` identifier;
- the 4 MiB frame limit includes the newline delimiter, and an oversized response becomes a bounded `frame_too_large` response rather than a partial payload;
- a client that disconnects mid-frame cannot crash or wedge the bridge, and later requests continue to succeed;
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

`make mcp-smoke-running` covers steps 1–3 against the live app bridge, including the explicit `permission_required` path before authorization. `make mcp-negative-smoke` verifies unknown tools, missing arguments, unsupported formats, invented source identifiers, and recovery after errors. `make rpc-negative-smoke` verifies authentication, protocol versions, request parsing, frame bounds, disconnect recovery, and 32 requests with eight-way concurrency. After authorization, `make mcp-smoke-capture` covers steps 4–5 and validates the real PNG file, SHA-256, metadata, and MCP image preview.

## Deferred

M0 does not claim completion for long screenshots, annotations, OCR, recording, audio, camera, GIF, click highlights, keystrokes, or automatic zoom.
