#!/usr/bin/env python3
"""Reproducible smoke test for the local Mupaw MCP stdio server."""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import json
import os
import selectors
import subprocess
import sys
from pathlib import Path
from typing import Any
from urllib.parse import unquote, urlparse

PROTOCOL_VERSION = "2025-11-25"
EXPECTED_TOOLS = {
    "mupaw_app_status",
    "mupaw_capabilities_get",
    "mupaw_sources_list",
    "mupaw_screenshot_capture",
}


class SmokeFailure(RuntimeError):
    pass


def write_message(process: subprocess.Popen[bytes], payload: dict[str, Any]) -> None:
    if process.stdin is None:
        raise SmokeFailure("MCP process stdin is unavailable")
    process.stdin.write(json.dumps(payload, separators=(",", ":")).encode("utf-8") + b"\n")
    process.stdin.flush()


def read_message(process: subprocess.Popen[bytes], timeout: float = 35.0) -> dict[str, Any]:
    if process.stdout is None:
        raise SmokeFailure("MCP process stdout is unavailable")

    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    try:
        if not selector.select(timeout):
            raise SmokeFailure(f"Timed out after {timeout:.1f}s waiting for an MCP response")
        line = process.stdout.readline()
    finally:
        selector.close()

    if not line:
        raise SmokeFailure("MCP process closed stdout before returning a response")
    try:
        value = json.loads(line)
    except json.JSONDecodeError as error:
        raise SmokeFailure(f"MCP returned invalid JSON: {line!r}") from error
    if not isinstance(value, dict):
        raise SmokeFailure("MCP response was not a JSON object")
    if "error" in value:
        raise SmokeFailure(f"MCP returned JSON-RPC error: {value['error']}")
    return value


def result_for(response: dict[str, Any], request_id: int) -> dict[str, Any]:
    if response.get("id") != request_id:
        raise SmokeFailure(
            f"Expected response id {request_id}, received {response.get('id')!r}"
        )
    result = response.get("result")
    if not isinstance(result, dict):
        raise SmokeFailure(f"Response {request_id} did not include an object result")
    return result


def call_tool(
    process: subprocess.Popen[bytes],
    request_id: int,
    name: str,
    arguments: dict[str, Any] | None = None,
) -> dict[str, Any]:
    write_message(
        process,
        {
            "jsonrpc": "2.0",
            "id": request_id,
            "method": "tools/call",
            "params": {"name": name, "arguments": arguments or {}},
        },
    )
    return result_for(read_message(process), request_id)


def text_content(tool_result: dict[str, Any], tool_name: str) -> str:
    content = tool_result.get("content")
    if not isinstance(content, list) or not content:
        raise SmokeFailure(f"{tool_name} returned no content")
    first = content[0]
    if not isinstance(first, dict) or first.get("type") != "text":
        raise SmokeFailure(f"{tool_name} did not return text content")
    text = first.get("text")
    if not isinstance(text, str):
        raise SmokeFailure(f"{tool_name} text payload is missing")
    return text


def parse_json_result(tool_result: dict[str, Any], tool_name: str) -> dict[str, Any]:
    if tool_result.get("isError") is True:
        raise SmokeFailure(f"{tool_name} returned an error: {text_content(tool_result, tool_name)}")
    text = text_content(tool_result, tool_name)
    try:
        value = json.loads(text)
    except json.JSONDecodeError as error:
        raise SmokeFailure(f"{tool_name} text was not JSON") from error
    if not isinstance(value, dict):
        raise SmokeFailure(f"{tool_name} JSON result was not an object")
    return value


def parse_status(tool_result: dict[str, Any]) -> dict[str, Any]:
    status = parse_json_result(tool_result, "mupaw_app_status")
    if not isinstance(status, dict) or not isinstance(status.get("running"), bool):
        raise SmokeFailure("mupaw_app_status omitted the boolean running field")
    return status


def image_content(tool_result: dict[str, Any], tool_name: str) -> dict[str, Any]:
    content = tool_result.get("content")
    if not isinstance(content, list):
        raise SmokeFailure(f"{tool_name} returned no content array")
    images = [item for item in content if isinstance(item, dict) and item.get("type") == "image"]
    if len(images) != 1:
        raise SmokeFailure(f"{tool_name} returned {len(images)} image blocks instead of one")

    image = images[0]
    encoded = image.get("data")
    mime_type = image.get("mimeType")
    if not isinstance(encoded, str) or not isinstance(mime_type, str):
        raise SmokeFailure(f"{tool_name} image block is missing data or mimeType")
    try:
        decoded = base64.b64decode(encoded, validate=True)
    except (ValueError, binascii.Error) as error:
        raise SmokeFailure(f"{tool_name} returned invalid base64 image data") from error
    if not decoded:
        raise SmokeFailure(f"{tool_name} returned an empty image preview")
    return image


def capture_and_validate(
    process: subprocess.Popen[bytes],
    request_id: int,
    source: dict[str, Any],
) -> dict[str, Any]:
    source_id = source.get("id")
    source_kind = source.get("kind")
    if not isinstance(source_id, str) or not isinstance(source_kind, str):
        raise SmokeFailure("Selected capture source is missing id or kind")

    result = call_tool(
        process,
        request_id,
        "mupaw_screenshot_capture",
        {
            "source_id": source_id,
            "format": "png",
            "include_cursor": False,
            "file_name": "Mupaw-MCP-Smoke",
        },
    )
    artifact = parse_json_result(result, "mupaw_screenshot_capture")
    artifact_source = artifact.get("source")
    if not isinstance(artifact_source, dict) or artifact_source.get("id") != source_id:
        raise SmokeFailure("Screenshot artifact source does not match the requested source")

    pixel_width = artifact.get("pixelWidth")
    pixel_height = artifact.get("pixelHeight")
    byte_count = artifact.get("byteCount")
    expected_sha256 = artifact.get("sha256")
    file_url = artifact.get("fileURL")
    if not isinstance(pixel_width, int) or pixel_width <= 0:
        raise SmokeFailure("Screenshot artifact has an invalid pixelWidth")
    if not isinstance(pixel_height, int) or pixel_height <= 0:
        raise SmokeFailure("Screenshot artifact has an invalid pixelHeight")
    if not isinstance(byte_count, int) or byte_count <= 0:
        raise SmokeFailure("Screenshot artifact has an invalid byteCount")
    if not isinstance(expected_sha256, str) or len(expected_sha256) != 64:
        raise SmokeFailure("Screenshot artifact has an invalid SHA-256")
    if not isinstance(file_url, str):
        raise SmokeFailure("Screenshot artifact omitted fileURL")

    parsed_url = urlparse(file_url)
    if parsed_url.scheme != "file":
        raise SmokeFailure(f"Screenshot artifact did not return a file URL: {file_url!r}")
    file_path = Path(unquote(parsed_url.path)).resolve()
    capture_root = (
        Path.home() / "Library" / "Application Support" / "Mupaw" / "Captures"
    ).resolve()
    try:
        file_path.relative_to(capture_root)
    except ValueError as error:
        raise SmokeFailure(f"Screenshot escaped the Mupaw capture directory: {file_path}") from error
    if not file_path.is_file():
        raise SmokeFailure(f"Screenshot file does not exist: {file_path}")

    file_data = file_path.read_bytes()
    if len(file_data) != byte_count:
        raise SmokeFailure(
            f"Screenshot byte count mismatch: metadata={byte_count}, file={len(file_data)}"
        )
    actual_sha256 = hashlib.sha256(file_data).hexdigest()
    if actual_sha256 != expected_sha256:
        raise SmokeFailure(
            f"Screenshot SHA-256 mismatch: metadata={expected_sha256}, file={actual_sha256}"
        )

    image = image_content(result, "mupaw_screenshot_capture")
    preview = artifact.get("preview")
    if not isinstance(preview, dict):
        raise SmokeFailure("Screenshot artifact omitted preview metadata")
    preview_data = preview.get("base64Data")
    preview_mime_type = preview.get("mimeType")
    if image.get("data") != preview_data or image.get("mimeType") != preview_mime_type:
        raise SmokeFailure("MCP image block does not match artifact preview metadata")

    return {
        "sourceID": source_id,
        "sourceKind": source_kind,
        "file": str(file_path),
        "pixelWidth": pixel_width,
        "pixelHeight": pixel_height,
        "byteCount": byte_count,
        "sha256": expected_sha256,
        "previewMimeType": preview_mime_type,
    }


def run(executable: Path, require_running: bool, capture_one: bool) -> dict[str, Any]:
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise SmokeFailure(f"MCP executable is missing or not executable: {executable}")

    process = subprocess.Popen(
        [str(executable)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        bufsize=0,
    )
    try:
        write_message(
            process,
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": PROTOCOL_VERSION,
                    "capabilities": {},
                    "clientInfo": {"name": "mupaw-smoke", "version": "1"},
                },
            },
        )
        initialize = result_for(read_message(process), 1)
        server_info = initialize.get("serverInfo")
        if not isinstance(server_info, dict) or server_info.get("name") != "Mupaw":
            raise SmokeFailure(f"Unexpected MCP server info: {server_info!r}")

        write_message(
            process,
            {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}},
        )
        write_message(
            process,
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
        )
        listed = result_for(read_message(process), 2)
        tools = listed.get("tools")
        if not isinstance(tools, list):
            raise SmokeFailure("tools/list did not return a tools array")
        tool_names = {
            item.get("name") for item in tools if isinstance(item, dict) and isinstance(item.get("name"), str)
        }
        missing = EXPECTED_TOOLS - tool_names
        if missing:
            raise SmokeFailure(f"tools/list omitted expected tools: {sorted(missing)}")

        status = parse_status(call_tool(process, 3, "mupaw_app_status"))
        if require_running and not status["running"]:
            raise SmokeFailure(
                "Mupaw.app is not reachable. Start it with `make run`, then retry."
            )

        capability_summary: dict[str, Any] | None = None
        source_check: dict[str, Any] | None = None
        availability_check: dict[str, Any] | None = None
        capture_check: dict[str, Any] | None = None
        if status["running"]:
            capabilities = parse_json_result(
                call_tool(process, 4, "mupaw_capabilities_get"),
                "mupaw_capabilities_get",
            )
            capability_items = capabilities.get("capabilities")
            if not isinstance(capability_items, list):
                raise SmokeFailure("mupaw_capabilities_get omitted the capabilities array")
            available_ids = {
                item.get("id")
                for item in capability_items
                if isinstance(item, dict) and item.get("availability") == "available"
            }
            expected_available = {"source-enumeration", "screenshot", "agent-mcp"}
            missing_available = expected_available - available_ids
            if missing_available:
                raise SmokeFailure(
                    "mupaw_capabilities_get omitted available capabilities: "
                    f"{sorted(missing_available)}"
                )
            capability_summary = {
                "count": len(capability_items),
                "availableIDs": sorted(value for value in available_ids if isinstance(value, str)),
            }

            sources_result = call_tool(process, 5, "mupaw_sources_list")
            permissions = status.get("permissions")
            screen_permission = (
                permissions.get("screenCapture") if isinstance(permissions, dict) else None
            )
            if screen_permission == "authorized":
                sources_payload = parse_json_result(sources_result, "mupaw_sources_list")
                sources = sources_payload.get("sources")
                if not isinstance(sources, list):
                    raise SmokeFailure("mupaw_sources_list omitted the sources array")
                if not any(
                    isinstance(item, dict) and item.get("kind") == "display" for item in sources
                ):
                    raise SmokeFailure("mupaw_sources_list returned no display source")
                source_check = {"mode": "authorized", "sourceCount": len(sources)}
                if capture_one:
                    mupaw_windows = [
                        item
                        for item in sources
                        if isinstance(item, dict)
                        and item.get("kind") == "window"
                        and item.get("applicationName") == "Mupaw"
                    ]
                    selected_source = (
                        max(
                            mupaw_windows,
                            key=lambda item: int(item.get("pixelWidth", 0))
                            * int(item.get("pixelHeight", 0)),
                        )
                        if mupaw_windows
                        else next(
                            (
                                item
                                for item in sources
                                if isinstance(item, dict) and item.get("kind") == "display"
                            ),
                            None,
                        )
                    )
                    if not isinstance(selected_source, dict):
                        raise SmokeFailure("No eligible source was available for a real screenshot")
                    capture_check = capture_and_validate(process, 6, selected_source)
            else:
                if sources_result.get("isError") is not True:
                    raise SmokeFailure(
                        "mupaw_sources_list succeeded even though screen capture permission is not authorized"
                    )
                error_text = text_content(sources_result, "mupaw_sources_list")
                if "permission_required" not in error_text:
                    raise SmokeFailure(
                        "mupaw_sources_list did not preserve the permission_required error code"
                    )
                source_check = {"mode": "permission-required", "message": error_text}
                if capture_one:
                    raise SmokeFailure(
                        "--capture-one requires Screen & System Audio Recording permission"
                    )
        else:
            unavailable_result = call_tool(process, 4, "mupaw_capabilities_get")
            if unavailable_result.get("isError") is not True:
                raise SmokeFailure(
                    "mupaw_capabilities_get succeeded even though Mupaw.app is not running"
                )
            unavailable_text = text_content(
                unavailable_result, "mupaw_capabilities_get"
            )
            if "app_not_running" not in unavailable_text:
                raise SmokeFailure(
                    "mupaw_capabilities_get did not preserve the app_not_running error code"
                )
            availability_check = {
                "mode": "app-not-running",
                "message": unavailable_text,
            }
            if capture_one:
                raise SmokeFailure("--capture-one requires a running Mupaw.app instance")

        return {
            "server": server_info,
            "protocolVersion": initialize.get("protocolVersion"),
            "toolNames": sorted(tool_names),
            "appStatus": status,
            "availabilityCheck": availability_check,
            "capabilities": capability_summary,
            "sourcesCheck": source_check,
            "captureCheck": capture_check,
        }
    finally:
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=2)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--executable", type=Path, required=True)
    parser.add_argument("--require-running", action="store_true")
    parser.add_argument("--capture-one", action="store_true")
    args = parser.parse_args()

    try:
        summary = run(args.executable.resolve(), args.require_running, args.capture_one)
    except SmokeFailure as error:
        print(f"MCP smoke test failed: {error}", file=sys.stderr)
        return 1

    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
