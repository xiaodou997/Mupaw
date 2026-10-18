# Mupaw MCP contract — M0

The executable product is `mupaw-mcp`. It communicates with MCP clients over stdio and forwards capture work to a running `Mupaw.app` instance.

## Tools

### `mupaw_app_status`

Returns whether the app connection descriptor exists, whether the local app responds, the app version, protocol version, and relevant permission state.

### `mupaw_capabilities_get`

Returns the implemented and planned capability matrix. Planned capabilities are never reported as available.

### `mupaw_sources_list`

Refreshes and returns displays and eligible on-screen windows. Each source has a stable identifier for the current app session. Callers must not invent source IDs.

### `mupaw_screenshot_capture`

Input:

```json
{
  "source_id": "display:1",
  "format": "png",
  "include_cursor": false,
  "file_name": "optional-safe-name"
}
```

M0 supports PNG. The result includes artifact metadata, a local file URL, and a bounded preview suitable for Agent inspection.

## Error behavior

- `app_not_running`: start Mupaw and retry;
- `permission_required`: grant Screen & System Audio Recording permission to Mupaw;
- `source_not_found`: refresh sources and use a returned source ID;
- `invalid_request`: correct arguments or malformed structured data;
- `unknown_method`: use a defined local RPC method or advertised MCP tool;
- `protocol_mismatch`: update the helper and app together;
- `unauthorized`: discard the stale local descriptor and reconnect to the running app;
- `frame_too_large`: reduce the request or result below the 4 MiB local frame limit;
- `capture_failed`: no artifact is claimed; inspect the accompanying message.

The helper must distinguish a completed capture from merely accepting a request.

MCP tool failures are returned as `isError: true` text content. The internal loopback RPC also returns a structured error code and a response ID. A safe request ID is preserved when the JSON object is structurally readable; malformed JSON and oversized frames use `unknown`.

Validation commands:

```bash
make mcp-negative-smoke
make rpc-negative-smoke
make m0-acceptance
```
