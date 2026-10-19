# M2b acceptance criteria

M2b is complete only when one selected microphone can be recorded independently without changing the video-only or system-audio contracts. Mixing, level controls, camera, GIF, event overlays, editing, and zoom remain out of scope.

## Compatibility and source selection

- The canonical audio source is `none`, `system_audio`, or `microphone`.
- Requests that omit audio fields remain video-only.
- Legacy `include_system_audio` and `include_microphone` decode to the corresponding source.
- Simultaneous or contradictory source requests return `audio_mixing_not_supported` before creating an output file.
- A microphone device ID is accepted only for microphone audio.

## Permission and device discovery

- The signed app exposes microphone permission separately from Screen & System Audio Recording permission.
- The UI can request permission and open the microphone privacy settings pane.
- `mupaw_microphones_list` reports permission, the current default ID, stable device IDs, names, manufacturers when available, connection state, and default hints.
- Omitting a device ID uses the current connected default; an exact requested ID must be returned by discovery.
- Unknown, unavailable, or disconnected devices fail explicitly and remove partial output.
- Permission denial or an unavailable microphone does not break screenshots, video-only recording, or system-audio recording.

## Microphone pipeline

- ScreenCaptureKit microphone output is enabled only for `microphone`; system audio and microphone are never active together in M2b.
- The selected device ID is passed to ScreenCaptureKit.
- The first valid microphone sample creates one real-time AAC writer input using the device format as a source hint.
- Input may be device-native PCM; output is 48 kHz AAC with one or two channels.
- Video and microphone samples use one AVAssetWriter timeline and serial append queue.
- Requested microphone audio that never arrives, cannot be encoded, or fails final validation never silently downgrades to video-only.

## Status and completed metadata

Active and completed status expose:

- audio source and state;
- selected microphone device ID and name;
- AAC identity;
- sample rate and channels;
- sample-buffer count and audio duration;
- final audio/video duration difference.

Completion requires one playable H.264 video track and exactly one 48 kHz mono/stereo AAC microphone track, positive audio duration, and an audio/video duration difference no greater than 0.25 seconds. File ownership, bytes, SHA-256, preview, dimensions, and duration must also validate.

## UI and Agent behavior

- The recording UI offers `None`, `System Audio`, and `Microphone` as mutually exclusive choices.
- Selecting microphone shows permission controls and a device picker; all audio/source controls lock while recording.
- UI and MCP call the same `RecordingService`; Agents query devices and never simulate the UI.
- Cancel and failure remove incomplete MP4 files and return no artifact.

## Real-device smoke

`make m2b-smoke` launches a safe animated fixture, selects the current default microphone, and plays an owner-only deterministic 48 kHz two-tone through the system output so the microphone captures genuine acoustic audio. It validates:

- microphone permission and at least one connected input device;
- mixing rejection and no file creation;
- invalid-device rejection and no file creation;
- active microphone source/device/sample metadata;
- one H.264 video track and one AAC microphone track;
- 48 kHz mono/stereo output;
- decoded audio samples with RMS at or above 0.0001 and a nonzero peak;
- audio/video duration difference at or below 0.25 seconds;
- valid bytes, SHA-256, preview, playback, and `0600` file permissions;
- cancellation removes the partial file.

The threshold is deliberately low because laptop/headset acoustic coupling varies; it still requires real nonzero decoded microphone samples rather than an empty or synthetic track.

## Full regression gate

```bash
make m2b-acceptance
```

The Mac must be unlocked with Screen & System Audio Recording and microphone permission granted to the stably signed `~/Applications/Mupaw.app`. The gate runs formatting/localization, all unit tests, stable installation, RPC/MCP negative and concurrency checks, M1a–M2a regression, and the real microphone smoke.

## Deferred

M2b does not mix system audio and microphone input, select independent gain levels, mute tracks, render meters/waveforms, capture camera, or edit audio/video timelines.
