# M1d acceptance criteria

M1d adds non-destructive screenshot visual styling to the M1b project renderer while preserving M1c OCR and color analysis. It does not claim scrolling capture, GIF, MP4, system audio, microphone, camera overlay, click/keystroke visualization, or automatic zoom.

## Build, localization, and compatibility

- `make format`, `make localization-check`, `make lint`, `make build`, and `make test` succeed with Swift 6 strict concurrency;
- English and Simplified Chinese contain identical UI, style, renderer-error, and privacy key sets;
- legacy M1b/M1c project JSON without `visualStyle` decodes as unstyled and preserves the old output path and dimensions;
- the style model, commands, preset identifiers, background modes, and aspect identifiers are stable Codable values and are not localized on the wire;
- generated projects, builds, captures, exports, local signing configuration, and user-specific paths are not committed.

## Non-destructive project model

- visual style is optional revisioned project content and never rewrites `original.png`;
- `set_visual_style`, `apply_style_preset`, and `clear_visual_style` are atomic `project_apply_edits` commands;
- every successful style mutation requires `expected_revision`, advances the monotonic revision once, and enters bounded undo/redo history;
- `reset` clears crop, annotations, and visual style;
- a failed style command rejects the entire batch without changing revision, crop, objects, style, history, original bytes, or project document state;
- applying the `none` preset produces the same unstyled state as clearing style.

## Style model and bounds

M1d supports:

- solid background;
- two-color linear gradient and angle;
- canvas padding;
- automatic, square, landscape 4:3, landscape 16:9, portrait 3:4, and portrait 9:16 output canvases;
- screenshot-card corner radius;
- optional shadow color, blur, horizontal offset, and vertical offset;
- built-in `none`, `clean_white`, `soft_gray`, `ocean`, `sunset`, and `midnight` presets.

Validation must reject non-finite or out-of-range colors, angles, padding, corner radius, blur, offsets, and final canvas allocations. The style layout planner reserves the bounded shadow footprint, expands rather than crops for a requested aspect ratio, centers the composition, and respects the global screenshot pixel limit.

## Shared renderer

The canonical output order is:

```text
verified original crop and annotations
→ rounded screenshot card
→ shadow
→ solid or gradient background canvas
```

- the original crop and annotation renderer remains the first stage;
- rounded corners use an alpha-clipped card rather than modifying the original;
- shadow and background use deterministic Core Graphics rendering in sRGB;
- UI project preview, MCP project preview, and PNG export consume the same final `CGImage`;
- preview and export report identical output dimensions for the same revision;
- exported file bytes, byte count, PNG dimensions, SHA-256, and owner-only permissions agree with metadata;
- removing style restores exact unstyled source/crop dimensions.

## Human editor

After a screenshot project is active:

- the Beautify toolbar action opens a localized style editor;
- the six presets are visible and selecting one exposes ordinary editable parameters;
- the user can enable or remove style;
- solid/gradient background, colors, gradient angle, aspect, padding, corner radius, shadow toggle/color/blur/offsets are editable;
- Apply creates one normal project revision; Remove Style creates one normal revision;
- the main screenshot preview updates through `ScreenshotProjectService` and the shared renderer;
- object handles, OCR rectangles, and color-sampling points continue to map to the screenshot card inside the styled canvas rather than the background;
- background clicks do not become original-image coordinates;
- undo, redo, reset, PNG export, and editor minimum-size layout remain usable.

## Agent/MCP styling

`mupaw_project_apply_edits` advertises and accepts:

```text
set_visual_style
apply_style_preset
clear_visual_style
```

A real MCP acceptance flow must:

1. capture a visible Mupaw window and create a project;
2. verify a new project is unstyled at revision 1;
3. apply the Ocean preset and validate persisted structured parameters;
4. preview and export the preset through the shared renderer and verify deterministic expanded dimensions, file metadata, SHA-256, and preview image content;
5. replace the preset with a fully custom gradient, square canvas, rounded card, and shadow;
6. verify the square preview/export dimensions and exact persisted style;
7. reject an oversized style inside a multi-command atomic batch and prove revision/style remain unchanged;
8. undo to the preset and redo to the custom style;
9. clear style and verify unstyled dimensions are restored;
10. apply the `none` preset and remain unstyled;
11. prove the copied-original SHA-256 is unchanged.

Agents provide structured style values and never operate the Beautify sheet or simulate editor clicks.

## Reproducible commands

```bash
make m1d-smoke
make m1d-acceptance
```

`make m1d-acceptance` includes formatting/localization, all unit tests, stable signed installation, raw RPC negative/concurrency checks, M1a real capture validation, M1b editing validation, M1c OCR/color validation, and the full real M1d preset/custom-style preview/export/history flow.

## Deferred

M1d does not claim scrolling long screenshots, stitched partial results, GIF, MP4, system audio, microphone, camera overlay, click highlights, keystroke display, manual zoom timelines, or automatic zoom. Physical dual-display region dragging remains a compatibility follow-up rather than an M1d blocker.
