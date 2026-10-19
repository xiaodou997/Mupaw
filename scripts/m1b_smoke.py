#!/usr/bin/env python3
"""End-to-end M1b smoke test through the public MCP tools."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import struct
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any
from urllib.parse import unquote, urlparse

import mcp_smoke as base

EDITING_TOOLS = {
    "mupaw_project_create",
    "mupaw_project_get",
    "mupaw_project_apply_edits",
    "mupaw_project_history",
    "mupaw_project_preview",
    "mupaw_project_export",
}


def initialize(process: subprocess.Popen[bytes]) -> set[str]:
    base.write_message(
        process,
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": base.PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": "mupaw-m1b-smoke", "version": "1"},
            },
        },
    )
    initialized = base.result_for(base.read_message(process), 1)
    server = initialized.get("serverInfo")
    if not isinstance(server, dict) or server.get("name") != "Mupaw":
        raise base.SmokeFailure(f"Unexpected MCP server info: {server!r}")

    base.write_message(
        process,
        {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}},
    )
    base.write_message(
        process,
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
    )
    listed = base.result_for(base.read_message(process), 2)
    tools = listed.get("tools")
    if not isinstance(tools, list):
        raise base.SmokeFailure("tools/list omitted the tools array")
    names = {
        item.get("name")
        for item in tools
        if isinstance(item, dict) and isinstance(item.get("name"), str)
    }
    missing = EDITING_TOOLS - names
    if missing:
        raise base.SmokeFailure(f"M1b tools/list omitted: {sorted(missing)}")

    apply_tool = next(
        (
            item
            for item in tools
            if isinstance(item, dict) and item.get("name") == "mupaw_project_apply_edits"
        ),
        None,
    )
    schema = apply_tool.get("inputSchema") if isinstance(apply_tool, dict) else None
    properties = schema.get("properties") if isinstance(schema, dict) else None
    if not isinstance(properties, dict) or not {
        "project_id",
        "expected_revision",
        "commands",
    }.issubset(properties):
        raise base.SmokeFailure("M1b apply-edits tool schema is incomplete")
    return names


def capture_fixture(
    process: subprocess.Popen[bytes],
    request_id: int,
) -> tuple[dict[str, Any], dict[str, Any]]:
    status = base.parse_status(base.call_tool(process, request_id, "mupaw_app_status"))
    permissions = status.get("permissions")
    if status.get("running") is not True:
        raise base.SmokeFailure("Mupaw.app is not running")
    if not isinstance(permissions, dict) or permissions.get("screenCapture") != "authorized":
        raise base.SmokeFailure("Screen capture permission is not authorized")

    base.activate_mupaw_app()
    source: dict[str, Any] | None = None
    sources: list[Any] = []
    for attempt in range(24):
        if attempt > 0 and attempt % 8 == 0:
            base.activate_mupaw_app()
        sources_payload = base.parse_json_result(
            base.call_tool(process, request_id + 1 + attempt, "mupaw_sources_list"),
            "mupaw_sources_list",
        )
        sources = sources_payload.get("sources")
        if not isinstance(sources, list):
            raise base.SmokeFailure("mupaw_sources_list omitted sources")
        source = base.select_mupaw_window(
            sources,
            minimum_pixel_width=800,
            minimum_pixel_height=500,
        )
        if source is not None:
            break
        time.sleep(0.25)
    if source is None:
        visible_mupaw_windows = [
            item
            for item in sources
            if isinstance(item, dict)
            and item.get("kind") == "window"
            and (
                item.get("applicationBundleIdentifier") == "com.xiaodou.mupaw"
                or item.get("applicationName") == "Mupaw"
            )
        ]
        raise base.SmokeFailure(
            "No full-size visible Mupaw window was available for M1b smoke "
            f"({len(visible_mupaw_windows)} smaller Mupaw windows were visible)"
        )

    source_id = source.get("id")
    if not isinstance(source_id, str):
        raise base.SmokeFailure("Selected Mupaw source omitted id")
    result = base.call_tool(
        process,
        request_id + 30,
        "mupaw_screenshot_capture",
        {
            "mode": "window",
            "source_id": source_id,
            "format": "png",
            "include_cursor": False,
            "file_name": "Mupaw-M1b-Source",
        },
    )
    summary = base.validate_artifact(
        result,
        expected_source_id=source_id,
        expected_source_kind="window",
    )
    artifact = base.parse_json_result(result, "mupaw_screenshot_capture")
    return artifact, summary


def project_state(
    process: subprocess.Popen[bytes],
    request_id: int,
    tool_name: str,
    arguments: dict[str, Any],
) -> dict[str, Any]:
    state = base.parse_json_result(
        base.call_tool(process, request_id, tool_name, arguments),
        tool_name,
    )
    project_id = state.get("id")
    revision = state.get("revision")
    content = state.get("content")
    if not isinstance(project_id, str) or not isinstance(revision, int):
        raise base.SmokeFailure(f"{tool_name} returned invalid project identity")
    if not isinstance(content, dict) or not isinstance(content.get("objects"), list):
        raise base.SmokeFailure(f"{tool_name} returned invalid project content")
    return state


def validate_preview(
    result: dict[str, Any],
    *,
    expected_project_id: str,
    expected_revision: int,
    expected_width: int,
    expected_height: int,
) -> dict[str, Any]:
    tool_name = "mupaw_project_preview"
    payload = base.parse_json_result(result, tool_name)
    image = base.image_content(result, tool_name)
    preview = payload.get("preview")
    if not isinstance(preview, dict):
        raise base.SmokeFailure("project preview omitted preview metadata")
    if payload.get("projectID") != expected_project_id:
        raise base.SmokeFailure("project preview projectID mismatch")
    if payload.get("revision") != expected_revision:
        raise base.SmokeFailure("project preview revision mismatch")
    if payload.get("pixelWidth") != expected_width or payload.get("pixelHeight") != expected_height:
        raise base.SmokeFailure(
            "project preview dimensions mismatch: "
            f"expected={expected_width}x{expected_height}, "
            f"actual={payload.get('pixelWidth')}x{payload.get('pixelHeight')}"
        )
    if image.get("data") != preview.get("base64Data"):
        raise base.SmokeFailure("project preview image block does not match metadata")
    if image.get("mimeType") != preview.get("mimeType"):
        raise base.SmokeFailure("project preview MIME type does not match metadata")
    return payload


def validate_export(
    result: dict[str, Any],
    *,
    expected_project_id: str,
    expected_revision: int,
    expected_width: int,
    expected_height: int,
) -> dict[str, Any]:
    tool_name = "mupaw_project_export"
    payload = base.parse_json_result(result, tool_name)
    image = base.image_content(result, tool_name)
    preview = payload.get("preview")
    if not isinstance(preview, dict):
        raise base.SmokeFailure("project export omitted preview metadata")
    if payload.get("projectID") != expected_project_id:
        raise base.SmokeFailure("project export projectID mismatch")
    if payload.get("projectRevision") != expected_revision:
        raise base.SmokeFailure("project export revision mismatch")
    if payload.get("pixelWidth") != expected_width or payload.get("pixelHeight") != expected_height:
        raise base.SmokeFailure("project export dimensions mismatch")
    if image.get("data") != preview.get("base64Data"):
        raise base.SmokeFailure("project export image block does not match preview metadata")

    file_url = payload.get("fileURL")
    byte_count = payload.get("byteCount")
    expected_hash = payload.get("sha256")
    if not isinstance(file_url, str) or not isinstance(byte_count, int):
        raise base.SmokeFailure("project export omitted file metadata")
    if not isinstance(expected_hash, str) or len(expected_hash) != 64:
        raise base.SmokeFailure("project export omitted a valid SHA-256")

    parsed = urlparse(file_url)
    if parsed.scheme != "file":
        raise base.SmokeFailure(f"project export returned a non-file URL: {file_url!r}")
    path = Path(unquote(parsed.path)).resolve()
    export_root = (
        Path.home() / "Library" / "Application Support" / "Mupaw" / "Exports"
    ).resolve()
    try:
        path.relative_to(export_root)
    except ValueError as error:
        raise base.SmokeFailure(f"project export escaped the Exports directory: {path}") from error
    if not path.is_file():
        raise base.SmokeFailure(f"project export file does not exist: {path}")
    if stat.S_IMODE(path.stat().st_mode) != 0o600:
        raise base.SmokeFailure("project export permissions are not owner read/write only")
    data = path.read_bytes()
    if len(data) != byte_count:
        raise base.SmokeFailure("project export byte count mismatch")
    if hashlib.sha256(data).hexdigest() != expected_hash:
        raise base.SmokeFailure("project export SHA-256 mismatch")
    png_width, png_height = png_dimensions(data)
    if (png_width, png_height) != (expected_width, expected_height):
        raise base.SmokeFailure("exported PNG header dimensions do not match metadata")
    payload["resolvedPath"] = str(path)
    return payload


def png_dimensions(data: bytes) -> tuple[int, int]:
    if len(data) < 24 or data[:8] != b"\x89PNG\r\n\x1a\n" or data[12:16] != b"IHDR":
        raise base.SmokeFailure("exported file is not a valid PNG")
    return struct.unpack(">II", data[16:24])


def file_path_from_url(value: Any, label: str) -> Path:
    if not isinstance(value, str):
        raise base.SmokeFailure(f"{label} omitted file URL")
    parsed = urlparse(value)
    if parsed.scheme != "file":
        raise base.SmokeFailure(f"{label} returned a non-file URL")
    return Path(unquote(parsed.path)).resolve()


def object_ids(state: dict[str, Any]) -> set[str]:
    content = state.get("content")
    objects = content.get("objects") if isinstance(content, dict) else None
    if not isinstance(objects, list):
        raise base.SmokeFailure("project state omitted objects")
    ids = {
        item.get(payload_name, {}).get("id")
        for item in objects
        if isinstance(item, dict)
        for payload_name in (item.get("kind"),)
        if isinstance(payload_name, str) and isinstance(item.get(payload_name), dict)
    }
    if not all(isinstance(value, str) for value in ids):
        raise base.SmokeFailure("project object omitted a valid id")
    return ids


def run(executable: Path) -> dict[str, Any]:
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise base.SmokeFailure(f"MCP executable is missing or not executable: {executable}")

    process = subprocess.Popen(
        [str(executable)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        bufsize=0,
    )
    try:
        tool_names = initialize(process)
        artifact, capture_summary = capture_fixture(process, 10)

        capture_url = artifact.get("fileURL")
        capture_hash = artifact.get("sha256")
        artifact_id = artifact.get("id")
        width = artifact.get("pixelWidth")
        height = artifact.get("pixelHeight")
        if not all(isinstance(value, str) for value in (capture_url, capture_hash, artifact_id)):
            raise base.SmokeFailure("capture artifact omitted project-create fields")
        if not isinstance(width, int) or not isinstance(height, int):
            raise base.SmokeFailure("capture artifact omitted dimensions")

        created = project_state(
            process,
            20,
            "mupaw_project_create",
            {
                "source_file_url": capture_url,
                "source_sha256": capture_hash,
                "source_artifact_id": artifact_id,
                "title": "Mupaw M1b MCP Smoke",
            },
        )
        project_id = created["id"]
        if created.get("revision") != 1:
            raise base.SmokeFailure("new project did not start at revision 1")
        original_path = file_path_from_url(created.get("originalFileURL"), "project create")
        if not original_path.is_file():
            raise base.SmokeFailure("project original copy does not exist")
        if hashlib.sha256(original_path.read_bytes()).hexdigest() != capture_hash:
            raise base.SmokeFailure("project original copy does not preserve capture SHA-256")
        project_directory = original_path.parent
        project_document = project_directory / "project.json"
        if stat.S_IMODE(project_directory.stat().st_mode) != 0o700:
            raise base.SmokeFailure("project directory permissions are not owner-only")
        if stat.S_IMODE(original_path.stat().st_mode) != 0o600:
            raise base.SmokeFailure("project original permissions are not owner read/write only")
        if not project_document.is_file() or stat.S_IMODE(project_document.stat().st_mode) != 0o600:
            raise base.SmokeFailure("project document permissions are not owner read/write only")

        crop_x = max(1, width // 20)
        crop_y = max(1, height // 20)
        crop_width = max(40, width - crop_x * 2)
        crop_height = max(40, height - crop_y * 2)
        crop = {
            "x": crop_x,
            "y": crop_y,
            "width": crop_width,
            "height": crop_height,
        }
        arrow_id = str(uuid.uuid4())
        text_id = str(uuid.uuid4())
        mosaic_id = str(uuid.uuid4())
        replacement_mosaic_id = str(uuid.uuid4())
        red = {"red": 0.92, "green": 0.15, "blue": 0.18, "alpha": 1.0}
        blue = {"red": 0.10, "green": 0.45, "blue": 0.95, "alpha": 1.0}

        initial_commands = [
            {"type": "set_crop", "rect": crop},
            {
                "type": "add_object",
                "object": {
                    "kind": "arrow",
                    "arrow": {
                        "id": arrow_id,
                        "start": {"x": crop_x + crop_width * 0.15, "y": crop_y + crop_height * 0.25},
                        "end": {"x": crop_x + crop_width * 0.70, "y": crop_y + crop_height * 0.55},
                        "color": red,
                        "lineWidth": 12.0,
                    },
                },
            },
            {
                "type": "add_object",
                "object": {
                    "kind": "text",
                    "text": {
                        "id": text_id,
                        "frame": {
                            "x": crop_x + crop_width * 0.18,
                            "y": crop_y + crop_height * 0.62,
                            "width": crop_width * 0.52,
                            "height": max(36.0, crop_height * 0.14),
                        },
                        "text": "Mupaw M1b",
                        "color": red,
                        "fontSize": 42.0,
                    },
                },
            },
            {
                "type": "add_object",
                "object": {
                    "kind": "mosaic",
                    "mosaic": {
                        "id": mosaic_id,
                        "frame": {
                            "x": crop_x + crop_width * 0.66,
                            "y": crop_y + crop_height * 0.16,
                            "width": crop_width * 0.20,
                            "height": crop_height * 0.18,
                        },
                        "blockSize": 20.0,
                    },
                },
            },
        ]
        initial = project_state(
            process,
            21,
            "mupaw_project_apply_edits",
            {
                "project_id": project_id,
                "expected_revision": 1,
                "commands": initial_commands,
            },
        )
        if initial.get("revision") != 2 or object_ids(initial) != {arrow_id, text_id, mosaic_id}:
            raise base.SmokeFailure("initial M1b edit batch was not applied atomically")

        update_commands = [
            {
                "type": "update_object",
                "object": {
                    "kind": "arrow",
                    "arrow": {
                        "id": arrow_id,
                        "start": {"x": crop_x + crop_width * 0.12, "y": crop_y + crop_height * 0.30},
                        "end": {"x": crop_x + crop_width * 0.80, "y": crop_y + crop_height * 0.48},
                        "color": blue,
                        "lineWidth": 16.0,
                    },
                },
            },
            {
                "type": "update_object",
                "object": {
                    "kind": "text",
                    "text": {
                        "id": text_id,
                        "frame": {
                            "x": crop_x + crop_width * 0.20,
                            "y": crop_y + crop_height * 0.60,
                            "width": crop_width * 0.58,
                            "height": max(40.0, crop_height * 0.16),
                        },
                        "text": "Edited by Agent",
                        "color": blue,
                        "fontSize": 48.0,
                    },
                },
            },
            {"type": "delete_object", "object_id": mosaic_id},
            {
                "type": "add_object",
                "object": {
                    "kind": "mosaic",
                    "mosaic": {
                        "id": replacement_mosaic_id,
                        "frame": {
                            "x": crop_x + crop_width * 0.62,
                            "y": crop_y + crop_height * 0.18,
                            "width": crop_width * 0.24,
                            "height": crop_height * 0.22,
                        },
                        "blockSize": 24.0,
                    },
                },
            },
        ]
        updated = project_state(
            process,
            22,
            "mupaw_project_apply_edits",
            {
                "project_id": project_id,
                "expected_revision": 2,
                "commands": update_commands,
            },
        )
        if updated.get("revision") != 3:
            raise base.SmokeFailure("update batch did not advance to revision 3")
        if object_ids(updated) != {arrow_id, text_id, replacement_mosaic_id}:
            raise base.SmokeFailure("update/delete/add batch produced the wrong object set")

        conflict = base.expect_tool_error(
            base.call_tool(
                process,
                23,
                "mupaw_project_apply_edits",
                {
                    "project_id": project_id,
                    "expected_revision": 1,
                    "commands": [{"type": "reset"}],
                },
            ),
            "mupaw_project_apply_edits",
            "project_version_conflict",
        )
        invalid = base.expect_tool_error(
            base.call_tool(
                process,
                24,
                "mupaw_project_apply_edits",
                {
                    "project_id": project_id,
                    "expected_revision": 3,
                    "commands": [
                        {
                            "type": "update_object",
                            "object": {
                                "kind": "text",
                                "text": {
                                    "id": text_id,
                                    "frame": {
                                        "x": crop_x + 10,
                                        "y": crop_y + 10,
                                        "width": 100,
                                        "height": 40,
                                    },
                                    "text": "   ",
                                    "color": red,
                                    "fontSize": 24,
                                },
                            },
                        }
                    ],
                },
            ),
            "mupaw_project_apply_edits",
            "invalid_edit",
        )
        missing_crop_rect = base.expect_tool_error(
            base.call_tool(
                process,
                241,
                "mupaw_project_apply_edits",
                {
                    "project_id": project_id,
                    "expected_revision": 3,
                    "commands": [{"type": "set_crop"}],
                },
            ),
            "mupaw_project_apply_edits",
            "invalid_request",
        )

        undone = project_state(
            process,
            25,
            "mupaw_project_history",
            {"project_id": project_id, "expected_revision": 3, "action": "undo"},
        )
        if undone.get("revision") != 4 or object_ids(undone) != {arrow_id, text_id, mosaic_id}:
            raise base.SmokeFailure("undo did not restore the initial edit batch")
        redone = project_state(
            process,
            26,
            "mupaw_project_history",
            {"project_id": project_id, "expected_revision": 4, "action": "redo"},
        )
        if redone.get("revision") != 5 or object_ids(redone) != {
            arrow_id,
            text_id,
            replacement_mosaic_id,
        }:
            raise base.SmokeFailure("redo did not restore the updated edit batch")

        reset = project_state(
            process,
            27,
            "mupaw_project_apply_edits",
            {
                "project_id": project_id,
                "expected_revision": 5,
                "commands": [{"type": "reset"}],
            },
        )
        reset_content = reset.get("content")
        if reset.get("revision") != 6 or not isinstance(reset_content, dict):
            raise base.SmokeFailure("reset did not advance the project revision")
        if reset_content.get("objects") != [] or reset_content.get("cropRect") is not None:
            raise base.SmokeFailure("reset did not clear crop and edit objects")

        restored = project_state(
            process,
            28,
            "mupaw_project_history",
            {"project_id": project_id, "expected_revision": 6, "action": "undo"},
        )
        if restored.get("revision") != 7 or object_ids(restored) != {
            arrow_id,
            text_id,
            replacement_mosaic_id,
        }:
            raise base.SmokeFailure("undo after reset did not restore the edited project")

        preview_result = base.call_tool(
            process,
            29,
            "mupaw_project_preview",
            {"project_id": project_id, "expected_revision": 7},
        )
        preview = validate_preview(
            preview_result,
            expected_project_id=project_id,
            expected_revision=7,
            expected_width=crop_width,
            expected_height=crop_height,
        )

        export_result = base.call_tool(
            process,
            30,
            "mupaw_project_export",
            {
                "project_id": project_id,
                "expected_revision": 7,
                "file_name": "Mupaw-M1b-MCP-Export",
            },
        )
        exported = validate_export(
            export_result,
            expected_project_id=project_id,
            expected_revision=7,
            expected_width=crop_width,
            expected_height=crop_height,
        )
        export_preview = exported.get("preview")
        if not isinstance(export_preview, dict) or export_preview.get("base64Data") != preview.get(
            "preview", {}
        ).get("base64Data"):
            raise base.SmokeFailure("preview and export did not use an identical rendered image")

        fetched = project_state(
            process,
            31,
            "mupaw_project_get",
            {"project_id": project_id},
        )
        if fetched.get("revision") != 7 or fetched.get("content") != restored.get("content"):
            raise base.SmokeFailure("project_get did not return the persisted current state")
        if hashlib.sha256(original_path.read_bytes()).hexdigest() != capture_hash:
            raise base.SmokeFailure("editing modified the preserved original image")

        return {
            "toolCount": len(tool_names),
            "editingTools": sorted(EDITING_TOOLS),
            "capture": capture_summary,
            "project": {
                "id": project_id,
                "revision": fetched.get("revision"),
                "objectIDs": sorted(object_ids(fetched)),
                "crop": fetched.get("content", {}).get("cropRect"),
                "originalFile": str(original_path),
                "originalSHA256": capture_hash,
            },
            "preview": {
                "pixelWidth": preview.get("pixelWidth"),
                "pixelHeight": preview.get("pixelHeight"),
                "mimeType": preview.get("preview", {}).get("mimeType"),
            },
            "export": {
                "file": exported.get("resolvedPath"),
                "pixelWidth": exported.get("pixelWidth"),
                "pixelHeight": exported.get("pixelHeight"),
                "byteCount": exported.get("byteCount"),
                "sha256": exported.get("sha256"),
            },
            "negativeChecks": {
                "versionConflict": conflict,
                "invalidEdit": invalid,
                "missingCropRect": missing_crop_rect,
            },
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
    args = parser.parse_args()
    try:
        summary = run(args.executable.resolve())
    except base.SmokeFailure as error:
        print(f"M1b MCP smoke test failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
