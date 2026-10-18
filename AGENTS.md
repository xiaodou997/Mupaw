# Mupaw engineering instructions

## Product boundary

Mupaw is a macOS 26+ native screenshot and recording tool. Human UI and Agent/MCP operations must call the same domain services and produce the same project state. Do not implement Agent control by simulating clicks in Mupaw's UI.

## Architecture rules

1. The app owns ScreenCaptureKit, TCC permissions, recording sessions, and artifact storage.
2. The MCP executable is a local stdio bridge. It must not request separate screen-recording permission or capture the screen directly.
3. App-to-MCP communication is local-only, authenticated, versioned, bounded, and explicit about success versus accepted work.
4. Capture and edit results are represented as stable identifiers and Codable value types.
5. Long-running work must eventually use job identifiers; do not block MCP indefinitely.
6. Never write protocol logs to MCP stdout. Use stderr for diagnostics.
7. Keep M0 small: permissions, source enumeration, screenshot capture, local RPC, MCP exposure, localization, tests, and build validation.
8. MCP tool names, method names, error codes, and serialized enum values are stable protocol identifiers and must not be translated.

## Localization rules

- English and Simplified Chinese are required from the first version.
- User-visible UI strings must use localization keys rather than inline prose.
- Privacy usage descriptions must be translated in `InfoPlist.strings`.
- Every supported language must contain the same localization key set.
- Run `make localization-check` whenever localized resources change.

## Code quality

- Swift 6 strict concurrency is expected.
- Prefer actors or global-actor isolation over unchecked sharing.
- Bound all network payloads and file operations.
- Keep generated files out of source control unless explicitly required.
- Add unit tests for pure models, framing, validation, and storage behavior.
- Run `make format`, `make localization-check`, `make lint`, `make build`, and `make test` before handoff.
