# M3a acceptance criteria

M3a is complete only when one permission-authorized camera can be selected explicitly, monitored for frame health, and composited into the completed recording as picture-in-picture inside the single H.264 video track. Click/keystroke overlays, GIF, timeline editing, and manual/automatic zoom remain out of scope.

## Compatibility and request model

- Requests that omit `camera_overlay`, or provide `enabled: false` without a device ID, preserve all M0–M2c behavior.
- Camera picture-in-picture is optional and independent of the four existing audio modes.
- An enabled overlay may name one exact ID from `mupaw_cameras_list` or omit it to use the current connected default.
- A camera ID while the overlay is disabled, an unknown ID, unavailable permission, or no connected default fails before an output file is created.
- Position is limited to `top_left`, `top_right`, `bottom_left`, or `bottom_right`; size to `small`, `medium`, or `large`; shape to `circle` or `rounded_rectangle`; rounded-rectangle corner radius to `0.0...0.5`; and safe margin to `0.0...0.15`.
- The camera device is immutable after start. Visibility, position, size, shape, corner radius, and safe margin remain adjustable through the shared `recording_update_camera_overlay` service path; M2c audio gain/mute updates remain available during the same recording.

## Permission and discovery

- The stably signed `Mupaw.app` owns camera permission and AVFoundation discovery.
- The UI can request camera permission and open the macOS camera privacy pane.
- `mupaw_cameras_list` reports permission, default device ID, stable IDs, localized names, manufacturers when available, device position, connection state, and default hints.
- UI and MCP use the same `CameraDeviceService` and `RecordingService`; Agents never simulate camera controls.

## Capture and composition

- `RecordingCameraCaptureSession` uses one exact AVFoundation device and a bounded HD capture preset, producing BGRA frames on a dedicated queue.
- Recording does not begin its shared writer timeline until ScreenCaptureKit video, every requested audio lane, and the first valid camera frame are available.
- `RecordingCameraLayoutPlanner` deterministically maps the selected corner, size, and shape into a bounded top-left-origin rectangle inside the final video dimensions.
- Camera frames and the latest ScreenCaptureKit frame are CPU-composed through VideoToolbox conversion and Core Graphics before AVAssetWriter; camera-driven output is bounded by the requested recording frame rate.
- Camera input is aspect-filled, clipped by the selected circular or rounded-rectangle mask, and blended over the screen frame. Hidden mode emits screen-only frames while camera capture and health enforcement continue.
- The completed MP4 contains exactly one H.264 video track. A second video track is not an acceptable substitute for picture-in-picture.
- The held terminal frame used for static sources is the latest composed frame when camera is enabled.

## Camera health and failure behavior

- The first valid camera frame must arrive within four seconds.
- After camera capture begins, three seconds without a new frame is a source stall.
- Camera runtime errors, device disconnect, invalid pixel buffers, composition failure, AVAssetWriter failure, or invalid final metadata fail the complete recording.
- Camera failure never silently downgrades to screen-only recording.
- Failure, cancellation, app shutdown, source loss, and device disconnect remove intermediate and final partial files and return no artifact.

## Status and completed metadata

Active and completed status expose:

- camera requested/state;
- exact selected device ID and name;
- current/final visibility, position, size, shape, corner radius, safe margin, and overlay rectangle;
- camera source pixel dimensions;
- received camera input-frame count;
- most recent camera wall-clock time and source timestamp;
- stale state based on recent-frame age.
- bounded camera control-event count.

Completed metadata must report a nonzero camera frame count and valid device/layout data when camera was requested, while camera-disabled recordings retain `requested: false` and `state: disabled`.

## Final artifact validation

Completion requires:

- one playable H.264 video track with the requested overlay visually baked into its frames;
- the existing M2c audio-track requirements for the selected audio mode;
- valid video/audio duration and synchronization bounds;
- owner-only `0600` file permissions;
- matching byte count and SHA-256;
- a bounded preview;
- no retained intermediate MOV or other partial output.

## Real-device smoke

`make m3a-smoke` launches the safe animated recording fixture and uses the current connected camera. It validates:

1. camera permission, discovery, default/exact device selection, and MCP schema;
2. invalid camera ID, disabled-overlay/device contradiction, out-of-range start layout, and out-of-range runtime updates rejecting without a completed file;
3. live `waiting` to `capturing` transition, nonzero input frames, source dimensions, recent wall/source timestamps, and non-stale status;
4. live hide, relocate, resize, reshape, corner-radius/margin update, and show-again behavior through the structured shared service, with monotonically increasing control-event count;
5. completed camera device/final visibility/layout/style/frame metadata and final overlay rectangle;
6. one H.264 video track and zero audio tracks for the camera-only recording;
7. independent multi-frame decoding of the final MP4, showing that the final configured camera region differs from the opposite fixture corner and contains meaningful visual texture;
8. camera composition surviving the M2a/M2c audio finalization path, producing one H.264 track plus one non-silent 48 kHz stereo AAC track;
9. valid playback, duration, permissions, bytes, SHA-256, and preview;
10. cancellation removing partial camera output.

The visual inspector uses the artifact's reported top-left-origin overlay rectangle; it does not infer a second video track or trust metadata alone.

`MupawCaptureTests.RecordingCameraHealthPolicyTests` additionally performs repeatable clock-controlled camera-loss simulation for startup grace, missing first frames, frame stalls, healthy capture, and camera-disabled compatibility.

## Full regression gate

```bash
make m3a-acceptance
```

The Mac must be unlocked with Screen & System Audio Recording, microphone, and camera permission granted to the stably signed `~/Applications/Mupaw.app`, plus connected microphone and camera devices. The gate runs formatting/localization, all unit tests, stable installation, RPC/MCP negative and concurrency checks, M1a–M2c historical regression, the real M2c mixed-audio smoke, and the real M3a camera smoke.

## Deferred

- M3b: click highlights and bounded keystroke display.
- M3c: manual zoom timeline.
- M4: automatic focus/zoom suggestions and the editable super-recording workflow.
