# M2a acceptance criteria

M2a is complete only when optional ScreenCaptureKit system audio is added without changing the M1e video-only default. This gate does not claim microphone input, audio mixing, camera, GIF, event overlays, editing, or zoom.

## Compatibility and API

- `RecordingRequest.includeSystemAudio` defaults to `false`, including decoding older requests that omit the field.
- `mupaw_recording_start` advertises `include_system_audio` with a default of `false`.
- video-only UI and MCP recordings still finalize with one H.264 video track and zero audio tracks.
- UI and MCP call the same application-owned `RecordingService`; Agents never operate the recording UI.

## System-audio pipeline

- enabling system audio configures ScreenCaptureKit for 48 kHz stereo system audio and explicitly disables microphone capture.
- current-process audio is excluded so Mupaw feedback or UI sounds are not fed back into the recording.
- AVAssetWriter has one AAC input at 48 kHz, two channels, and a bounded target bitrate.
- video and audio first samples are buffered within explicit limits and start one writer session at the earliest valid timestamp after all requested tracks are available.
- video and audio append on one serial sample queue and preserve valid sample timestamps.
- requested audio that never arrives, has an unexpected format, cannot be written, or fails final track validation fails the recording and removes the partial file; it never silently downgrades to video-only.

## Status and artifact metadata

Active and terminal status expose:

- whether system audio was requested;
- audio state (`disabled`, `waiting`, `capturing`, `completed`, `failed`, or `cancelled`);
- AAC codec identity;
- sample rate and channel count;
- audio sample-buffer count and duration when available.

A completed audio recording additionally exposes:

- exactly one AAC audio track;
- actual audio duration;
- audio/video duration difference;
- actual sample rate and channels.

The artifact remains owner-only and includes the existing file URL, bytes, SHA-256, preview, video dimensions, duration, and frame metadata.

## Synchronization and validation

- AVFoundation confirms one playable H.264 video track.
- with audio disabled, AVFoundation confirms zero audio tracks.
- with audio enabled, AVFoundation confirms exactly one AAC track at 48 kHz stereo.
- both video and audio durations are positive.
- the final audio/video duration difference is no greater than 0.25 seconds.
- static video still receives the M1e held terminal frame; system audio remains continuous according to its source timestamps.
- stop returns only after both requested tracks are finalized and validated.

## Real-device smoke

`make m2a-smoke` launches a safe animated fixture, then performs two MCP recordings:

1. a video-only window recording that must contain one video track and zero audio tracks;
2. a structured-region recording with system audio enabled while `/usr/bin/afplay` plays an owner-only deterministic 48 kHz stereo WAV containing 440 Hz followed by 880 Hz.

The system-audio file must have:

- one H.264 video track and one AAC audio track;
- 48,000 Hz and two channels;
- decoded PCM samples with RMS above 0.01 and a nonzero peak;
- audio/video duration difference at or below 0.25 seconds;
- valid dimensions, duration, bytes, SHA-256, preview, and `0600` permissions.

The two-tone source makes the test audibly and numerically distinguishable from silence; the test removes its temporary source and fixture.

## Full regression gate

```bash
make m2a-acceptance
```

The Mac must be unlocked and in a normal desktop session. The gate runs formatting/localization, all unit tests, stable signed installation, RPC negative/concurrency tests, M1a–M1e capture/editing/analysis/style/video regression, then the real M2a audio smoke.

## Deferred

M2a does not request microphone permission, enumerate input devices, mix system audio with microphone input, expose level controls, render audio waveforms, record camera, or edit audio/video timelines.
