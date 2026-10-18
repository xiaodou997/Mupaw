# Mupaw MCP contract — M0 through M1c

The executable product is `mupaw-mcp`. It communicates with MCP clients over stdio and forwards capture, editing, OCR, and color analysis to a running `Mupaw.app` instance. The helper never requests screen permission, captures independently, reads arbitrary source files, or drives Mupaw's UI.

## Discovery and capture tools

### `mupaw_app_status`

Returns whether the app responds, app and protocol versions, process ID, and relevant permission state.

### `mupaw_capabilities_get`

Returns the implemented and planned capability matrix. M1c reports `source-enumeration`, `screenshot`, `region-capture`, `screenshot-editing`, `ocr`, `color-sampling`, and `agent-mcp` as available.

### `mupaw_sources_list`

Returns active displays and eligible on-screen windows. Each source includes a session-scoped ID, kind, title, application metadata when available, pixel dimensions, global point frame, point-to-pixel scale, and active/primary hints. Callers must use exact returned source IDs.

### `mupaw_screenshot_capture`

Mupaw supports explicit `full_screen`, `window`, and `region` PNG capture. Region input uses `global_display_points`: macOS global display coordinates in points with a top-left origin.

```json
{
  "mode": "region",
  "region": {
    "coordinate_space": "global_display_points",
    "x": 120,
    "y": 80,
    "width": 960,
    "height": 540
  },
  "format": "png",
  "include_cursor": false,
  "exclude_mupaw_ui": true,
  "file_name": "optional-safe-name"
}
```

For full-screen and window capture, omit `region` and provide an exact `display:` or `window:` source ID. A successful result contains the completed local PNG file URL, SHA-256, actual dimensions, bytes, source metadata, and a bounded preview.

## Screenshot project tools

### `mupaw_project_create`

Creates a non-destructive project from a completed Mupaw capture.

```json
{
  "source_file_url": "file:///Users/example/Library/Application%20Support/Mupaw/Captures/example.png",
  "source_sha256": "64-character-sha256",
  "source_artifact_id": "optional-capture-artifact-id",
  "title": "Optional project title"
}
```

The source must resolve inside Mupaw's `Captures` directory. The app recomputes SHA-256, verifies image dimensions, copies the source to `Projects/<project-id>/original.png`, and writes an owner-only project document. The original remains unchanged by later edits.

Project get, OCR, color sampling, preview, and export verify that the copied original still matches its recorded SHA-256 and dimensions.

### `mupaw_project_get`

```json
{
  "project_id": "project-uuid"
}
```

Returns current revision, original metadata, crop, ordered edit objects, timestamps, and undo/redo availability.

### `mupaw_project_apply_edits`

Atomically applies one or more commands. Every mutation requires the current revision.

```json
{
  "project_id": "project-uuid",
  "expected_revision": 1,
  "commands": [
    {
      "type": "set_crop",
      "rect": {"x": 40, "y": 30, "width": 1200, "height": 720}
    },
    {
      "type": "add_object",
      "object": {
        "kind": "arrow",
        "arrow": {
          "id": "object-uuid",
          "start": {"x": 120, "y": 160},
          "end": {"x": 760, "y": 420},
          "color": {"red": 0.92, "green": 0.15, "blue": 0.18, "alpha": 1.0},
          "lineWidth": 12
        }
      }
    }
  ]
}
```

All edit coordinates use **original-image pixels with a top-left origin**. Crop does not rewrite object coordinates.

A batch contains 1–1,000 commands. `set_crop` must include the `rect` key; send a rectangle to set crop or JSON `null` to clear it. Omitting `rect` is an `invalid_request` rather than an implicit clear.

Supported commands:

- `set_crop`: include `rect`; send JSON `null` to clear crop;
- `add_object`: include a tagged `object`;
- `update_object`: include the full replacement object with the existing object ID;
- `delete_object`: include `object_id`;
- `reset`: clears crop and all objects.

Tagged object payloads:

```json
{
  "kind": "text",
  "text": {
    "id": "object-uuid",
    "frame": {"x": 100, "y": 100, "width": 500, "height": 100},
    "text": "Important",
    "color": {"red": 0.1, "green": 0.45, "blue": 0.95, "alpha": 1.0},
    "fontSize": 48
  }
}
```

```json
{
  "kind": "mosaic",
  "mosaic": {
    "id": "object-uuid",
    "frame": {"x": 700, "y": 120, "width": 260, "height": 160},
    "blockSize": 24
  }
}
```

A batch either validates and persists completely as one new revision, or leaves the project unchanged.

### `mupaw_project_history`

```json
{
  "project_id": "project-uuid",
  "expected_revision": 4,
  "action": "undo"
}
```

`action` is `undo` or `redo`. A successful history action creates a new monotonic revision rather than returning to an old revision number.

### `mupaw_project_preview`

```json
{
  "project_id": "project-uuid",
  "expected_revision": 5
}
```

Renders the project through the same renderer used for export. Returns output dimensions, revision, bounded JPEG preview metadata, and one MCP image content block. `expected_revision` is optional but recommended.

### `mupaw_project_ocr`

Runs Apple Vision OCR locally against the immutable copied original. Vision executes in Mupaw's signed, short-lived local OCR helper with a 120-second safety timeout; no image or text leaves the machine. The current project crop is used when `region` is omitted; rendered arrows, text annotations, and mosaic do not become OCR input.

```json
{
  "project_id": "project-uuid",
  "expected_revision": 5,
  "region": {"x": 40, "y": 30, "width": 1200, "height": 720},
  "recognition_level": "accurate",
  "recognition_languages": ["en-US", "zh-Hans"],
  "uses_language_correction": true,
  "minimum_confidence": 0.25
}
```

Only `project_id` is required. `expected_revision` is optional but recommended. Omitting `recognition_languages` or passing an empty array enables automatic language detection. At most eight short BCP-47-style language hints are accepted. `minimum_confidence` must be between 0 and 1.

The result includes:

- `projectID`, unchanged `projectRevision`, and `source: "original"`;
- the integral `analyzedRegion` in original-image pixels with a top-left origin;
- requested recognition settings plus `recognitionEngine` (`vision_fast` or `vision_accurate`), `effectiveRecognitionLanguages`, and result-level `detectedLanguages`;
- ordered `observations`, each with bounded text, confidence, a BCP-47-style detected `language` (`und` when uncertain), and an original-image pixel `boundingBox`;
- `fullText`, equal to observation text joined with newlines.

Results are bounded to 512 observations, 4,096 UTF-8 bytes per observation, and 256 KiB of combined text. Large source regions are scaled to a maximum OCR input dimension of 4,096 pixels while returned coordinates remain in original-image pixels. Language identification uses Natural Language only for sufficiently long or non-ASCII text at a configured confidence threshold and reports `und` rather than inventing a low-confidence language. A cold OCR request may take longer than ordinary RPC calls, so the local client uses a dedicated 150-second OCR response timeout. OCR is read-only and never advances the project revision.

### `mupaw_project_color_sample`

Samples normalized sRGB from the immutable copied original. Coordinates use original-image pixels with a top-left origin.

Point mode:

```json
{
  "project_id": "project-uuid",
  "expected_revision": 5,
  "mode": "point",
  "point": {"x": 320, "y": 180}
}
```

Region mode:

```json
{
  "project_id": "project-uuid",
  "expected_revision": 5,
  "mode": "region",
  "region": {"x": 100, "y": 80, "width": 640, "height": 360}
}
```

Point mode requires exactly one in-bounds point and no region. It returns one `primaryColor` and `sampledPixelCount: 1`. Region mode accepts an explicit region or, when omitted, defaults to the current project crop/full image. It returns `primaryColor` equal to `averageColor`, plus `centerColor`, a deterministic quantized `dominantColor`, and the actual bounded `sampledPixelCount`.

Each sampled color includes normalized `rgba`, uppercase `hexRGB` and `hexRGBA`, WCAG-style relative luminance, and `isDark`. Region sampling is bounded to at most 256 pixels on either axis and at most 65,536 sampled pixels. Color sampling is read-only and never advances the project revision.

### `mupaw_project_export`

```json
{
  "project_id": "project-uuid",
  "expected_revision": 5,
  "file_name": "Optional export name"
}
```

Exports an owner-only PNG under Mupaw's `Exports` directory. Returns project revision, file URL, actual dimensions, bytes, SHA-256, and the preview generated from the same rendered image. Export never overwrites the original capture or project document.

## Concurrency and errors

- `app_not_running`: start Mupaw and retry;
- `permission_required`: grant Screen & System Audio Recording permission;
- `capture_in_progress`: wait for the active capture/selection to finish;
- `source_not_found`: refresh sources and use a returned source ID;
- `invalid_region`: correct region coordinates or active-display intersection;
- `artifact_not_found`: the project source file no longer exists;
- `artifact_hash_mismatch`: the source file no longer matches the supplied capture hash;
- `project_not_found`: use a valid persisted project ID;
- `project_version_conflict`: fetch the current project and rebase the intended edit;
- `invalid_edit`: correct malformed coordinates, colors, object IDs, text, limits, or command combinations;
- `history_unavailable`: no undo or redo state exists;
- `export_failed`: no completed export is claimed;
- `ocr_failed`: the available local OCR engines or OCR input preparation failed; no partial result is claimed;
- `color_sampling_failed`: color input preparation or sRGB sampling failed;
- `invalid_request`, `unknown_method`, `protocol_mismatch`, `unauthorized`, `frame_too_large`, `capture_failed`, and `internal_error` retain their M0/M1a meanings.

MCP failures use `isError: true` text content and preserve the stable internal error code in the message. Invalid OCR/color inputs return `invalid_request`; stale expected revisions return `project_version_conflict`. A result is successful only after the requested capture, project mutation, analysis, preview, or export has completed.

## Validation commands

```bash
make mcp-smoke-running
make mcp-negative-smoke
make mcp-smoke-capture
make m1b-smoke
make m1c-smoke
make rpc-negative-smoke
make m1c-acceptance
```

`make m1b-smoke` performs a real capture, project creation, atomic crop/arrow/text/mosaic batches, update/delete/add, stale-revision and invalid-edit checks, undo, redo, reset, restore, preview, export, file/hash/dimension validation, and original-image immutability verification.

`make m1c-smoke` performs a real Mupaw-window capture, project creation, local OCR with engine/language reporting, point and region color sampling, result-bound/coordinate/color validation, invalid-input and stale-revision checks, and proof that analysis does not change the project revision, project document, or copied original.

`make mcp-smoke-full-screen` remains separate because it records the current display. Cover the display with non-sensitive test content first. For UI/MCP capture ownership, start interactive region selection and run `make mcp-capture-conflict-smoke`.
