# Mupaw MCP contract — M0 through M3a

The executable product is `mupaw-mcp`. It communicates with MCP clients over stdio and forwards screenshot capture, MP4 recording sessions, editing, visual styling, OCR, and color analysis to a running `Mupaw.app` instance. The helper never requests screen permission, captures or records independently, reads arbitrary source files, or drives Mupaw's UI.

## Discovery and capture tools

### `mupaw_app_status`

Returns whether the app responds, app and protocol versions, process ID, and relevant permission state.

### `mupaw_capabilities_get`

Returns the implemented and planned capability matrix. M3a reports `source-enumeration`, `screenshot`, `region-capture`, `recording`, `camera-overlay`, `screenshot-editing`, `visual-style`, `ocr`, `color-sampling`, and `agent-mcp` as available. Recording supports all M2c audio modes plus an optional camera picture-in-picture overlay baked into the single H.264 video track.

### `mupaw_sources_list`

Returns active displays and eligible on-screen windows. Each source includes a session-scoped ID, kind, title, application metadata when available, pixel dimensions, global point frame, point-to-pixel scale, and active/primary hints. Callers must use exact returned source IDs.

### `mupaw_microphones_list`

Returns the current microphone permission, system-default device ID, and available input devices with stable ID, localized name, manufacturer when available, default hint, and connection state. Agents must use an exact returned ID or omit the ID to request the current default; they must not invent microphone identifiers.

### `mupaw_cameras_list`

Returns the current camera permission, system-default device ID, and available cameras with stable ID, localized name, manufacturer when available, front/back/unspecified position, default hint, and connection state. Agents must use one exact returned ID or omit the ID to request the current default; they must not invent camera identifiers.

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

## Recording tools

M3a records H.264 MP4 with the M2c audio modes and an optional camera picture-in-picture overlay. Omitting audio and `camera_overlay` preserves the M1e video-only contract. Legacy audio flags remain compatible. A requested camera is composited into every output frame before encoding; the final MP4 still contains exactly one H.264 video track. Clicks, keystrokes, GIF, timeline editing, and zoom events are not included.

### `mupaw_recording_start`

Starts one application-owned recording and returns after ScreenCaptureKit has started. Only one recording session may be active.

System-audio example:

```json
{
  "mode": "window",
  "source_id": "window:1234",
  "format": "mp4",
  "frame_rate": 30,
  "quality": "standard",
  "include_cursor": false,
  "audio_source": "system_audio",
  "file_name": "Product demo"
}
```

Microphone example:

```json
{
  "mode": "window",
  "source_id": "window:1234",
  "format": "mp4",
  "frame_rate": 30,
  "quality": "standard",
  "audio_source": "microphone",
  "microphone_device_id": "exact-id-from-mupaw_microphones_list"
}
```

Mixed-audio example:

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
  "frame_rate": 30,
  "quality": "standard",
  "audio_source": "system_audio_and_microphone",
  "microphone_device_id": "exact-id-from-mupaw_microphones_list",
  "system_audio_gain": 0.8,
  "microphone_gain": 1.25,
  "system_audio_muted": false,
  "microphone_muted": false
}
```

Camera picture-in-picture example:

```json
{
  "mode": "window",
  "source_id": "window:1234",
  "frame_rate": 30,
  "quality": "standard",
  "audio_source": "system_audio",
  "camera_overlay": {
    "enabled": true,
    "camera_device_id": "exact-id-from-mupaw_cameras_list",
    "visible": true,
    "position": "bottom_right",
    "size": "medium",
    "shape": "circle",
    "corner_radius": 0.12,
    "margin": 0.025
  }
}
```

Structured region example:

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
  "frame_rate": 15,
  "quality": "high",
  "audio_source": "none",
  "exclude_mupaw_ui": true
}
```

`full_screen` and `window` require an exact source ID from `mupaw_sources_list`; `region` supplies a rectangle wholly inside one display. `frame_rate` is 15, 30, or 60; `quality` is `standard` or `high`. `microphone_device_id` and `camera_device_id` may be omitted to use their current defaults and otherwise must exactly match discovery. Camera `position` is one of four corners, `size` is `small`, `medium`, or `large`, `shape` is `circle` or `rounded_rectangle`, `corner_radius` is `0.0...0.5`, and `margin` is `0.0...0.15`. The selected camera device locks after start; presentation fields remain adjustable through `mupaw_recording_update_camera_overlay`. Required permissions must already be authorized. The result includes the stable session ID, source, dimensions, phase, elapsed duration, output frame count, audio state, and—when requested—camera identity, current visibility/layout/style, control-event count, source dimensions, input frame count, last wall/source timestamps, and stale state.

### `mupaw_recording_status`

```json
{"session_id": "recording-session-uuid"}
```

Returns active or retained terminal state. Active phases are `starting`, `recording`, and `stopping`; terminal phases are `completed`, `failed`, and `cancelled`. Camera-enabled status reports `waiting` until the first valid frame, then `capturing`, plus frame count, last timestamps, source dimensions, overlay rectangle, and stale state.

### `mupaw_recording_update_audio_controls`

```json
{
  "session_id": "recording-session-uuid",
  "system_audio_gain": 0.35,
  "microphone_gain": 1.5,
  "system_audio_muted": false,
  "microphone_muted": true
}
```

Updates any provided gain or mute fields on the active recording. At least one field is required. Source and microphone device selection cannot change after start. The returned status reflects the committed controls immediately; finalization applies the bounded control-event timeline to the single AAC output track.

### `mupaw_recording_update_camera_overlay`

```json
{
  "session_id": "recording-session-uuid",
  "visible": false,
  "position": "top_left",
  "size": "large",
  "shape": "rounded_rectangle",
  "corner_radius": 0.3,
  "margin": 0.08
}
```

Updates any provided camera presentation fields on an active camera-enabled recording. At least one field is required. The selected camera device and the fact that camera capture was requested cannot change after start. Hidden mode keeps camera capture and frame-health enforcement active so the same device can be shown again. Each successful update appends a bounded control event and returns refreshed camera metadata immediately.

### `mupaw_recording_stop`

```json
{"session_id": "recording-session-uuid"}
```

Stops ScreenCaptureKit and the optional camera session, then waits for capture finalization and audio post-processing. Audio-enabled capture uses an owner-only intermediate MOV; Mupaw applies the runtime control timeline, writes one final AAC track into MP4, and deletes the intermediate before returning. A completed artifact includes the owner-only MP4 URL, one H.264 video-track identity, actual dimensions and duration, requested/average frame rate, output frame count, audio metadata, and camera identity/final visibility/layout/style/control-event count/source dimensions/input-frame count/last timestamps/final overlay rectangle when requested, plus bytes, SHA-256, timestamps, and preview.

Completion requires one playable H.264 video track, with any requested camera already baked into it. `none` requires zero audio tracks; every enabled audio mode requires exactly one 48 kHz stereo AAC track. Every requested audio source and camera must provide valid samples/frames and remain live. Camera startup is bounded to four seconds and frame stalls to three seconds. Missing permission, unavailable/disconnected devices, source startup/stall, invalid camera frames, composition, conversion, mix, write, or final-validation failure removes intermediate and final partial files.

### `mupaw_recording_cancel`

```json
{"session_id": "recording-session-uuid"}
```

Stops screen, audio, and camera capture, cancels AVAssetWriter, deletes intermediate/final incomplete output, and returns `cancelled` without an artifact. Recording dimensions, queues, duration, camera/audio health state, control-event history, files, and terminal history remain bounded; static video receives the held final original or composited frame so wall-clock duration stays correct.


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

Returns current revision, original metadata, crop, ordered edit objects, optional `visualStyle`, timestamps, and undo/redo availability. Legacy projects without the field decode as unstyled.

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
- `set_visual_style`: include a complete `style` object;
- `apply_style_preset`: include `preset` as `none`, `clean_white`, `soft_gray`, `ocean`, `sunset`, or `midnight`;
- `clear_visual_style`: removes styling while preserving crop and objects;
- `reset`: clears crop, all objects, and visual style.

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

Visual-style command example:

```json
{
  "type": "set_visual_style",
  "style": {
    "background": {
      "mode": "linear_gradient",
      "start_color": {"red": 0.12, "green": 0.42, "blue": 0.96, "alpha": 1.0},
      "end_color": {"red": 0.13, "green": 0.84, "blue": 0.70, "alpha": 1.0},
      "angle_degrees": 35
    },
    "padding": 80,
    "corner_radius": 40,
    "shadow": {
      "is_enabled": true,
      "color": {"red": 0.01, "green": 0.04, "blue": 0.12, "alpha": 0.38},
      "blur_radius": 30,
      "offset_x": 8,
      "offset_y": 18
    },
    "canvas_aspect": "square"
  }
}
```

`background.mode` is `solid` or `linear_gradient`. Canvas aspect is `automatic`, `square`, `landscape_4_3`, `landscape_16_9`, `portrait_3_4`, or `portrait_9_16`. Style values and final allocations are bounded. Presets are editable parameter sets rather than opaque themes.

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

Renders the project through the same renderer used for export. For styled projects the order is crop/annotations, rounded card, shadow, then background canvas. Returns actual output dimensions, revision, bounded JPEG preview metadata, and one MCP image content block. `expected_revision` is optional but recommended.

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

Exports an owner-only PNG under Mupaw's `Exports` directory. Returns project revision, file URL, actual styled or unstyled dimensions, bytes, SHA-256, and the preview generated from the same rendered image. Export never overwrites the original capture or project document.

## Concurrency and errors

- `app_not_running`: start Mupaw and retry;
- `permission_required`: grant Screen & System Audio Recording permission;
- `capture_in_progress`: wait for the active capture/selection to finish;
- `recording_in_progress`: poll or stop the returned active recording session before starting another;
- `recording_not_found`: use a retained or active session UUID;
- `recording_not_active`: the requested session is not the active session;
- `recording_failed`: no completed MP4 is claimed; inspect the accompanying stream/writer/finalization message;
- `microphone_permission_required`: grant microphone permission to the signed Mupaw app before microphone recording;
- `microphone_device_not_found`: refresh `mupaw_microphones_list` and use a connected returned device, or omit the ID for the current default;
- `camera_permission_required`: grant camera permission to the signed Mupaw app before camera-overlay recording;
- `camera_device_not_found`: refresh `mupaw_cameras_list` and use a connected returned device, or omit the ID for the current default;
- `audio_mixing_not_supported`: remove explicit/legacy source contradictions; both legacy flags are valid and select M2c mixing;
- `invalid_audio_controls`: provide at least one update field and keep gains within the finite `0.0...2.0` range;
- `invalid_camera_overlay`: enable the overlay before naming a device, provide at least one runtime update field, and keep corner radius/margin within their finite bounded ranges;
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

MCP failures use `isError: true` text content and preserve the stable internal error code in the message. Invalid recording settings, OCR/color inputs, or source/mode combinations return `invalid_request`; stale expected revisions return `project_version_conflict`. Recording start success means the stream started, while completed recording success is returned only by status/stop after finalization. Other results are successful only after the requested capture, project mutation, analysis, preview, or export has completed.

## Validation commands

```bash
make mcp-smoke-running
make mcp-negative-smoke
make mcp-smoke-capture
make m1b-smoke
make m1c-smoke
make m1d-smoke
make m1e-smoke
make m2a-smoke
make m2b-smoke
make m2c-smoke
make m3a-smoke
make rpc-negative-smoke
make m3a-acceptance
```

`make m1b-smoke` performs a real capture, project creation, atomic crop/arrow/text/mosaic batches, update/delete/add, stale-revision and invalid-edit checks, undo, redo, reset, restore, preview, export, file/hash/dimension validation, and original-image immutability verification.

`make m1c-smoke` performs a real Mupaw-window capture, project creation, local OCR with engine/language reporting, point and region color sampling, result-bound/coordinate/color validation, invalid-input and stale-revision checks, and proof that analysis does not change the project revision, project document, or copied original.

`make m1d-smoke` performs a real capture and project creation, applies an editable preset and a fully custom gradient/square style, validates deterministic preview/export dimensions and hashes, rejects an invalid atomic style batch, exercises undo/redo/clear/none-preset behavior, and proves the copied original remains unchanged.

`make m1e-smoke` performs real window and structured single-display region MP4 recordings, polls active state, verifies screenshot and duplicate-recording ownership errors, tests cancel/delete and missing-session behavior, and independently validates MP4 container, H.264 track, no audio track, playability, duration, dimensions, permissions, bytes, SHA-256, and preview metadata.

`make m2a-smoke` verifies the video-only compatibility path and a genuine non-silent 48 kHz stereo AAC system-audio recording with bounded synchronization.

`make m2b-smoke` discovers the current default microphone, verifies legacy dual booleans now resolve to the M2c mixed source, rejects invalid devices without creating files, acoustically records a deterministic tone through the selected microphone, verifies one non-silent 48 kHz stereo AAC final track plus device metadata and synchronization, and confirms cancellation removes partial output.

`make m2c-smoke` records a safe structured region while simultaneously capturing deterministic system audio and real acoustic microphone input. It validates separate live RMS/peak/timestamps, stale handling, invalid controls, explicit/legacy conflicts, runtime system-only/microphone-only/rebalanced phases, one final 48 kHz stereo AAC track, numerically distinct decoded phase RMS values, synchronization, hashes, permissions, playback, and cancellation cleanup.

`make m3a-smoke` discovers the current camera; rejects invalid devices, contradictory disabled requests, out-of-range start layout, and out-of-range runtime updates; records a real camera picture-in-picture over the safe animated fixture; hides, relocates, resizes, reshapes, restyles, and shows the overlay again through the shared runtime tool; verifies non-stale live frames and bounded control-event metadata; independently decodes multiple final video frames to prove the final region is visually distinct and textured; validates exactly one H.264 video track; exercises camera plus real system audio through the M2c post-processing path; and confirms cancellation removes partial output.

`make m1e-full-screen-smoke` additionally records the primary display. Cover it with non-sensitive test content first; this mode is intentionally separate from the default acceptance gate.

`make mcp-smoke-full-screen` remains separate because it records the current display. Cover the display with non-sensitive test content first. For UI/MCP capture ownership, start interactive region selection and run `make mcp-capture-conflict-smoke`.
