# Mupaw architecture

## Product invariant

A human and an Agent operate the same application-owned capture and recording services. A screenshot or finalized MP4 made through MCP must use the same artifact stores and metadata contracts as one made from the UI.

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
    ├── native region-selection overlay and global shortcuts
    ├── ScreenCaptureKit full-screen/window/region capture service
    ├── ScreenCaptureKit stream + AVAssetWriter MP4 recording service
    ├── multi-display region planner and compositor
    ├── versioned screenshot project service
    ├── shared edit, visual-style renderer, and history service
    ├── Vision OCR and bounded sRGB color analyzer
    └── capture, recording, project, and export stores
```

The helper never performs screen capture itself. This avoids a second TCC identity and keeps permissions attached to `Mupaw.app`.

## Targets

### MupawCore

Pure shared types and local transport support:

- capability and permission models;
- explicit screenshot modes and global point/pixel geometry;
- source, screenshot artifact, recording session/artifact, project, edit-command, visual-style, OCR, color-sampling, preview, and export descriptors;
- original-image pixel geometry for crop and annotation objects;
- deterministic multi-display region planning;
- RPC request/response envelopes;
- a strict request decoder and bounded response-frame encoder;
- connection descriptor storage;
- bounded local RPC client;
- filename validation.

### MupawCapture

Application-owned platform services:

- ScreenCaptureKit source enumeration with display/window frames and scale metadata;
- explicit full-screen and independent-window capture;
- structured region capture split across displays and composed into one bounded image;
- H.264 MP4 display/window/single-display-region streaming through ScreenCaptureKit and AVAssetWriter, with an optional 48 kHz stereo AAC system-audio track;
- one shared video/audio timeline, bounded initial sample queues, static-frame duration preservation, bounded resolution/bitrate/duration, owner-only files, and AVFoundation final artifact validation;
- image encoding and preview generation;
- screen, microphone, camera, accessibility, and input-monitoring permission snapshots.

### MupawEditing

Application-owned non-destructive editing services:

- project creation from a verified Mupaw capture artifact;
- owner-only project directories containing an immutable copied original and versioned JSON document;
- crop, arrow, text, and mosaic validation in original-image pixel coordinates;
- bounded persisted undo/redo history and optimistic revision conflicts;
- a single Core Graphics renderer used by preview and export;
- bounded JPEG previews and owner-only PNG exports with SHA-256 metadata.
- local Vision text recognition with bounded original-image pixel observations;
- deterministic point/region color analysis in normalized sRGB with bounded sampling.
- deterministic visual-style layout planning and Core Graphics background/card/shadow composition.

### Mupaw.app

- SwiftUI application shell with screenshot and recording workspaces and explicit source modes;
- AppKit multi-display region-selection overlay with `Esc`/right-click cancellation;
- Carbon global shortcuts with visible conflict state;
- screenshot editor canvas, layer list, object inspector, crop and beautification sheets, OCR overlays, color-sampling controls, and recording source/settings/status/artifact views;
- lifecycle for the local RPC listener;
- routing UI and RPC requests to the same screenshot, recording, editing, and analysis services;
- screenshot, recording, project, OCR, color, preview, and export presentation.

### mupaw-mcp

- official Swift MCP SDK over stdio;
- a small, stable screenshot, recording-session, editing, visual-style, OCR, and color-analysis tool catalog;
- conversion between MCP values and Mupaw RPC values;
- structured MP4 start/status/stop/cancel plus project creation, batch edits and style presets, history, OCR, color sampling, preview, and export;
- actionable errors for unavailable apps, permissions, stale revisions, invalid edits/analysis, and missing artifacts.

## M1a screenshot contract

`ScreenshotRequest` carries one explicit mode:

- `full_screen` requires an exact `display:` source ID;
- `window` requires an exact `window:` source ID;
- `region` requires a `CaptureRegion` and does not accept a source ID.

Human and Agent region capture intentionally differ only at the input boundary. The UI obtains a rectangle from a native AppKit overlay. MCP accepts a structured rectangle directly. Both then call the same `CaptureService.capture` method and produce the same artifact model.

Region coordinates use `global_display_points`: macOS global display coordinates measured in points with a top-left origin. Each display descriptor includes its global frame and `pointPixelScale`. The planner intersects the requested rectangle with every display, chooses the highest participating scale for the output canvas, requests display-local `sourceRect` slices from ScreenCaptureKit, and composites them into the requested union rectangle. Transparent pixels remain where a rectangular request spans a physical gap between displays. A global pixel-count limit prevents unbounded allocations.

Full-screen and region capture exclude Mupaw's own windows by default. Independent window capture uses the exact returned window. Only one capture operation may own the app at a time; concurrent Agent requests receive `capture_in_progress` while an interactive selection or another capture is active.

## M1b screenshot project contract

A screenshot project keeps the source capture immutable. Creation verifies that the source URL resolves inside Mupaw's `Captures` directory, recomputes SHA-256, reads dimensions, then copies the PNG into `Projects/<project-id>/original.png`. The project document stores only metadata, crop, edit objects, bounded undo/redo stacks, and monotonically increasing revision numbers.

Project get, preview, and export revalidate the copied original's SHA-256 and dimensions. Directory and file permissions are repaired on use (`0700` directories, `0600` project documents, copied originals, and exports). Source hashes, source identifiers, command batches, project objects, history, strings, dimensions, and pixel allocations all have explicit bounds.

Editing uses original-image pixels with a top-left origin. A crop changes the visible output rectangle but does not rewrite object coordinates. Arrow endpoints, text and mosaic frames, colors, line width, font size, and block size are validated against source bounds and configured limits before a mutation is committed.

`project_apply_edits` is atomic: either every command is valid and one new revision is written, or nothing changes. Mutations require `expected_revision`; mismatches return `project_version_conflict` with expected and actual revisions. Undo and redo also create new revisions, allowing clients to detect every state transition.

Preview and export call the same `ScreenshotRenderer`. The renderer loads the copied original, applies crop, then renders objects in array order. Mosaic uses a deterministic CPU downsample/upscale path rather than a separate GPU preview effect. Preview returns a bounded JPEG; export writes a PNG under `Exports`, returns actual dimensions, byte count, SHA-256, and the preview generated from the same rendered image.

The UI and MCP tools both call `ScreenshotProjectService`. Agent operations never manipulate the editor UI.

## M1c screenshot analysis contract

OCR and color sampling read the verified copied original and never mutate the project document, original file, edit content, or history. The current crop is used only as the default analysis rectangle. Rendered arrows, text annotations, and mosaic are not silently fed back into analysis.

`project_ocr` runs Apple Vision locally through the signed `mupaw-ocr-helper` bundled inside `Mupaw.app`. The short-lived helper isolates Vision from ScreenCaptureKit and the long-running UI process, works only inside one owner-only temporary directory, returns bounded Codable data, and is terminated after a 120-second safety timeout. The RPC client allows 150 seconds for the cold Vision path. The service validates an optional original-image pixel rectangle, bounded language hints, recognition level, language-correction setting, and minimum confidence. Very large regions are scaled down to a maximum 4,096-pixel input dimension. Vision lower-left normalized rectangles are converted into original-image pixel rectangles with a top-left origin, filtered, deterministically ordered, and bounded before crossing RPC. Natural Language identifies each observation language only when the text and confidence are sufficient and returns `und` otherwise. The result reports the Vision engine, explicit recognition-language hints, detected languages, and is limited to 512 observations, 4,096 UTF-8 bytes per observation, and 256 KiB of joined text.

`project_color_sample` converts the copied original into sRGB. Point mode reads exactly one in-bounds pixel. Region mode downsamples deterministically to at most 256 pixels on either axis and no more than 65,536 samples, then reports average, center, and a stable 5-bit-per-channel dominant color bucket. Each color reports normalized RGBA, hexadecimal RGB/RGBA, relative luminance, and dark/light classification together with the actual sample count.

Both human UI and MCP call `ScreenshotProjectService`. Analysis accepts an optional `expected_revision` to detect stale context but never creates a new revision. Project get, OCR, color sampling, preview, and export first revalidate the copied original's SHA-256 and dimensions.

## M1d screenshot visual-style contract

Visual style is optional revisioned project content. Project schema version 1 remains readable because a missing `visualStyle` field decodes as `nil`; the unstyled renderer returns the same crop-and-annotation image as M1b/M1c. Styling never rewrites the copied original or annotation coordinates.

The style model contains a solid or two-color linear-gradient background, bounded canvas padding, one of six output aspect choices, screenshot-card corner radius, and an optional bounded shadow with color, blur, and offsets. Built-in presets (`none`, `clean_white`, `soft_gray`, `ocean`, `sunset`, and `midnight`) are only structured parameter sets and may be replaced by a fully custom style.

`ScreenshotStyleLayoutPlanner` computes one deterministic output canvas and a top-left pixel card frame. It reserves padding and the full bounded shadow footprint, expands the canvas rather than cropping when an aspect ratio is requested, centers the composition, and rejects allocations above the global screenshot pixel limit.

`ScreenshotRenderer` uses the canonical order: source crop and annotations, rounded alpha card, Core Graphics shadow, then solid/gradient background canvas. Preview and export consume the exact same final `CGImage`. The UI maps object, OCR, and color coordinates through the card frame inside the styled output; background pixels do not map to original-image coordinates.

`set_visual_style`, `apply_style_preset`, and `clear_visual_style` are normal `project_apply_edits` commands. They require the current revision, participate in atomic batches and persisted undo/redo, and `reset` clears style together with crop and edit objects. Invalid style geometry, colors, shadow values, or output allocations reject the whole batch.

## M1e/M2a/M2b/M2c MP4 recording contract

M1e established video-only H.264 MP4 through one `RecordingService` owned by `Mupaw.app`. M2a added optional ScreenCaptureKit system audio, M2b added one selected microphone, and M2c adds controlled dual-source mixing while preserving the original default: omitted audio fields still produce exactly one video track and zero audio tracks. The canonical source is `none`, `system_audio`, `microphone`, or `system_audio_and_microphone`; both legacy include booleans map to the mixed source, while explicit/legacy contradictions fail before output creation.

Microphone permission and device discovery are owned by the signed app. `MicrophoneDeviceService` uses AVFoundation discovery to return stable device IDs, names, manufacturer, connection state, and the current default. Start resolves the exact requested device or current default only after permission is authorized. A device disconnect notification fails the active session and deletes partial output instead of switching inputs silently. MCP forwards structured IDs and never operates the UI.

`recording_start` validates a returned display/window source or finite single-display region, 15/30/60 fps, bounded Standard/High video bitrate, one canonical audio source, gains from 0.0 through 2.0, independent mute flags, and a sanitized final destination under the owner-only `Recordings` directory. ScreenCaptureKit provides BGRA video, 48 kHz stereo system PCM, and device-native microphone PCM on separate callback queues. Current-process system audio is excluded. A single serialization queue owns all AVAssetWriter mutation, live per-source measurement, and bounded control-event history.

Audio-enabled capture writes an owner-only intermediate MOV. It contains one H.264 track and one requested source track, or two separate source tracks for mixed mode. The writer buffers bounded first samples and does not start its timeline until video and every requested audio lane are present. A 500 ms watchdog enforces a four-second initial-source deadline and a three-second ongoing sample-stall deadline. Missing, stalled, invalid, disconnected, or unwritable requested input fails the whole session and deletes intermediate/final output; there is no silent downgrade.

Per-source PCM analysis computes bounded RMS and peak without blocking capture. Active status reports input sample counts, native format, last wall/source timestamps, stale state, current controls, and an estimated controlled mixed level. `recording_update_audio_controls` atomically appends bounded gain/mute events to the same service-owned timeline. The UI uses this exact method; source/device changes remain locked during recording.

At stop, `RecordingAudioPostProcessor` reads the intermediate tracks through AVAssetReader, applies the per-lane control-event timeline with `AVAudioMix`, converts to stable 48 kHz stereo PCM, passes through H.264 video without re-encoding, and writes one final 48 kHz stereo AAC track in MP4. The intermediate MOV is removed before success is returned. This two-stage design ensures mixed mode never masquerades as two AAC tracks in the final artifact.

Unchanged screen content may not produce repeated video frames, so the last valid frame is retimed at stop to preserve wall-clock duration. Completion waits for AVFoundation validation: one playable H.264 video track; zero audio tracks for `none`; otherwise exactly one 48 kHz stereo AAC track; positive requested-source input and final-audio durations; audio/video duration difference at most 250 ms; valid dimensions, `0600` permissions, bytes, SHA-256, and preview.

Completed metadata includes actual video/audio duration, frame count, per-source sample counts and level summaries, microphone device identity, final controls and control-event count, sample rate/channels, synchronization difference, dimensions, bytes, SHA-256, file URL, timestamps, and preview. M2c intentionally excludes camera, GIF, click/keystroke overlays, timeline editing, and manual/automatic zoom.

## Local RPC security

- bind only to loopback;
- use an ephemeral port;
- generate a random bearer token per app launch;
- save the descriptor under the user's Application Support directory;
- set descriptor permissions to owner read/write only;
- cap every newline-delimited request or response frame at 4 MiB, including the delimiter;
- accept exactly one JSON request per connection in M0;
- decode the wire method as a string first so an unsupported method returns `unknown_method` instead of collapsing into a generic decoding error;
- preserve a bounded, valid request ID on structured errors; use `unknown` when no safe ID can be trusted;
- validate the protocol version and bearer token before resolving or dispatching the requested method;
- replace an oversized encoded response with a small `frame_too_large` response carrying the same safe request ID;
- tolerate interrupted system calls and peer disconnects without terminating the app.

This is a local development contract, not a remote API. A later XPC migration remains possible because the domain request/response types are transport-neutral.

The deterministic codec tests cover malformed structures and oversized-response fallback. A raw loopback smoke test additionally exercises the running app with bad tokens, unknown methods, malformed JSON, oversized frames, early disconnects, and concurrent connections.

## Milestone evolution

- M0: source enumeration, base screenshot, permissions, RPC, MCP — complete.
- M1a: explicit full-screen/window/region capture, native selection overlay, global shortcuts, structured Agent regions — complete.
- M1b: non-destructive crop, arrow, text, mosaic, history, shared preview/export, and Agent editing tools — complete.
- M1c: Apple Vision OCR, point color picking, bounded region color summaries, UI overlays, and Agent analysis tools — complete.
- M1d: non-destructive backgrounds, aspect canvases, padding, rounded cards, shadows, editable presets, and Agent style commands — complete.
- M1e: application-owned video-only H.264 MP4 display/window/single-display-region recording with stable sessions, final artifact validation, UI, and Agent tools — complete.
- M2a: optional ScreenCaptureKit system audio encoded as validated 48 kHz stereo AAC on the shared MP4 timeline — complete.
- M2b: permission-aware microphone discovery and one selected microphone encoded as validated 48 kHz mono/stereo AAC, with device metadata and disconnect cleanup — complete.
- M2c: system-audio/microphone capture, independent runtime gain/mute controls, live per-source metering, bounded source-health enforcement, and one validated final mixed AAC track — complete.
- S2: scrolling capture, partial-result stitching, and GIF.
- M3: camera overlay, click and keystroke events, manual zoom timeline.
- M4: automatic focus/zoom suggestions and editable super-recording workflow.
