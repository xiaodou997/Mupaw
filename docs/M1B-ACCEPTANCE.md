# M1b acceptance criteria

M1b is the screenshot-editing foundation. It extends M1a and does not claim OCR, color sampling, long screenshots, background/shadow styling, recording, GIF, click/keystroke visualization, or automatic zoom.

The development machine has one display. Physical cross-display dragging remains a future compatibility check and does not block M1b; deterministic negative-coordinate and mixed-scale planning tests continue to cover that M1a path.

## Build, localization, and tests

- `make format`, `make localization-check`, `make lint`, `make build`, and `make test` succeed with Swift 6 strict concurrency.
- English and Simplified Chinese have identical localized key sets.
- editor controls and service errors have English and Simplified Chinese user-visible messages while protocol identifiers remain stable English values.
- Core and editing test bundles both run and report zero failures.
- tests cover project creation, source hash validation, source-directory confinement, crop/arrow/text/mosaic validation, version conflicts, invalid edits, canvas bounds, undo/redo boundaries, redo invalidation after a new edit, reset persistence, preview dimensions, export bytes/hash, and original-image preservation.
- generated projects, builds, captures, exports, local signing configuration, and user-specific paths are not committed.

## Non-destructive project storage

- project creation accepts only an existing file inside Mupaw's `Captures` directory;
- source SHA-256 is syntactically validated, recomputed, and must match the request;
- project get, preview, and export recheck the copied original SHA-256 and dimensions;
- source dimensions are read before allocation and checked against the global pixel limit;
- the source is copied to `Projects/<uuid>/original.png` and is never modified;
- root/capture/project/export directories are repaired to `0700`; project JSON, copied originals, and exports are repaired to `0600`;
- project documents include schema version, UUID, monotonic revision, source metadata, current content, bounded undo/redo stacks, and timestamps;
- project state survives creating a fresh `ScreenshotProjectService` instance.

## Editing model and validation

- coordinates use original-image pixels with a top-left origin;
- crop is optional, fully inside the original, and does not rewrite annotation coordinates;
- arrows contain two bounded points, normalized color, valid line width, and a minimum length;
- text contains a bounded frame, non-empty bounded UTF-8 text, normalized color, and valid font size;
- mosaic contains a bounded frame and valid block size;
- object IDs are UUIDs and unique within the project;
- command count, object count, history depth, title/source-ID/text bytes, canvas pixels, and render allocations are bounded;
- a batch is atomic: one invalid command rejects the whole batch without advancing revision;
- every mutation, undo, and redo requires `expected_revision` and creates one new revision;
- undo/redo stacks persist; a new edit after undo clears redo.

## Shared rendering and export

- preview and export call the same renderer with the same project revision;
- renderer loads the copied original, applies crop, then draws objects in array order;
- arrow, CoreText text, and CPU mosaic output are included in both preview and export;
- preview returns actual output dimensions and a bounded JPEG;
- export writes PNG under `Exports`, then reports actual dimensions, byte count, SHA-256, file URL, and preview;
- the MCP image block exactly matches preview metadata;
- preview and export preview bytes match for the same revision;
- the original copied image retains its original SHA-256 after every edit and export.

## Human editor

After any UI screenshot:

- Mupaw automatically creates and activates an editing project;
- the editor displays the rendered project preview rather than modifying the source image;
- toolbar actions add arrow, text, mosaic, and crop;
- canvas/layer selection works;
- selected objects can move; text/mosaic frames resize; arrow endpoints adjust;
- the inspector changes arrow color/width, text content/color/font size, and mosaic block size;
- delete removes the selected object;
- undo, redo, reset, and PNG export update their enabled states from project state;
- the crop sheet can move/resize, clear, apply, or cancel without altering the original;
- the current revision, object count, crop state, project ID, and latest export metadata are visible;
- the editor remains usable at the configured minimum window size and has accessible button labels.

## Agent/MCP editing

The following tools are advertised and callable:

```text
mupaw_project_create
mupaw_project_get
mupaw_project_apply_edits
mupaw_project_history
mupaw_project_preview
mupaw_project_export
```

A real MCP acceptance flow must:

1. capture a real Mupaw window;
2. create a project from the returned URL, hash, and artifact ID;
3. atomically add crop, arrow, text, and mosaic;
4. update arrow/text, delete a mosaic, and add a replacement;
5. reject a stale revision with `project_version_conflict`;
6. reject invalid text with `invalid_edit`;
7. undo and redo the update batch;
8. reset and undo reset;
9. preview the restored revision;
10. export PNG and verify file location, PNG dimensions, bytes, SHA-256, and preview equality;
11. fetch the project again and verify persisted current state;
12. verify the copied original hash is unchanged.

UI and MCP must call the same `ScreenshotProjectService`; Agent tools must not simulate editor clicks.

## Reproducible commands

```bash
make m1b-smoke
make m1b-acceptance
```

`make m1b-acceptance` includes formatting/localization, all unit tests, stable signed installation, raw RPC negative/concurrency checks, M1a capture checks, and the complete M1b MCP project flow.

## Deferred

M1b does not claim OCR, color sampling, scrolling capture, background/rounded-corner/shadow styling, MP4/GIF recording, system audio, microphone, camera overlay, click highlights, keystroke display, or automatic zoom. Physical dual-display drag validation is recorded as a compatibility follow-up rather than an M1b blocker.
