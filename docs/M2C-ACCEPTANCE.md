# M2c acceptance criteria

M2c is complete only when system audio and one selected microphone can be captured together, controlled independently during recording, measured live, and finalized as one validated AAC track. Camera, GIF, click/keystroke overlays, timeline editing, and zoom remain out of scope.

## Compatibility and request model

- The canonical `audio_source` values are `none`, `system_audio`, `microphone`, and `system_audio_and_microphone`.
- Requests that omit audio fields remain video-only.
- Legacy `include_system_audio` and `include_microphone` remain readable; both true select the mixed source.
- An explicit canonical source that contradicts a legacy flag fails before creating any output.
- `system_audio_gain` and `microphone_gain` are finite linear values from `0.0` through `2.0`, defaulting to `1.0`.
- `system_audio_muted` and `microphone_muted` default to `false`.
- Invalid gains or empty runtime-control updates fail atomically and create no file or control event.

## Capture and source health

- ScreenCaptureKit delivers video, system audio, and microphone input on separate callback queues; one serial writer queue owns AVAssetWriter mutation.
- Mixed mode must receive a valid first sample from video and both requested audio lanes before starting its capture timeline.
- A requested lane that does not start within four seconds, stops producing samples for three seconds, reports an invalid format, disconnects, or cannot be written fails the complete session.
- Failure, cancellation, app shutdown, and source loss delete intermediate and final partial files and return no artifact.
- Microphone permission and stable device resolution remain owned by the signed app. An unavailable device never silently switches to another input.

## Runtime controls and live levels

- UI and MCP use the same `recording_update_audio_controls` service method.
- Source and microphone device are immutable after start; gains and mute flags remain adjustable while recording.
- Control changes are appended to a bounded event timeline and returned in current/completed metadata.
- System audio and microphone status independently expose sample count, native format, last wall-clock sample time, last source timestamp, RMS, peak, and a stale flag.
- The controlled mixed-level estimate reflects current gains/mutes and becomes stale when either requested source is stale.
- PCM level analysis is bounded, thread-safe, and must not block ScreenCaptureKit delivery or AVAssetWriter.

## Final single-track pipeline

- Audio-enabled capture writes an owner-only intermediate MOV containing one H.264 track and one requested audio track, or two separate requested tracks for mixed mode.
- At stop, AVFoundation decodes the requested audio tracks to stable 48 kHz stereo PCM, applies the per-lane gain/mute event timeline, and writes exactly one AAC track to the final MP4.
- H.264 video is passed through without re-encoding during audio post-processing.
- The intermediate MOV is removed before completion is reported.
- Finalization requires exactly one playable H.264 video track and one 48 kHz stereo AAC track for every enabled audio mode.
- Final audio duration is positive and differs from video duration by no more than 0.25 seconds.
- The final file is `0600`, has matching byte count and SHA-256, and includes a bounded preview.

## Completed metadata

The artifact reports:

- canonical audio source and final AAC identity;
- selected microphone ID/name when applicable;
- final system/microphone gains and mute states;
- bounded control-event count;
- per-source sample counts, formats, durations, last timestamps, and RMS/peak summaries;
- final audio duration, sample rate, channel count, track count, and audio/video duration difference;
- existing video, source, file, hash, byte, permission, and preview metadata.

## Real-device smoke

`make m2c-smoke` launches a safe animated fixture and records a structured region so ScreenCaptureKit receives global system audio while the selected real microphone receives the same deterministic two-tone through the physical output path. It validates:

1. microphone permission, device discovery, and all M2c MCP schemas;
2. invalid gain and explicit/legacy contradiction rejection without file creation;
3. both requested inputs producing non-stale live RMS/peak measurements and source timestamps;
4. runtime phases for both sources, system-only, microphone-only, and rebalanced output;
5. one H.264 video track and exactly one 48 kHz stereo AAC final track;
6. decoded final audio with four non-silent segments, including numerically distinguishable system-only and microphone-only phases;
7. per-source nonzero summaries, four control events, synchronization at or below 0.25 seconds, valid bytes/SHA-256/preview/playability, and `0600` permissions;
8. cancellation removing both intermediate and final partial output.

The test does not inject synthetic microphone PCM into Mupaw. The microphone path remains ScreenCaptureKit input from the selected physical device; `/usr/bin/afplay` provides the deterministic acoustic stimulus.

`MupawCaptureTests.RecordingAudioHealthPolicyTests` additionally performs repeatable clock-controlled input-loss simulation. It verifies the exact production watchdog policy for a missing requested microphone after the startup deadline, a microphone that stalls after previously delivering samples, healthy dual-source operation, startup grace, and ignoring an unrequested lane.

## Full regression gate

```bash
make m2c-acceptance
```

The Mac must be unlocked with Screen & System Audio Recording and microphone permission granted to the stably signed `~/Applications/Mupaw.app`. The gate runs formatting/localization, all unit tests, stable installation, RPC/MCP negative and concurrency checks, M1a–M2b regression, and the real M2c mixed-audio smoke.

## Deferred

M2c does not capture a camera, render click or keystroke overlays, export GIF, edit an audio/video timeline, or provide manual/automatic zoom.
