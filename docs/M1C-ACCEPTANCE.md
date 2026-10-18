# M1c acceptance criteria

M1c adds local OCR and color sampling to the immutable screenshot-project foundation. It extends M1b and does not claim scrolling capture, visual background/shadow styling, recording, GIF, camera overlay, click/keystroke visualization, or automatic zoom.

The development machine has one display. Physical cross-display dragging remains a compatibility follow-up and does not block M1c; M1c analysis itself uses project-original pixel coordinates and is independent of display topology.

## Build, localization, and deterministic tests

- `make format`, `make localization-check`, `make lint`, `make build`, and `make test` succeed with Swift 6 strict concurrency.
- English and Simplified Chinese contain identical UI, analysis, service-error, and privacy key sets.
- Core and editing/analysis tests report zero failures.
- tests cover OCR request defaults, engine metadata, language/confidence/region validation, normalized-coordinate conversion, deterministic observation order, text bounds, point color, bounded region average/center/dominant colors, sRGB metadata, stale revisions, original corruption, and proof that analysis does not mutate project state.
- generated projects, builds, captures, exports, local signing configuration, and user-specific paths are not committed.

## Shared immutable analysis input

- OCR and color sampling load `Projects/<uuid>/original.png`, never the rendered annotation preview;
- project get, OCR, color sampling, preview, and export revalidate the copied original SHA-256 and dimensions before use;
- the current crop is the default OCR or region-color rectangle when a request omits `region`;
- explicit analysis coordinates use original-image pixels with a top-left origin;
- successful or failed analysis never changes project revision, content, undo/redo history, project JSON, or original bytes;
- optional `expected_revision` detects stale context with `project_version_conflict`.

## Apple Vision local OCR

- OCR runs locally in `Mupaw.app` and requires no network service;
- Apple Vision runs in a short-lived signed helper bundled inside the app, with owner-only request files, path confinement, cancellation, and a 120-second process timeout;
- the local RPC client allows 150 seconds for a cold Vision model start without extending ordinary RPC calls;
- Apple Vision is the only OCR engine and reports `vision_fast` or `vision_accurate` as the effective engine;
- `fast` and `accurate` recognition levels are accepted;
- callers may provide zero to eight bounded BCP-47-style language hints, or omit them for automatic detection;
- language correction and minimum confidence are explicit request settings;
- very large OCR input is scaled to at most 4,096 pixels on its largest axis;
- Vision lower-left normalized rectangles are converted to original-image top-left pixel rectangles;
- observations are filtered, ordered top-to-bottom then left-to-right, and receive stable per-result IDs;
- output is bounded to 512 observations, 4,096 UTF-8 bytes per observation, and 256 KiB of combined text;
- each observation contains non-empty text, confidence in `0...1`, a sufficiently confident detected language or `und`, and an in-bounds rectangle;
- the result includes the ordered set of confidently detected languages;
- `fullText` equals ordered observation text joined by newlines;
- OCR input/preparation failures return `ocr_failed`; malformed inputs return `invalid_request`.

## Point and region color sampling

- point mode requires one finite in-bounds original-image coordinate and samples exactly one pixel;
- region mode accepts one finite in-bounds rectangle or defaults to the project crop/full image;
- input is converted to normalized sRGB;
- every sampled color contains RGBA, uppercase `hexRGB`, uppercase `hexRGBA`, relative luminance, and `isDark`;
- region mode returns average, center, and deterministic dominant colors;
- `primaryColor` equals the average color for region mode;
- dominant color uses a deterministic bounded quantized bucket rather than an unbounded clustering job;
- region analysis is bounded to at most 256 pixels per axis and at most 65,536 sampled pixels;
- the actual sampled-pixel count is returned;
- color preparation/sampling failures return `color_sampling_failed`; malformed inputs return `invalid_request`.

## Human editor

After a screenshot project is active:

- the OCR toolbar action runs local recognition for the current crop/full image;
- recognized rectangles appear on the canvas and remain selectable;
- the inspector displays ordered text, confidence, source coordinates, result count, clear, and copy-all actions;
- point-color mode visibly enters a click-to-sample state and exits after a sample or cancellation;
- a point marker and normalized color metadata appear in the inspector;
- region-color mode opens a movable/resizable original-image selection sheet with apply/cancel;
- average, center, dominant, hexadecimal, luminance classification, and sample count are visible;
- analysis overlays are invalidated when the project revision changes;
- controls have accessible labels and remain usable at the configured minimum window size.

## Agent/MCP analysis

The following M1c tools are advertised and callable:

```text
mupaw_project_ocr
mupaw_project_color_sample
```

A real MCP acceptance flow must:

1. capture a visible Mupaw window;
2. create a project from the returned URL, SHA-256, and artifact ID;
3. run local Apple Vision OCR, verify the reported engine/languages, and recognize visible text including the Mupaw title;
4. verify every OCR confidence, detected language, and original-image bounding rectangle;
5. sample one point and verify normalized sRGB/hex/luminance metadata and sample count `1`;
6. sample a bounded region and verify average, center, dominant, and sample count;
7. reject a missing point, out-of-bounds point, invalid OCR confidence, too many languages, and stale revision;
8. fetch the project again and prove revision/content are unchanged;
9. prove project JSON and copied-original SHA-256 are unchanged.

UI and MCP call the same `ScreenshotProjectService`; Agents provide structured coordinates and never simulate editor clicks.

## Reproducible commands

```bash
make m1c-smoke
make m1c-acceptance
```

`make m1c-acceptance` includes formatting/localization, all unit tests, stable signed installation, raw RPC negative/concurrency checks, M1a real capture validation, M1b full project-editing validation, and the complete real M1c Apple-Vision-OCR/color workflow.

## Deferred

M1c does not claim scrolling long screenshots, background/rounded-corner/shadow styling, MP4/GIF recording, system audio, microphone, camera overlay, click highlights, keystroke display, or automatic zoom. Physical dual-display drag validation remains a compatibility follow-up rather than an M1c blocker.
