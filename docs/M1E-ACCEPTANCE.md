# M1e acceptance criteria

M1e adds application-owned, video-only H.264 MP4 recording to the completed screenshot pipeline. It does not claim system audio, microphone, camera overlay, GIF, click or keystroke visualization, zoom editing, or scrolling long screenshots.

## Build, localization, and regression

- `make format`, `make localization-check`, `make lint`, `make build`, and `make test` succeed with Swift 6 strict concurrency;
- English and Simplified Chinese have identical workspace, recording, status, metadata, and error key sets;
- the historical M1a–M1d screenshot, project, OCR, color, style, preview, and export acceptance flows still pass;
- generated projects/builds, captured media, signing configuration, temporary test surfaces, and user-specific paths are not committed.

## Recording sources and output contract

M1e supports:

- an exact `display:` source returned by source discovery;
- an exact independent `window:` source returned by source discovery;
- a structured `global_display_points` region wholly contained by one active display.

Every successful completed artifact must be:

- an MP4 container with exactly one playable H.264 video track;
- free of system-audio and microphone tracks;
- even-sized and aspect-preserving, with no side above 3,840 pixels and no more than 3,840 × 2,160 pixels;
- written under the owner-only `Recordings` directory with file mode `0600`;
- accompanied by actual duration, dimensions, requested/average frame rate, frame count, bytes, SHA-256, source metadata, creation/completion timestamps, and bounded preview.

Frame rate is limited to 15, 30, or 60 fps. Quality is `standard` or `high` and maps to a bounded H.264 bitrate. Filenames are sanitized, destinations are controlled by Mupaw, and session history is bounded.

## Session lifecycle and ownership

- `recording_start` returns a stable UUID only after ScreenCaptureKit starts;
- `recording_status` returns active or retained terminal state;
- `recording_stop` returns completion only after AVAssetWriter and AVFoundation validation finish;
- repeated stop for an already completed retained session is idempotent;
- `recording_cancel` removes the incomplete MP4 and returns `cancelled` without an artifact;
- unexpected stream, writer, source, or finalization failure removes incomplete output and retains `failed` without an artifact;
- one recording session may be active at a time;
- screenshot capture/selection and recording start/finalization cannot own the app simultaneously;
- an unknown session produces `recording_not_found` and a competing start produces `recording_in_progress`.

## Static-source duration

ScreenCaptureKit may deliver only an initial frame when a display or window remains unchanged. Mupaw retains the latest valid sample and appends one retimed terminal frame at stop. A static source recorded for more than the minimum duration must produce a playable MP4 whose AVFoundation duration tracks wall-clock recording time rather than an empty or one-frame-duration file.

## Human UI

- the main sidebar switches between Screenshot and Recording without discarding the active screenshot project;
- Recording exposes display/window/region modes, pointer inclusion, 15/30/60 fps, Standard/High quality, source selection, and start;
- human region recording uses the native AppKit selector and cancellation creates no file;
- an active session shows source, dimensions, frame rate, elapsed duration, stop, and cancel;
- the main header shows active recording state;
- a completed artifact shows a real preview, duration, dimensions, average frame rate, codec/container, bytes, SHA-256, and file path;
- screenshot controls are disabled while recording owns the service.

## Agent/MCP

The advertised tool catalog contains:

```text
mupaw_recording_start
mupaw_recording_status
mupaw_recording_stop
mupaw_recording_cancel
```

- full-screen/window start requires an exact returned source ID;
- region start accepts structured coordinates and never simulates UI input;
- invalid mode/source/region, unsupported frame rate/quality/format, oversized output, and cross-display region requests fail explicitly;
- completed stop includes the same artifact and preview metadata shown by the human UI;
- MCP stdout remains protocol-only and the app remains the sole ScreenCaptureKit/TCC identity.

## Reproducible commands

```bash
make m1e-acceptance
```

This gate performs localization/lint, all unit tests, stable signed installation, raw RPC negative and concurrency tests, historical M1a–M1d real flows, then M1e window and region recording, active polling, ownership conflicts, cancellation, MP4 track inspection, duration/dimension/permission/byte/hash/preview validation, and post-error recovery.

Full-screen recording is separate because it captures the current display:

```bash
make m1e-full-screen-smoke
```

Cover the display with non-sensitive test content first. The full-screen gate must independently verify a playable 3,840 × 2,160-or-smaller H.264 MP4 with zero audio tracks and no new Mupaw crash report.

## Deferred

M1e does not claim system audio, microphone mixing, camera overlay, GIF recording/export, click highlighting, keystroke display, manual zoom timeline, automatic focus/zoom, cross-display video composition, or rolling/long capture.
