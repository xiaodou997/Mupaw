#!/usr/bin/env python3
"""End-to-end M1d visual-style smoke test through MCP."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any

import m1b_smoke as m1b
import mcp_smoke as base

STYLE_COMMANDS = {
    "set_visual_style",
    "apply_style_preset",
    "clear_visual_style",
}


def project_content(state: dict[str, Any]) -> dict[str, Any]:
    content = state.get("content")
    if not isinstance(content, dict):
        raise base.SmokeFailure("Project state omitted content")
    return content


def visual_style(state: dict[str, Any]) -> dict[str, Any] | None:
    value = project_content(state).get("visualStyle")
    if value is not None and not isinstance(value, dict):
        raise base.SmokeFailure("Project visualStyle is not an object or null")
    return value


def preview_payload(
    process: subprocess.Popen[bytes],
    request_id: int,
    project_id: str,
    revision: int,
) -> dict[str, Any]:
    result = base.call_tool(
        process,
        request_id,
        "mupaw_project_preview",
        {"project_id": project_id, "expected_revision": revision},
    )
    payload = base.parse_json_result(result, "mupaw_project_preview")
    image = base.image_content(result, "mupaw_project_preview")
    preview = payload.get("preview")
    if not isinstance(preview, dict):
        raise base.SmokeFailure("Styled preview omitted preview metadata")
    if payload.get("projectID") != project_id or payload.get("revision") != revision:
        raise base.SmokeFailure("Styled preview project identity mismatch")
    width = payload.get("pixelWidth")
    height = payload.get("pixelHeight")
    if not isinstance(width, int) or not isinstance(height, int) or width <= 0 or height <= 0:
        raise base.SmokeFailure("Styled preview returned invalid dimensions")
    if image.get("data") != preview.get("base64Data"):
        raise base.SmokeFailure("Styled preview image block does not match metadata")
    if image.get("mimeType") != preview.get("mimeType"):
        raise base.SmokeFailure("Styled preview MIME type does not match metadata")
    return payload


def validate_style(value: Any, *, expected_mode: str | None = None) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise base.SmokeFailure("Expected a persisted visual style")
    background = value.get("background")
    shadow = value.get("shadow")
    if not isinstance(background, dict) or not isinstance(shadow, dict):
        raise base.SmokeFailure("Visual style omitted background or shadow")
    if expected_mode is not None and background.get("mode") != expected_mode:
        raise base.SmokeFailure(
            f"Visual style background mode mismatch: {background.get('mode')!r}"
        )
    if value.get("canvas_aspect") not in {
        "automatic",
        "square",
        "landscape_4_3",
        "landscape_16_9",
        "portrait_3_4",
        "portrait_9_16",
    }:
        raise base.SmokeFailure("Visual style omitted a valid canvas_aspect")
    for key in ("padding", "corner_radius"):
        if not isinstance(value.get(key), (int, float)):
            raise base.SmokeFailure(f"Visual style omitted numeric {key}")
    for key in ("is_enabled", "color", "blur_radius", "offset_x", "offset_y"):
        if key not in shadow:
            raise base.SmokeFailure(f"Visual style shadow omitted {key}")
    return value


def custom_style() -> dict[str, Any]:
    return {
        "background": {
            "mode": "linear_gradient",
            "start_color": {"red": 0.12, "green": 0.42, "blue": 0.96, "alpha": 1.0},
            "end_color": {"red": 0.13, "green": 0.84, "blue": 0.70, "alpha": 1.0},
            "angle_degrees": 35.0,
        },
        "padding": 80.0,
        "corner_radius": 40.0,
        "shadow": {
            "is_enabled": True,
            "color": {"red": 0.01, "green": 0.04, "blue": 0.12, "alpha": 0.38},
            "blur_radius": 30.0,
            "offset_x": 8.0,
            "offset_y": 18.0,
        },
        "canvas_aspect": "square",
    }


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
        tool_names = m1b.initialize(process)
        artifact, capture_summary = m1b.capture_fixture(process, 10)
        capture_url = artifact.get("fileURL")
        capture_hash = artifact.get("sha256")
        artifact_id = artifact.get("id")
        source_width = artifact.get("pixelWidth")
        source_height = artifact.get("pixelHeight")
        if not all(isinstance(value, str) for value in (capture_url, capture_hash, artifact_id)):
            raise base.SmokeFailure("Capture omitted M1d project-create fields")
        if not isinstance(source_width, int) or not isinstance(source_height, int):
            raise base.SmokeFailure("Capture omitted M1d dimensions")

        created = m1b.project_state(
            process,
            20,
            "mupaw_project_create",
            {
                "source_file_url": capture_url,
                "source_sha256": capture_hash,
                "source_artifact_id": artifact_id,
                "title": "Mupaw M1d Visual Style Smoke",
            },
        )
        project_id = created["id"]
        if created.get("revision") != 1 or visual_style(created) is not None:
            raise base.SmokeFailure("New project did not start unstyled at revision 1")
        original_path = m1b.file_path_from_url(created.get("originalFileURL"), "M1d project")
        original_before = hashlib.sha256(original_path.read_bytes()).hexdigest()
        if original_before != capture_hash:
            raise base.SmokeFailure("M1d project original differs from capture")

        preset = m1b.project_state(
            process,
            21,
            "mupaw_project_apply_edits",
            {
                "project_id": project_id,
                "expected_revision": 1,
                "commands": [{"type": "apply_style_preset", "preset": "ocean"}],
            },
        )
        if preset.get("revision") != 2:
            raise base.SmokeFailure("Style preset did not advance to revision 2")
        preset_style = validate_style(visual_style(preset), expected_mode="linear_gradient")
        preset_preview = preview_payload(process, 22, project_id, 2)
        expected_preset_width = source_width + 400
        expected_preset_height = source_height + 400
        if (
            preset_preview.get("pixelWidth") != expected_preset_width
            or preset_preview.get("pixelHeight") != expected_preset_height
        ):
            raise base.SmokeFailure(
                "Ocean preset output dimensions do not include deterministic padding and shadow"
            )
        preset_export_result = base.call_tool(
            process,
            23,
            "mupaw_project_export",
            {
                "project_id": project_id,
                "expected_revision": 2,
                "file_name": "Mupaw-M1d-Ocean",
            },
        )
        preset_export = m1b.validate_export(
            preset_export_result,
            expected_project_id=project_id,
            expected_revision=2,
            expected_width=expected_preset_width,
            expected_height=expected_preset_height,
        )

        custom = custom_style()
        custom_state = m1b.project_state(
            process,
            24,
            "mupaw_project_apply_edits",
            {
                "project_id": project_id,
                "expected_revision": 2,
                "commands": [{"type": "set_visual_style", "style": custom}],
            },
        )
        if custom_state.get("revision") != 3:
            raise base.SmokeFailure("Custom style did not advance to revision 3")
        persisted_custom = validate_style(
            visual_style(custom_state), expected_mode="linear_gradient"
        )
        if persisted_custom != custom:
            raise base.SmokeFailure("Persisted custom visual style differs from the request")

        custom_preview = preview_payload(process, 25, project_id, 3)
        expected_square = max(source_width + 280, source_height + 280)
        if (
            custom_preview.get("pixelWidth") != expected_square
            or custom_preview.get("pixelHeight") != expected_square
        ):
            raise base.SmokeFailure("Square custom style did not produce a square bounded canvas")
        custom_export_result = base.call_tool(
            process,
            26,
            "mupaw_project_export",
            {
                "project_id": project_id,
                "expected_revision": 3,
                "file_name": "Mupaw-M1d-Custom",
            },
        )
        custom_export = m1b.validate_export(
            custom_export_result,
            expected_project_id=project_id,
            expected_revision=3,
            expected_width=expected_square,
            expected_height=expected_square,
        )

        invalid_style = json.loads(json.dumps(custom))
        invalid_style["padding"] = 999_999
        invalid = base.expect_tool_error(
            base.call_tool(
                process,
                27,
                "mupaw_project_apply_edits",
                {
                    "project_id": project_id,
                    "expected_revision": 3,
                    "commands": [
                        {"type": "set_crop", "rect": None},
                        {"type": "set_visual_style", "style": invalid_style},
                    ],
                },
            ),
            "mupaw_project_apply_edits",
            "invalid_edit",
        )
        after_invalid = m1b.project_state(
            process,
            28,
            "mupaw_project_get",
            {"project_id": project_id},
        )
        if after_invalid.get("revision") != 3 or visual_style(after_invalid) != custom:
            raise base.SmokeFailure("Invalid style batch was not rejected atomically")

        undone = m1b.project_state(
            process,
            29,
            "mupaw_project_history",
            {"project_id": project_id, "expected_revision": 3, "action": "undo"},
        )
        if undone.get("revision") != 4 or visual_style(undone) != preset_style:
            raise base.SmokeFailure("Undo did not restore the preset style")
        redone = m1b.project_state(
            process,
            30,
            "mupaw_project_history",
            {"project_id": project_id, "expected_revision": 4, "action": "redo"},
        )
        if redone.get("revision") != 5 or visual_style(redone) != custom:
            raise base.SmokeFailure("Redo did not restore the custom style")

        cleared = m1b.project_state(
            process,
            31,
            "mupaw_project_apply_edits",
            {
                "project_id": project_id,
                "expected_revision": 5,
                "commands": [{"type": "clear_visual_style"}],
            },
        )
        if cleared.get("revision") != 6 or visual_style(cleared) is not None:
            raise base.SmokeFailure("clear_visual_style did not remove styling")
        clear_preview = preview_payload(process, 32, project_id, 6)
        if (
            clear_preview.get("pixelWidth") != source_width
            or clear_preview.get("pixelHeight") != source_height
        ):
            raise base.SmokeFailure("Removing style did not restore exact source dimensions")

        none_preset = m1b.project_state(
            process,
            33,
            "mupaw_project_apply_edits",
            {
                "project_id": project_id,
                "expected_revision": 6,
                "commands": [{"type": "apply_style_preset", "preset": "none"}],
            },
        )
        if none_preset.get("revision") != 7 or visual_style(none_preset) is not None:
            raise base.SmokeFailure("The none preset did not remain unstyled")

        if hashlib.sha256(original_path.read_bytes()).hexdigest() != original_before:
            raise base.SmokeFailure("M1d visual styling modified the immutable project original")

        return {
            "toolCount": len(tool_names),
            "styleCommands": sorted(STYLE_COMMANDS),
            "capture": capture_summary,
            "project": {
                "id": project_id,
                "finalRevision": none_preset.get("revision"),
                "originalSHA256": original_before,
            },
            "preset": {
                "style": preset_style,
                "preview": {
                    "width": preset_preview.get("pixelWidth"),
                    "height": preset_preview.get("pixelHeight"),
                },
                "export": {
                    "file": preset_export.get("resolvedPath"),
                    "sha256": preset_export.get("sha256"),
                },
            },
            "custom": {
                "style": custom,
                "preview": {
                    "width": custom_preview.get("pixelWidth"),
                    "height": custom_preview.get("pixelHeight"),
                },
                "export": {
                    "file": custom_export.get("resolvedPath"),
                    "sha256": custom_export.get("sha256"),
                },
            },
            "negativeChecks": {"invalidStyle": invalid},
            "history": {
                "undoRevision": undone.get("revision"),
                "redoRevision": redone.get("revision"),
                "clearRevision": cleared.get("revision"),
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
        print(f"M1d MCP smoke test failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps(summary, indent=2, sort_keys=True, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
