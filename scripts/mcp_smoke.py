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
import time
from pathlib import Path
from typing import Any
from urllib.parse import unquote, urlparse

PROTOCOL_VERSION = "2025-11-25"
EXPECTED_TOOLS = {
    "mupaw_app_status",
    "mupaw_capabilities_get",
    "mupaw_sources_list",
    "mupaw_screenshot_capture",
    "mupaw_recording_start",
    "mupaw_recording_status",
    "mupaw_recording_stop",
    "mupaw_recording_cancel",
    "mupaw_project_create",
    "mupaw_project_get",
    "mupaw_project_apply_edits",
    "mupaw_project_history",
    "mupaw_project_preview",
    "mupaw_project_export",
    "mupaw_project_ocr",
    "mupaw_project_color_sample",
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
    timeout: float = 35.0,
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
    return result_for(read_message(process, timeout=timeout), request_id)


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


def expect_tool_error(
    tool_result: dict[str, Any],
    tool_name: str,
    expected_fragment: str,
) -> str:
    if tool_result.get("isError") is not True:
        raise SmokeFailure(f"{tool_name} unexpectedly succeeded")
    message = text_content(tool_result, tool_name)
    if expected_fragment not in message:
        raise SmokeFailure(
            f"{tool_name} error omitted {expected_fragment!r}: {message!r}"
        )
    return message


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


def validate_artifact(
    tool_result: dict[str, Any],
    *,
    expected_source_id: str | None = None,
    expected_source_kind: str | None = None,
) -> dict[str, Any]:
    tool_name = "mupaw_screenshot_capture"
    artifact = parse_json_result(tool_result, tool_name)
    artifact_source = artifact.get("source")
    if not isinstance(artifact_source, dict):
        raise SmokeFailure("Screenshot artifact omitted its source descriptor")
    source_id = artifact_source.get("id")
    source_kind = artifact_source.get("kind")
    if not isinstance(source_id, str) or not isinstance(source_kind, str):
        raise SmokeFailure("Screenshot artifact source is missing id or kind")
    if expected_source_id is not None and source_id != expected_source_id:
        raise SmokeFailure(
            f"Screenshot artifact source mismatch: expected={expected_source_id!r}, actual={source_id!r}"
        )
    if expected_source_kind is not None and source_kind != expected_source_kind:
        raise SmokeFailure(
            f"Screenshot artifact kind mismatch: expected={expected_source_kind!r}, actual={source_kind!r}"
        )

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

    image = image_content(tool_result, tool_name)
    preview = artifact.get("preview")
    if not isinstance(preview, dict):
        raise SmokeFailure("Screenshot artifact omitted preview metadata")
    preview_data = preview.get("base64Data")
    preview_mime_type = preview.get("mimeType")
    if image.get("data") != preview_data or image.get("mimeType") != preview_mime_type:
        raise SmokeFailure("MCP image block does not match artifact preview metadata")

    return {
        "artifactID": artifact.get("id"),
        "sourceID": source_id,
        "sourceKind": source_kind,
        "file": str(file_path),
        "pixelWidth": pixel_width,
        "pixelHeight": pixel_height,
        "byteCount": byte_count,
        "sha256": expected_sha256,
        "previewMimeType": preview_mime_type,
    }


def capture_source_and_validate(
    process: subprocess.Popen[bytes],
    request_id: int,
    source: dict[str, Any],
    *,
    exclude_mupaw_ui: bool | None = None,
) -> dict[str, Any]:
    source_id = source.get("id")
    source_kind = source.get("kind")
    if not isinstance(source_id, str) or source_kind not in {"display", "window"}:
        raise SmokeFailure("Selected capture source is missing a usable display/window id")
    mode = "full_screen" if source_kind == "display" else "window"
    if exclude_mupaw_ui is None:
        exclude_mupaw_ui = source_kind == "display"

    result = call_tool(
        process,
        request_id,
        "mupaw_screenshot_capture",
        {
            "mode": mode,
            "source_id": source_id,
            "format": "png",
            "include_cursor": False,
            "exclude_mupaw_ui": exclude_mupaw_ui,
            "file_name": f"Mupaw-MCP-{mode}-Smoke",
        },
    )
    return validate_artifact(
        result,
        expected_source_id=source_id,
        expected_source_kind=source_kind,
    )


def capture_region_and_validate(
    process: subprocess.Popen[bytes],
    request_id: int,
    covering_source: dict[str, Any],
) -> dict[str, Any]:
    frame = covering_source.get("framePoints")
    if not isinstance(frame, dict):
        raise SmokeFailure("Mupaw window source omitted framePoints required for region smoke")
    values = {key: frame.get(key) for key in ("x", "y", "width", "height")}
    if not all(isinstance(value, (int, float)) for value in values.values()):
        raise SmokeFailure(f"Mupaw window framePoints are invalid: {frame!r}")

    frame_x = float(values["x"])
    frame_y = float(values["y"])
    frame_width = float(values["width"])
    frame_height = float(values["height"])
    if frame_width < 8 or frame_height < 8:
        raise SmokeFailure("Mupaw window is too small for a structured region smoke")
    margin = min(24.0, frame_width / 4, frame_height / 4)
    requested_region = {
        "coordinate_space": "global_display_points",
        "x": frame_x + margin,
        "y": frame_y + margin,
        "width": min(420.0, frame_width - 2 * margin),
        "height": min(260.0, frame_height - 2 * margin),
    }

    result = call_tool(
        process,
        request_id,
        "mupaw_screenshot_capture",
        {
            "mode": "region",
            "region": requested_region,
            "format": "png",
            "include_cursor": False,
            "exclude_mupaw_ui": False,
            "file_name": "Mupaw-MCP-region-Smoke",
        },
    )
    summary = validate_artifact(result, expected_source_kind="region")
    summary["requestedRegion"] = requested_region
    return summary


def select_mupaw_window(sources: list[Any]) -> dict[str, Any] | None:
    candidates = [
        item
        for item in sources
        if isinstance(item, dict)
        and item.get("kind") == "window"
        and item.get("applicationName") == "Mupaw"
    ]
    if not candidates:
        return None
    return max(
        candidates,
        key=lambda item: int(item.get("pixelWidth", 0))
        * int(item.get("pixelHeight", 0)),
    )


def run_negative_checks(
    process: subprocess.Popen[bytes],
    status: dict[str, Any],
) -> dict[str, str]:
    checks: dict[str, str] = {}

    checks["unknownTool"] = expect_tool_error(
        call_tool(process, 20, "mupaw_unknown_tool"),
        "mupaw_unknown_tool",
        "Unknown Mupaw tool",
    )
    checks["missingSourceID"] = expect_tool_error(
        call_tool(
            process,
            21,
            "mupaw_screenshot_capture",
            {"mode": "window"},
        ),
        "mupaw_screenshot_capture",
        "source_id is required",
    )
    checks["unsupportedFormat"] = expect_tool_error(
        call_tool(
            process,
            22,
            "mupaw_screenshot_capture",
            {"mode": "window", "source_id": "window:not-used", "format": "gif"},
        ),
        "mupaw_screenshot_capture",
        "supports only PNG",
    )
    checks["missingRegion"] = expect_tool_error(
        call_tool(
            process,
            23,
            "mupaw_screenshot_capture",
            {"mode": "region"},
        ),
        "mupaw_screenshot_capture",
        "region is required",
    )
    checks["invalidRegion"] = expect_tool_error(
        call_tool(
            process,
            24,
            "mupaw_screenshot_capture",
            {
                "mode": "region",
                "region": {"x": 0, "y": 0, "width": -1, "height": 20},
            },
        ),
        "mupaw_screenshot_capture",
        "positive dimensions",
    )
    checks["regionWithSource"] = expect_tool_error(
        call_tool(
            process,
            25,
            "mupaw_screenshot_capture",
            {
                "mode": "region",
                "source_id": "display:not-used",
                "region": {"x": 0, "y": 0, "width": 20, "height": 20},
            },
        ),
        "mupaw_screenshot_capture",
        "source_id must be omitted",
    )

    permissions = status.get("permissions")
    if status.get("running") is True and isinstance(permissions, dict):
        if permissions.get("screenCapture") == "authorized":
            checks["inventedSource"] = expect_tool_error(
                call_tool(
                    process,
                    26,
                    "mupaw_screenshot_capture",
                    {
                        "mode": "window",
                        "source_id": "window:does-not-exist",
                        "format": "png",
                    },
                ),
                "mupaw_screenshot_capture",
                "source_not_found",
            )

    recovered = parse_status(call_tool(process, 27, "mupaw_app_status"))
    if recovered.get("running") != status.get("running"):
        raise SmokeFailure("Mupaw app status changed after MCP negative checks")
    checks["statusAfterErrors"] = "ok"
    return checks


def run(
    executable: Path,
    require_running: bool,
    capture_one: bool,
    capture_full_screen: bool,
    expect_capture_in_progress: bool,
    negative: bool,
) -> dict[str, Any]:
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
        screenshot_tool = next(
            (
                item
                for item in tools
                if isinstance(item, dict)
                and item.get("name") == "mupaw_screenshot_capture"
            ),
            None,
        )
        if not isinstance(screenshot_tool, dict):
            raise SmokeFailure("tools/list omitted mupaw_screenshot_capture metadata")
        input_schema = screenshot_tool.get("inputSchema")
        schema_properties = (
            input_schema.get("properties") if isinstance(input_schema, dict) else None
        )
        required_schema_properties = {"mode", "source_id", "region", "exclude_mupaw_ui"}
        if not isinstance(schema_properties, dict) or not required_schema_properties.issubset(
            schema_properties
        ):
            raise SmokeFailure(
                "mupaw_screenshot_capture schema omitted M1a mode/region properties"
            )
        tool_schema_check = {"m1aCaptureProperties": sorted(required_schema_properties)}
        apply_tool = next(
            (
                item
                for item in tools
                if isinstance(item, dict)
                and item.get("name") == "mupaw_project_apply_edits"
            ),
            None,
        )
        apply_schema = apply_tool.get("inputSchema") if isinstance(apply_tool, dict) else None
        apply_properties = (
            apply_schema.get("properties") if isinstance(apply_schema, dict) else None
        )
        required_edit_properties = {"project_id", "expected_revision", "commands"}
        if not isinstance(apply_properties, dict) or not required_edit_properties.issubset(
            apply_properties
        ):
            raise SmokeFailure("mupaw_project_apply_edits schema omitted M1b properties")
        tool_schema_check["m1bApplyEditProperties"] = sorted(required_edit_properties)
        commands_schema = apply_properties.get("commands")
        command_items = commands_schema.get("items") if isinstance(commands_schema, dict) else None
        command_properties = (
            command_items.get("properties") if isinstance(command_items, dict) else None
        )
        required_style_command_properties = {"style", "preset"}
        if not isinstance(command_properties, dict) or not required_style_command_properties.issubset(
            command_properties
        ):
            raise SmokeFailure("mupaw_project_apply_edits schema omitted M1d style properties")
        command_type = command_properties.get("type")
        command_type_enum = command_type.get("enum") if isinstance(command_type, dict) else None
        required_style_commands = {
            "set_visual_style",
            "apply_style_preset",
            "clear_visual_style",
        }
        if not isinstance(command_type_enum, list) or not required_style_commands.issubset(
            set(value for value in command_type_enum if isinstance(value, str))
        ):
            raise SmokeFailure("mupaw_project_apply_edits schema omitted M1d style commands")
        tool_schema_check["m1dStyleCommandProperties"] = sorted(
            required_style_command_properties
        )
        tool_schema_check["m1dStyleCommands"] = sorted(required_style_commands)

        recording_start_tool = next(
            (
                item
                for item in tools
                if isinstance(item, dict) and item.get("name") == "mupaw_recording_start"
            ),
            None,
        )
        recording_start_schema = (
            recording_start_tool.get("inputSchema")
            if isinstance(recording_start_tool, dict)
            else None
        )
        recording_start_properties = (
            recording_start_schema.get("properties")
            if isinstance(recording_start_schema, dict)
            else None
        )
        required_recording_properties = {
            "mode",
            "source_id",
            "region",
            "format",
            "frame_rate",
            "quality",
            "include_cursor",
            "exclude_mupaw_ui",
            "file_name",
        }
        if not isinstance(recording_start_properties, dict) or not required_recording_properties.issubset(
            recording_start_properties
        ):
            raise SmokeFailure("mupaw_recording_start schema omitted M1e properties")
        for recording_tool_name in (
            "mupaw_recording_status",
            "mupaw_recording_stop",
            "mupaw_recording_cancel",
        ):
            item = next(
                (
                    tool
                    for tool in tools
                    if isinstance(tool, dict) and tool.get("name") == recording_tool_name
                ),
                None,
            )
            schema = item.get("inputSchema") if isinstance(item, dict) else None
            properties = schema.get("properties") if isinstance(schema, dict) else None
            if not isinstance(properties, dict) or "session_id" not in properties:
                raise SmokeFailure(f"{recording_tool_name} schema omitted session_id")
        tool_schema_check["m1eRecordingStartProperties"] = sorted(required_recording_properties)

        ocr_tool = next(
            (
                item
                for item in tools
                if isinstance(item, dict) and item.get("name") == "mupaw_project_ocr"
            ),
            None,
        )
        ocr_schema = ocr_tool.get("inputSchema") if isinstance(ocr_tool, dict) else None
        ocr_properties = ocr_schema.get("properties") if isinstance(ocr_schema, dict) else None
        required_ocr_properties = {
            "project_id",
            "expected_revision",
            "region",
            "recognition_level",
            "recognition_languages",
            "uses_language_correction",
            "minimum_confidence",
        }
        if not isinstance(ocr_properties, dict) or not required_ocr_properties.issubset(
            ocr_properties
        ):
            raise SmokeFailure("mupaw_project_ocr schema omitted M1c OCR properties")
        tool_schema_check["m1cOCRProperties"] = sorted(required_ocr_properties)

        color_tool = next(
            (
                item
                for item in tools
                if isinstance(item, dict)
                and item.get("name") == "mupaw_project_color_sample"
            ),
            None,
        )
        color_schema = color_tool.get("inputSchema") if isinstance(color_tool, dict) else None
        color_properties = (
            color_schema.get("properties") if isinstance(color_schema, dict) else None
        )
        required_color_properties = {
            "project_id",
            "expected_revision",
            "mode",
            "point",
            "region",
        }
        if not isinstance(color_properties, dict) or not required_color_properties.issubset(
            color_properties
        ):
            raise SmokeFailure("mupaw_project_color_sample schema omitted M1c color properties")
        tool_schema_check["m1cColorProperties"] = sorted(required_color_properties)

        status = parse_status(call_tool(process, 3, "mupaw_app_status"))
        if require_running and not status["running"]:
            raise SmokeFailure(
                "Mupaw.app is not reachable. Start it with `make run`, then retry."
            )

        capability_summary: dict[str, Any] | None = None
        source_check: dict[str, Any] | None = None
        availability_check: dict[str, Any] | None = None
        capture_check: dict[str, Any] | None = None
        negative_checks: dict[str, str] | None = None
        conflict_check: dict[str, str] | None = None
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
            expected_available = {
                "source-enumeration",
                "screenshot",
                "agent-mcp",
                "region-capture",
                "screenshot-editing",
                "ocr",
                "color-sampling",
                "visual-style",
                "recording",
            }
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
                if expect_capture_in_progress:
                    conflict_source = select_mupaw_window(sources)
                    if conflict_source is None:
                        conflict_source = next(
                            (
                                item
                                for item in sources
                                if isinstance(item, dict) and item.get("kind") == "window"
                            ),
                            None,
                        )
                    if not isinstance(conflict_source, dict):
                        raise SmokeFailure(
                            "No window source was available for capture_in_progress validation"
                        )
                    conflict_source_id = conflict_source.get("id")
                    if not isinstance(conflict_source_id, str):
                        raise SmokeFailure("Conflict smoke source omitted its identifier")
                    conflict_message = expect_tool_error(
                        call_tool(
                            process,
                            30,
                            "mupaw_screenshot_capture",
                            {
                                "mode": "window",
                                "source_id": conflict_source_id,
                                "format": "png",
                            },
                        ),
                        "mupaw_screenshot_capture",
                        "capture_in_progress",
                    )
                    conflict_check = {
                        "sourceID": conflict_source_id,
                        "message": conflict_message,
                    }

                if capture_one:
                    selected_source = select_mupaw_window(sources)
                    if selected_source is None:
                        # App startup may have populated the five-second source cache before
                        # the SwiftUI window became visible. Wait for that bounded cache to
                        # expire, then require a Mupaw-owned window rather than capturing an
                        # unrelated full display during automated validation.
                        time.sleep(5.25)
                        refreshed_payload = parse_json_result(
                            call_tool(process, 6, "mupaw_sources_list"),
                            "mupaw_sources_list",
                        )
                        refreshed_sources = refreshed_payload.get("sources")
                        if not isinstance(refreshed_sources, list):
                            raise SmokeFailure(
                                "Refreshed mupaw_sources_list omitted the sources array"
                            )
                        sources = refreshed_sources
                        source_check = {
                            "mode": "authorized",
                            "sourceCount": len(sources),
                            "refreshedForCapture": True,
                        }
                        selected_source = select_mupaw_window(sources)
                    if selected_source is None:
                        raise SmokeFailure(
                            "No visible Mupaw window was available for a privacy-safe smoke screenshot"
                        )
                    capture_check = {
                        "window": capture_source_and_validate(
                            process,
                            10,
                            selected_source,
                            exclude_mupaw_ui=False,
                        ),
                        "region": capture_region_and_validate(
                            process,
                            11,
                            selected_source,
                        ),
                    }
                if capture_full_screen:
                    display_source = next(
                        (
                            item
                            for item in sources
                            if isinstance(item, dict)
                            and item.get("kind") == "display"
                            and item.get("isPrimaryDisplay") is True
                        ),
                        next(
                            (
                                item
                                for item in sources
                                if isinstance(item, dict) and item.get("kind") == "display"
                            ),
                            None,
                        ),
                    )
                    if not isinstance(display_source, dict):
                        raise SmokeFailure("No display source was available for full-screen capture")
                    if capture_check is None:
                        capture_check = {}
                    capture_check["fullScreen"] = capture_source_and_validate(
                        process,
                        12,
                        display_source,
                        exclude_mupaw_ui=True,
                    )
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
                if capture_one or capture_full_screen or expect_capture_in_progress:
                    raise SmokeFailure(
                        "capture smoke options require Screen & System Audio Recording permission"
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
            if capture_one or capture_full_screen or expect_capture_in_progress:
                raise SmokeFailure("capture smoke options require a running Mupaw.app instance")

        if negative:
            negative_checks = run_negative_checks(process, status)

        return {
            "server": server_info,
            "protocolVersion": initialize.get("protocolVersion"),
            "toolNames": sorted(tool_names),
            "toolSchemaCheck": tool_schema_check,
            "appStatus": status,
            "availabilityCheck": availability_check,
            "capabilities": capability_summary,
            "sourcesCheck": source_check,
            "captureCheck": capture_check,
            "negativeChecks": negative_checks,
            "captureConflictCheck": conflict_check,
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
    parser.add_argument(
        "--capture-full-screen",
        action="store_true",
        help="Capture the primary display. Cover it with non-sensitive test content first.",
    )
    parser.add_argument(
        "--expect-capture-in-progress",
        action="store_true",
        help="Require a live interactive capture and verify that MCP returns capture_in_progress.",
    )
    parser.add_argument("--negative", action="store_true")
    args = parser.parse_args()

    try:
        summary = run(
            args.executable.resolve(),
            args.require_running,
            args.capture_one,
            args.capture_full_screen,
            args.expect_capture_in_progress,
            args.negative,
        )
    except SmokeFailure as error:
        print(f"MCP smoke test failed: {error}", file=sys.stderr)
        return 1

    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
