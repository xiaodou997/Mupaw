# Mupaw engineering instructions

## Product boundary

Mupaw is a source-available macOS 26+ native screenshot and recording tool. Human UI and Agent/MCP operations must call the same domain services and produce the same project state. Do not implement Agent control by simulating clicks in Mupaw's UI.

## Architecture rules

1. The app owns ScreenCaptureKit, TCC permissions, recording sessions, and artifact storage.
2. The MCP executable is a local stdio bridge. It must not request separate screen-recording permission or capture the screen directly.
3. App-to-MCP communication is local-only, authenticated, versioned, bounded, and explicit about success versus accepted work.
4. Capture and edit results are represented as stable identifiers and Codable value types.
5. Long-running work must eventually use job identifiers; do not block MCP indefinitely.
6. Never write protocol logs to MCP stdout. Use stderr for diagnostics.
7. Screenshot modes must share one application-owned capture service. Human region capture uses a native AppKit overlay; Agent region capture uses a structured rectangle and must never simulate clicks in Mupaw's UI.
8. MCP tool names, method names, error codes, coordinate-space names, and serialized enum values are stable protocol identifiers and must not be translated.

## Capture geometry rules

- Agent regions use `global_display_points`: macOS global display coordinates in point units with a top-left origin.
- Display and window source descriptors expose their global frame and point-to-pixel scale so Agents do not invent coordinates.
- Multi-display region capture must split work per display, preserve the requested union rectangle, use bounded output dimensions, and handle mixed Retina scales deterministically.
- Full-screen and region capture should exclude Mupaw's own UI by default; independent window capture targets the exact returned window ID.
- Cancelling an interactive selection is not a capture failure and must not create an artifact.

## Screenshot project rules

- Original captures are immutable project inputs. Copy them into the project directory and store edits separately.
- Project coordinates use original-image pixels with a top-left origin; crop does not rewrite object coordinates.
- Every mutation must require the caller's expected revision and create a new monotonic revision.
- Persist bounded undo and redo stacks. A new edit after undo clears redo history.
- UI preview, MCP preview, and PNG export must call one shared renderer. Do not maintain visually divergent preview and export implementations.
- Agent edits are structured domain commands. Never drive the editor with simulated clicks or pointer movement.
- Validate every rectangle, point, color, text length, line width, font size, mosaic block size, object count, canvas allocation, and project identifier before persistence or rendering.
- Keep project and export files owner-only. Project creation must verify that the source belongs to Mupaw's capture directory and that its SHA-256 matches.
- Prefer deterministic Core Graphics CPU rendering for the editing foundation. Introduce GPU/Core Image paths only with a real-device crash and output-equivalence gate.

## Screenshot visual-style rules

- Visual styling is project state, not a destructive image rewrite. Legacy projects without style data must render exactly as before.
- The canonical render order is crop and annotations, rounded screenshot card, shadow, then background canvas.
- Solid and linear-gradient backgrounds, padding, aspect-ratio expansion, corner radius, and shadow parameters must remain bounded and deterministic.
- Style presets are ordinary structured parameter sets. Applying a preset creates a normal revision and users or Agents may modify every field afterward.
- UI preview, MCP preview, and PNG export must render style through the same `ScreenshotRenderer`; never approximate final output with a separate production renderer.
- The editor maps object, OCR, and color coordinates to the screenshot card inside the styled output canvas. Background pixels are not original-image coordinates.

## Screenshot analysis rules

- OCR and color sampling operate on the immutable copied original. The current crop is only the default analysis region; annotations must not silently alter analysis input.
- OCR results return bounded text observations, confidence, detected language (`und` when uncertain), and original-image pixel rectangles with a top-left origin.
- Point and region color sampling convert to sRGB and remain deterministic and allocation-bounded. Region sampling must report the sampling resolution/count.
- UI and MCP analysis must call the same project service. Agents provide structured points and rectangles and never simulate clicks in the editor.
- Analysis is read-only and must never advance the project revision or mutate the original, project document, or edit history.

## Localization rules

- English and Simplified Chinese are required from the first version.
- User-visible UI strings must use localization keys rather than inline prose.
- Privacy usage descriptions must be translated in `InfoPlist.strings`.
- Every supported language must contain the same localization key set.
- Run `make localization-check` whenever localized resources change.

## Licensing rules

- Mupaw uses `PolyForm-Noncommercial-1.0.0`; commercial use is not granted by the public license.
- Describe the project as source-available. Do not label it OSI open source or GPL-licensed.
- Preserve the complete `LICENSE` text and its `Required Notice:` line.
- Contributions are accepted under the same license; third-party dependencies retain their own terms.
- Do not imply that a commercial license is available unless the maintainer explicitly changes that policy in writing.

## Code quality

- Swift 6 strict concurrency is expected.
- Prefer actors or global-actor isolation over unchecked sharing.
- Bound all network payloads and file operations.
- Keep generated files out of source control unless explicitly required.
- Add unit tests for pure models, framing, validation, and storage behavior.
- Run `make format`, `make localization-check`, `make lint`, `make build`, and `make test` before handoff.
