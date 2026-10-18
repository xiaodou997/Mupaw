# Mupaw MCP contract — M0 and M1a

The executable product is `mupaw-mcp`. It communicates with MCP clients over stdio and forwards capture work to a running `Mupaw.app` instance. The helper never requests screen permission or captures independently.

## Tools

### `mupaw_app_status`

Returns whether the app connection descriptor exists, whether the local app responds, the app version, protocol version, and relevant permission state.

### `mupaw_capabilities_get`

Returns the implemented and planned capability matrix. Planned capabilities are never reported as available. In M1a, `screenshot`, `source-enumeration`, `region-capture`, and `agent-mcp` are available.

### `mupaw_sources_list`

Returns active displays and eligible on-screen windows. Callers must use exact returned identifiers and must not invent source IDs.

M1a source descriptors include:

- `id` and `kind` (`display` or `window`);
- title and owning-application metadata when available;
- pixel dimensions;
- `framePoints` in `global_display_points`;
- `pointPixelScale`;
- active-window and primary-display hints.

Source IDs are session-scoped and may become stale when a window closes or the display configuration changes.

### `mupaw_screenshot_capture`

M1a supports PNG in three explicit modes.

#### Full screen

```json
{
  "mode": "full_screen",
  "source_id": "display:2",
  "format": "png",
  "include_cursor": false,
  "exclude_mupaw_ui": true,
  "file_name": "optional-safe-name"
}
```

#### Window

```json
{
  "mode": "window",
  "source_id": "window:1234",
  "format": "png",
  "include_cursor": false,
  "file_name": "optional-safe-name"
}
```

#### Structured region

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

`global_display_points` uses macOS global display coordinates in point units with a top-left origin. A region may cross displays. Mupaw performs the display splitting, Retina conversion, composition, and bounds checks internally; an Agent must not simulate dragging or click the Mupaw UI.

For compatibility, omitting `mode` infers `window` from a `window:` source ID, `region` from a region object, and otherwise `full_screen`. New integrations should always send an explicit mode.

The successful result includes artifact metadata, the exact captured-source descriptor, a local file URL, SHA-256, and a bounded image preview suitable for Agent inspection. Success means the PNG has been fully written; it does not mean the request was merely accepted.

## Error behavior

- `app_not_running`: start Mupaw and retry;
- `permission_required`: grant Screen & System Audio Recording permission to Mupaw;
- `capture_in_progress`: wait for the active UI or Agent capture to finish or be cancelled;
- `source_not_found`: refresh sources and use a returned source ID;
- `invalid_region`: correct the region or ensure it intersects an active display;
- `invalid_request`: correct mode/source/region combinations or malformed structured data;
- `unknown_method`: use a defined local RPC method or advertised MCP tool;
- `protocol_mismatch`: update the helper and app together;
- `unauthorized`: discard the stale local descriptor and reconnect to the running app;
- `frame_too_large`: reduce the request or result below the 4 MiB local frame limit;
- `capture_failed`: no artifact is claimed; inspect the accompanying message.

MCP tool failures are returned as `isError: true` text content. The internal loopback RPC also returns a structured error code and response ID. A safe request ID is preserved when the JSON object is structurally readable; malformed JSON and oversized frames use `unknown`.

## Validation commands

```bash
make mcp-smoke-running
make mcp-negative-smoke
make mcp-smoke-capture
make rpc-negative-smoke
make m1a-acceptance
```

`make mcp-smoke-capture` captures a Mupaw window and a structured subregion of that window, avoiding unrelated display content. `make mcp-smoke-full-screen` is separate: cover the display with non-sensitive test content before running it. To verify conflict handling, start an interactive region selection and run `make mcp-capture-conflict-smoke`; it must return `capture_in_progress`.
