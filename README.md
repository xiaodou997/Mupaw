# Mupaw

[![License: PolyForm Noncommercial 1.0.0](https://img.shields.io/badge/license-PolyForm%20Noncommercial%201.0.0-5b5b5b.svg)](LICENSE)

Mupaw is a source-available native macOS 26+ screenshot and screen-recording application designed for both people and Agents.

Mupaw currently includes the M0 foundation, M1a capture modes, M1b screenshot editing, M1c local screenshot analysis, M1d visual styling, M1e MP4 recording, M2a system audio, M2b microphone recording, M2c controlled system-audio/microphone mixing, and M3a camera picture-in-picture:

- explicit full-screen, window, and region PNG capture;
- a native AppKit region-selection overlay with cancellation and multi-display-aware geometry;
- global shortcuts for full screen, frontmost window, and region selection;
- non-destructive, persisted, revisioned screenshot projects;
- crop, arrow, text, and mosaic editing with selection, movement, resizing, deletion, reset, undo, and redo;
- one shared renderer for UI preview, Agent preview, and final PNG export;
- native local OCR using Apple Vision in a signed short-lived helper process, including engine metadata, confidence, detected language, and original-image pixel rectangles;
- point color picking and bounded region color summaries in sRGB;
- non-destructive screenshot beautification with solid/gradient backgrounds, padding, output aspect ratios, rounded corners, bounded shadows, and editable presets;
- application-owned H.264 MP4 recording for displays, independent windows, and structured single-display regions, with no audio, system audio, one selected microphone, or both sources mixed into one 48 kHz stereo AAC track;
- independent system/microphone gains and mute controls that remain adjustable during recording, plus per-source live RMS/peak meters and stale-sample reporting;
- permission-aware camera discovery and a selected camera composited into the single H.264 video track, with runtime visibility, corner, size, circle/rounded-rectangle shape, bounded corner radius, safe margin, and layout-preview controls;
- structured Agent capture, recording, editing, OCR, and color-analysis tools that never simulate Mupaw UI clicks;
- ScreenCaptureKit capture owned by one stably signed app identity;
- a local authenticated RPC bridge and MCP stdio server;
- English and Simplified Chinese localization from the first version;
- deterministic models, tests, and local acceptance commands.

Long scrolling screenshots, GIF export, click highlights, keystroke display, timeline editing, and manual/automatic zoom remain planned. They are not part of M3a.

## Screenshot modes

The app provides three explicit modes:

- **Full Screen** captures an exact display returned by ScreenCaptureKit. Mupaw windows are excluded by default.
- **Window** captures an exact independent window returned by source discovery.
- **Region** lets a person drag across one or more displays, or lets an Agent provide a structured rectangle.

Default global shortcuts are:

```text
Control + Option + Command + 1   Full screen under the pointer
Control + Option + Command + 2   Frontmost eligible window
Control + Option + Command + 3   Interactive region selection
```

Shortcut conflicts are shown in the app and can be retried. Interactive region selection can be cancelled with `Esc` or a right-click and creates no artifact when cancelled.

Agent region coordinates use the stable `global_display_points` coordinate space: macOS global display coordinates measured in points, with a top-left origin. `mupaw_sources_list` returns global frames and point-to-pixel scales for displays and windows.

## Screenshot editing

Every screenshot created through the app becomes an editable project without changing the original capture. Mupaw copies the original PNG into its project directory, records its SHA-256 and dimensions, and stores crop and annotation objects separately in a versioned JSON document.

Project creation accepts only files in Mupaw's capture directory and verifies the supplied SHA-256. Reading, previewing, and exporting a project recheck the copied original's hash and dimensions, so local corruption is reported instead of silently rendering a different source.

The editor currently supports:

- non-destructive crop;
- arrows with adjustable endpoints, color, and line width;
- text with editable content, color, frame, and font size;
- mosaic regions with adjustable frame and block size;
- object selection, movement, resizing, layer selection, deletion, reset, undo, and redo;
- PNG export while keeping the source capture and project editable.

Editing coordinates use original-image pixels with a top-left origin. Preview and export run through the same renderer, so a completed preview and export at the same project revision represent the same composed image.

Agents use `mupaw_project_create`, `mupaw_project_get`, `mupaw_project_apply_edits`, `mupaw_project_history`, `mupaw_project_preview`, and `mupaw_project_export`. Mutating calls require `expected_revision`; stale callers receive `project_version_conflict` rather than overwriting newer work.

A batch is bounded to 1,000 commands and is atomic: any invalid command rejects the entire batch without advancing the revision.

## Screenshot beautification

M1d stores visual styling beside crop and annotations without altering the original screenshot. The renderer applies edits in one deterministic order:

```text
crop and annotations → rounded screenshot card → shadow → background canvas
```

The editor provides six built-in parameter presets—None, Clean White, Soft Gray, Ocean, Sunset, and Midnight—and every preset remains fully editable. Custom controls include:

- solid or two-color linear-gradient backgrounds;
- canvas padding;
- automatic, 1:1, 4:3, 16:9, 3:4, and 9:16 output canvases;
- screenshot-card corner radius;
- optional shadow color, blur, and horizontal/vertical offsets.

Old M1b/M1c project documents omit `visualStyle` and continue to render byte-for-byte through the unstyled path. Styled projects use the same renderer for the human editor preview, MCP preview, and final PNG export. Agents apply `set_visual_style`, `apply_style_preset`, and `clear_visual_style` through `mupaw_project_apply_edits`; these commands participate in normal optimistic revisioning, undo, redo, reset, and atomic batches.

## OCR and color sampling

M1c analyzes the immutable project original rather than the rendered annotations. The current crop is used as the default OCR or region-sampling area; callers can also provide an explicit rectangle in original-image pixels with a top-left origin. Analysis is read-only and never advances the project revision.

The human editor provides:

- local Apple Vision OCR for the current crop or full screenshot;
- selectable OCR rectangles, ordered text, confidence, detected language, and one-click copy of all or individual results;
- click-to-pick point color from the screenshot canvas;
- a movable and resizable region sampler;
- normalized sRGB RGBA values, hexadecimal RGB/RGBA, luminance, and dark/light classification;
- average, center, and deterministic dominant colors for a region, plus the bounded sampled-pixel count.

Agents use `mupaw_project_ocr` and `mupaw_project_color_sample`. OCR reports the effective Apple Vision engine (`vision_fast` or `vision_accurate`), recognition-language settings, result-level detected languages, and a language code for every observation (`und` when confidence is insufficient). It returns at most 512 bounded observations and limits combined recognized text to 256 KiB. Color region analysis downsamples to at most 256 pixels on either axis and at most 65,536 sampled pixels. Project get, OCR, color sampling, preview, and export all revalidate the copied original before reading it.

## MP4 recording, audio sources, and camera picture-in-picture

M1e added one application-owned H.264 MP4 recording session using ScreenCaptureKit and AVAssetWriter. M2a added system audio, M2b added a selectable microphone, M2c added **System Audio + Microphone** mixing, and M3a adds optional camera picture-in-picture. Audio source and microphone/camera device selections lock during recording. M2c audio gains/mutes and M3a camera visibility/layout/style controls remain adjustable through the same application-owned `RecordingService`.

Human region recording reuses the native region selector. Agent region recording uses `global_display_points` directly. Regions must remain inside one display; cross-display screenshots continue to work, while cross-display video composition is deferred.

The canonical request field is `audio_source` with `none`, `system_audio`, `microphone`, or `system_audio_and_microphone`. Legacy `include_system_audio` and `include_microphone` remain readable; both true resolve to the mixed source. An explicit canonical source that contradicts a legacy flag is rejected before creating a file. Gains are bounded linear values from `0.0` through `2.0`, default to `1.0`, and each source has an independent mute flag.

Mupaw enumerates microphone devices through AVFoundation and exposes stable device IDs, names, the current default, connection state, and microphone permission through `mupaw_microphones_list`. A microphone request may name an exact returned device or omit the device ID to use the current system default. Permission denial, an unknown device, or a device disconnect fails explicitly and removes partial output instead of silently switching devices or returning a video-only artifact.

M3a similarly exposes camera permission and stable camera IDs through `mupaw_cameras_list`. A camera overlay request may use the current default camera or one exact returned ID, and configures visibility, one of four corners, three bounded sizes, a circle or rounded rectangle, a `0.0...0.5` rounded-rectangle corner-radius fraction, and a `0.0...0.15` safe-margin fraction. AVFoundation camera frames are aspect-filled, clipped, and CPU-composited with VideoToolbox and Core Graphics before AVAssetWriter so the completed file still contains exactly one H.264 video track. The camera must start within four seconds and remain live; device disconnect, a three-second frame stall, invalid frames, composition failure, or writer failure fails the whole session and removes partial output rather than silently dropping the overlay.

During capture, ScreenCaptureKit provides separate video, system-audio, and microphone callbacks. Mupaw serializes them into an owner-only intermediate MOV, waits for every requested lane within a bounded startup period, and fails if a requested lane later stops producing samples. At stop, AVFoundation applies the recorded gain/mute event timeline and renders the requested source or mix into exactly one 48 kHz stereo AAC track in the final MP4. The intermediate file is deleted before success is reported.

Active status includes current controls and separate system/microphone sample counts, formats, timestamps, RMS, peak, and stale flags. The UI renders smoothly animated meters for both inputs and an estimated controlled mixed output. `mupaw_recording_update_audio_controls` provides the same runtime control path to Agents without simulating UI actions.

Camera-enabled status reports the selected device, current visibility/layout/style, source dimensions, input-frame count, most recent wall/source timestamps, stale state, and bounded camera control-event count. `mupaw_recording_update_camera_overlay` changes visibility, position, size, shape, corner radius, or safe margin without restarting capture or changing the device. Completed metadata records the final configuration and top-left-origin overlay rectangle. UI and MCP call the same `RecordingService`; Agents never simulate camera controls.

Recording output is bounded to even dimensions, a maximum 3,840-pixel side and 3,840 × 2,160 total pixels. Very large sources are scaled down without changing aspect ratio. Files are stored under the owner-only `Recordings` directory and finalized only after Mupaw verifies:

- one playable H.264 video track, with any requested camera overlay already baked into its frames;
- zero audio tracks for `none`, or exactly one 48 kHz stereo AAC track for every enabled single-source or mixed recording;
- actual video/audio duration, dimensions, per-source sample counts and level summaries, selected device, final controls/control-event count, sample rate, channels, requested and average frame rate, and synchronization difference;
- an audio/video duration difference no greater than 250 ms when audio is enabled;
- file byte count, SHA-256, a bounded preview, and `0600` permissions.

Static windows and displays may not produce repeated ScreenCaptureKit frames. Mupaw therefore holds the last video frame through the wall-clock stop time so a still screen produces a correctly timed MP4. Requested audio is never silently substituted or dropped.

Agents use `mupaw_microphones_list`, `mupaw_cameras_list`, `mupaw_recording_start`, `mupaw_recording_status`, `mupaw_recording_update_audio_controls`, `mupaw_recording_update_camera_overlay`, `mupaw_recording_stop`, and `mupaw_recording_cancel`. UI and MCP calls use the same `RecordingService`; Agents never simulate microphone, camera, or recording controls.

## Requirements

- macOS 26 or later
- Xcode 27 or later for the current development environment
- XcodeGen

## Build

```bash
make generate
make localization-check
make lint
make build
make test
```

Install the signed development app at a stable path and open it:

```bash
make run
```

The stable development path is:

```text
~/Applications/Mupaw.app
```

macOS privacy permissions are tied to the app's code identity. The default local build is ad-hoc signed, so replacing it can require granting Screen & System Audio Recording permission again. To keep a stable identity, copy `.mupaw.local.mk.example` to `.mupaw.local.mk` and set an Apple Development or Developer ID Application identity available in your keychain:

```make
DEV_CODE_SIGN_IDENTITY := Apple Development: Your Name (TEAMID)
```

The local signing file is ignored by Git. Configure the identity before granting screen-recording permission for the most stable development workflow.

Open the macOS Screen & System Audio Recording settings pane:

```bash
make open-screen-recording-settings
```

Open the macOS microphone privacy pane:

```bash
make open-microphone-settings
```

Open the macOS camera privacy pane:

```bash
make open-camera-settings
```

Validate the MCP executable without requiring the app to be open:

```bash
make mcp-smoke
```

After Mupaw is running, validate the live app bridge as well:

```bash
make mcp-smoke-running
```

After granting Screen & System Audio Recording permission, run real MCP window and structured-region captures and validate their files, hashes, metadata, and previews:

```bash
make mcp-smoke-capture
```

A full-screen MCP smoke test is intentionally separate because it captures the current display. Cover the display with non-sensitive test content before running it:

```bash
make mcp-smoke-full-screen
```

Exercise MCP argument failures and recovery, then exercise the authenticated loopback RPC directly with invalid tokens, unknown methods, malformed JSON, oversized frames, disconnects, and concurrent calls:

```bash
make mcp-negative-smoke
make rpc-negative-smoke
```

Run the complete M3a acceptance sequence. It checks formatting and localization, runs all capture/editing/analysis/style/recording tests, rebuilds and restarts the stably signed app, performs negative and concurrency checks, validates M1a–M2c, then records real camera picture-in-picture through MCP. The M3a gate verifies camera permission/device discovery, bounded start/runtime configuration, live hide/show and layout updates, frame health, a single baked H.264 video track, visual distinction of the final overlay region, camera plus system-audio post-processing, metadata, cancellation cleanup, permissions, bytes, SHA-256, and playability:

```bash
make m3a-acceptance
```

`make m3a-acceptance` expects the stable signing identity in `.mupaw.local.mk`, an unlocked desktop session, Screen & System Audio Recording, microphone, and camera permissions, plus connected microphone and camera devices for `~/Applications/Mupaw.app`. Historical `m0-acceptance` through `m2c-acceptance` gates remain available; `make m2c-acceptance` remains the dedicated real mixed-audio gate.

Focused flows can be rerun with:

```bash
make m1b-smoke
make m1c-smoke
make m1d-smoke
make m1e-smoke
make m2a-smoke
make m2b-smoke
make m2c-smoke
make m3a-smoke
```

To validate UI/MCP conflict handling, begin an interactive region selection and, before completing it, run:

```bash
make mcp-capture-conflict-smoke
```

The MCP request must return `capture_in_progress`; cancel the overlay with `Esc` afterward.

Full-screen MP4 validation is deliberately separate because it records the current display. Cover the display with non-sensitive test content before running:

```bash
make m1e-full-screen-smoke
```

Open the generated project when UI debugging is needed:

```bash
open Mupaw.xcodeproj
```

## Localization

The first version ships with English (`en`) and Simplified Chinese (`zh-Hans`). Mupaw follows the language selected by macOS, including the per-application language override in System Settings. UI strings and privacy usage descriptions are localized; MCP tool names and protocol identifiers remain stable English identifiers.

Run `make localization-check` after changing translations. It verifies that both languages contain the same keys and that required privacy descriptions are present. See `docs/LOCALIZATION.md` for the extension workflow.

## Repository layout

- `Sources/MupawCore`: shared capture/recording/editing/style models, geometry and layout planning, bounded RPC codec, storage paths, and client code
- `Sources/MupawCapture`: ScreenCaptureKit screenshot and video streams, AVAssetWriter MP4 finalization, source discovery, composition, artifact encoding, and permission services
- `Sources/MupawEditing`: project persistence, edit/style validation, shared beautification renderer, OCR analysis services, color sampling, previews, history, and PNG export
- `Sources/MupawApp`: native screenshot/recording/editor/analysis/beautification UI, region overlay, global shortcuts, and local RPC server
- `Sources/MupawOCRHelper`: short-lived signed Apple Vision worker bundled under `Mupaw.app/Contents/Helpers`
- `Sources/MupawMCP`: MCP stdio bridge for Agent clients
- `Resources/MupawApp`: localized UI and Info.plist resources
- `Tests`: deterministic unit tests
- `scripts`: reproducible localization, MCP, raw RPC, and real-capture smoke tests
- `docs`: architecture, localization, MCP contract, and milestone acceptance criteria

## Licensing

Mupaw is source-available under the [PolyForm Noncommercial License 1.0.0](LICENSE), identified by SPDX as `PolyForm-Noncommercial-1.0.0`.

You may inspect, use, modify, and redistribute Mupaw only for purposes permitted by `LICENSE`. The public license does not grant commercial-use rights. Commercial use requires separate written permission from the copyright holder, and Mupaw does not currently offer a commercial license.

PolyForm Noncommercial is not an OSI-approved open-source license, so Mupaw must be described as **source-available**, not open source. Copies and distributions must preserve the `Required Notice:` line in `LICENSE`. Third-party dependencies retain their own license terms.

See [CONTRIBUTING.md](CONTRIBUTING.md) for contribution and copyright rules.
