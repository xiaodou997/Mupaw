# M1a acceptance criteria

M1a is complete only when all criteria below pass on a real macOS 26+ machine. This gate extends M0; it does not claim annotations, OCR, scrolling capture, or recording.

## Build, localization, and deterministic models

- `make generate`, `make lint`, `make build`, and `make test` succeed with Swift 6 strict concurrency.
- English and Simplified Chinese contain identical UI and privacy key sets.
- deterministic tests cover rectangle normalization, AppKit/global coordinate conversion, single-display Retina planning, mixed-scale cross-display planning, bounds failures, and legacy/new request decoding.
- the source tree contains no generated project, build artifacts, local signing configuration, captured images, or secrets.

## Source discovery and explicit modes

- `mupaw_sources_list` returns display and window sources with global point frames, point-to-pixel scales, pixel dimensions, and useful application/active/primary hints.
- the UI exposes three explicit modes: Full Screen, Window, and Region.
- full-screen capture accepts only a returned display source; window capture accepts only a returned window source; region capture accepts a structured region and no source ID.
- stale, closed, mismatched, or missing sources return explicit errors and never claim an artifact.

## Native region selection

- pressing Select Region opens a native AppKit overlay on every active display.
- dragging may cross display boundaries and produces one region in `global_display_points`.
- `Esc` and right-click cancel without creating an artifact.
- a display-configuration change cancels the selection explicitly.
- a too-small selection remains in selection mode rather than creating an invalid artifact.
- after selection, overlay windows are removed before ScreenCaptureKit captures the region.

## Retina and multi-display capture

- the region planner intersects the requested global-point rectangle with each active display.
- every slice is converted to a display-local ScreenCaptureKit `sourceRect`.
- mixed-scale regions use the highest participating point-to-pixel scale for one deterministic output canvas.
- physical gaps between displays remain transparent instead of being stretched or silently removed.
- output allocation is bounded by `maximumScreenshotPixelCount`.
- the resulting PNG, metadata, SHA-256, and bounded preview agree.

## Global shortcuts

The default shortcuts register without Accessibility or Input Monitoring permission:

```text
Control + Option + Command + 1   Full screen under the pointer
Control + Option + Command + 2   Frontmost eligible window
Control + Option + Command + 3   Region selection
```

- registration conflicts and other registration failures are visible in the UI and can be retried.
- full-screen capture excludes Mupaw UI by default.
- frontmost-window capture resolves the front-to-back Core Graphics window order for the most recently active external application.
- the region shortcut enters the same native selection flow as the UI button.

## Agent and concurrency behavior

- MCP advertises `mode`, `source_id`, `region`, and `exclude_mupaw_ui` in the screenshot tool schema.
- a real MCP client completes explicit window and structured-region captures through the application-owned service.
- a full-screen MCP capture passes separately on a display covered by non-sensitive test content.
- Agents never operate the region overlay or simulate Mupaw UI input.
- while an interactive selection or another capture owns the service, a concurrent MCP screenshot returns `capture_in_progress`.
- negative tests cover missing sources, missing/invalid regions, illegal source-plus-region combinations, unsupported formats, invented sources, and recovery after errors.

## Reproducible commands

```bash
make m1a-acceptance
```

This non-full-screen gate performs formatting/localization checks, unit tests, stable signed installation, raw RPC negative/concurrency checks, MCP negative checks, and real window plus structured-region captures.

Full-screen capture is intentionally separate because it records the current display:

```bash
make mcp-smoke-full-screen
```

Cover the target display with non-sensitive test content first.

For the UI/MCP ownership check, begin an interactive region selection and run:

```bash
make mcp-capture-conflict-smoke
```

It must return `capture_in_progress`; cancel the overlay with `Esc` afterward.

## Deferred

M1a does not claim scrolling long screenshots, arrows, text, mosaic, crop editing, OCR, color sampling, background/shadow styling, MP4/GIF recording, system audio, microphone, camera overlay, click/keystroke visualization, or automatic zoom.
