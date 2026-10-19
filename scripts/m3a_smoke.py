#!/usr/bin/env python3
"""End-to-end M3a camera picture-in-picture smoke test through MCP."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Any

import m1e_smoke as m1e
import m2a_smoke as m2a
import mcp_smoke as base

ROOT = Path(__file__).resolve().parents[1]
CAMERA_INSPECTOR_SOURCE = ROOT / "scripts" / "inspect_camera_overlay.swift"
CAMERA_INSPECTOR_BINARY = Path("/tmp/mupaw-m3a-inspect-camera-overlay")
TONE_PATH = Path("/tmp/mupaw-m3a-system-audio-tone.wav")


def file_set(prefix: str) -> set[Path]:
    if not m1e.RECORDINGS_ROOT.is_dir():
        return set()
    return {
        item.resolve()
        for item in m1e.RECORDINGS_ROOT.iterdir()
        if item.is_file() and (item.name.startswith(prefix) or "intermediate" in item.name)
    }


def choose_camera(payload: dict[str, Any]) -> dict[str, Any]:
    devices = payload.get("devices")
    if not isinstance(devices, list) or not devices:
        raise base.SmokeFailure("M3a found no camera devices")
    default_id = payload.get("defaultDeviceID")
    selected = next(
        (
            item
            for item in devices
            if isinstance(item, dict)
            and item.get("id") == default_id
            and item.get("isConnected") is True
        ),
        None,
    )
    if selected is None:
        selected = next(
            (
                item
                for item in devices
                if isinstance(item, dict) and item.get("isConnected") is True
            ),
            None,
        )
    if not isinstance(selected, dict) or not isinstance(selected.get("id"), str):
        raise base.SmokeFailure("M3a found no connected camera")
    return selected


def overlay(
    camera_id: str,
    *,
    visible: bool = True,
    position: str = "bottom_right",
    size: str = "medium",
    shape: str = "circle",
    corner_radius: float = 0.12,
    margin: float = 0.025,
) -> dict[str, Any]:
    return {
        "enabled": True,
        "camera_device_id": camera_id,
        "visible": visible,
        "position": position,
        "size": size,
        "shape": shape,
        "corner_radius": corner_radius,
        "margin": margin,
    }


def validate_live_camera(
    status: dict[str, Any],
    *,
    camera_id: str,
    visible: bool = True,
    position: str,
    size: str,
    shape: str,
    corner_radius: float = 0.12,
    margin: float = 0.025,
    minimum_control_events: int = 1,
    require_frames: bool,
) -> dict[str, Any]:
    camera = status.get("camera")
    if not isinstance(camera, dict):
        raise base.SmokeFailure("recording status omitted camera metadata")
    if camera.get("requested") is not True:
        raise base.SmokeFailure("recording status did not mark camera requested")
    if camera.get("deviceID") != camera_id:
        raise base.SmokeFailure("recording status camera device mismatch")
    if camera.get("position") != position or camera.get("size") != size or camera.get("shape") != shape:
        raise base.SmokeFailure("recording status camera layout mismatch")
    if camera.get("visible") is not visible:
        raise base.SmokeFailure("recording status camera visibility mismatch")
    if abs(float(camera.get("cornerRadius", -1)) - corner_radius) > 0.0001:
        raise base.SmokeFailure("recording status camera corner radius mismatch")
    if abs(float(camera.get("margin", -1)) - margin) > 0.0001:
        raise base.SmokeFailure("recording status camera margin mismatch")
    if not isinstance(camera.get("controlEventCount"), int) or camera["controlEventCount"] < minimum_control_events:
        raise base.SmokeFailure("recording status camera control event count is invalid")
    state = camera.get("state")
    if state not in {"waiting", "capturing"}:
        raise base.SmokeFailure(f"recording status returned invalid camera state: {state!r}")
    frame_count = camera.get("frameCount")
    if not isinstance(frame_count, int) or frame_count < 0:
        raise base.SmokeFailure("recording status returned invalid camera frame count")
    if require_frames:
        if state != "capturing" or frame_count <= 0:
            raise base.SmokeFailure("camera did not enter capturing state")
        if camera.get("isStale") is not False:
            raise base.SmokeFailure("live camera status is stale")
        if not isinstance(camera.get("lastFrameAt"), str):
            raise base.SmokeFailure("live camera omitted lastFrameAt")
        if not isinstance(camera.get("lastSourceTimestampSeconds"), (int, float)):
            raise base.SmokeFailure("live camera omitted source timestamp")
        if not isinstance(camera.get("sourcePixelWidth"), int) or camera.get("sourcePixelWidth", 0) <= 0:
            raise base.SmokeFailure("live camera omitted source width")
        if not isinstance(camera.get("sourcePixelHeight"), int) or camera.get("sourcePixelHeight", 0) <= 0:
            raise base.SmokeFailure("live camera omitted source height")
    rect = camera.get("overlayRectPixels")
    if not isinstance(rect, dict):
        raise base.SmokeFailure("live camera omitted overlay rectangle")
    for key in ("x", "y", "width", "height"):
        if not isinstance(rect.get(key), (int, float)):
            raise base.SmokeFailure(f"camera overlay rectangle omitted {key}")
    if rect["width"] <= 0 or rect["height"] <= 0:
        raise base.SmokeFailure("camera overlay rectangle has invalid dimensions")
    return camera


def validate_completed_camera(
    camera: Any,
    *,
    camera_id: str,
    visible: bool = True,
    position: str,
    size: str,
    shape: str,
    corner_radius: float = 0.12,
    margin: float = 0.025,
    minimum_control_events: int = 1,
) -> dict[str, Any]:
    if not isinstance(camera, dict):
        raise base.SmokeFailure("completed artifact omitted camera metadata")
    if camera.get("requested") is not True or camera.get("state") != "completed":
        raise base.SmokeFailure("completed artifact did not complete camera capture")
    if camera.get("deviceID") != camera_id:
        raise base.SmokeFailure("completed artifact camera device mismatch")
    if camera.get("position") != position or camera.get("size") != size or camera.get("shape") != shape:
        raise base.SmokeFailure("completed artifact camera layout mismatch")
    if camera.get("visible") is not visible:
        raise base.SmokeFailure("completed artifact camera visibility mismatch")
    if abs(float(camera.get("cornerRadius", -1)) - corner_radius) > 0.0001:
        raise base.SmokeFailure("completed artifact camera corner radius mismatch")
    if abs(float(camera.get("margin", -1)) - margin) > 0.0001:
        raise base.SmokeFailure("completed artifact camera margin mismatch")
    if not isinstance(camera.get("controlEventCount"), int) or camera["controlEventCount"] < minimum_control_events:
        raise base.SmokeFailure("completed artifact camera control event count is invalid")
    if not isinstance(camera.get("deviceName"), str) or not camera["deviceName"]:
        raise base.SmokeFailure("completed artifact omitted camera device name")
    if not isinstance(camera.get("frameCount"), int) or camera["frameCount"] <= 0:
        raise base.SmokeFailure("completed artifact camera frame count is invalid")
    if not isinstance(camera.get("lastFrameAt"), str):
        raise base.SmokeFailure("completed artifact omitted camera lastFrameAt")
    if camera.get("isStale") is not False:
        raise base.SmokeFailure("completed artifact incorrectly marked camera stale")
    rect = camera.get("overlayRectPixels")
    if not isinstance(rect, dict):
        raise base.SmokeFailure("completed artifact omitted camera overlay rectangle")
    return camera


def compile_camera_inspector() -> Path:
    if (
        CAMERA_INSPECTOR_BINARY.is_file()
        and os.access(CAMERA_INSPECTOR_BINARY, os.X_OK)
        and CAMERA_INSPECTOR_BINARY.stat().st_mtime >= CAMERA_INSPECTOR_SOURCE.stat().st_mtime
    ):
        return CAMERA_INSPECTOR_BINARY
    result = subprocess.run(
        [
            "xcrun",
            "swiftc",
            "-parse-as-library",
            str(CAMERA_INSPECTOR_SOURCE),
            "-o",
            str(CAMERA_INSPECTOR_BINARY),
            "-framework",
            "AVFoundation",
            "-framework",
            "CoreGraphics",
            "-framework",
            "CoreMedia",
        ],
        check=False,
        capture_output=True,
        text=True,
        timeout=120,
    )
    if result.returncode != 0:
        raise base.SmokeFailure(
            "Could not compile the camera-overlay inspector: "
            + (result.stderr.strip() or result.stdout.strip())
        )
    return CAMERA_INSPECTOR_BINARY


def inspect_camera_overlay(path: Path, rect: dict[str, Any]) -> dict[str, Any]:
    arguments = [
        str(compile_camera_inspector()),
        str(path),
        str(int(round(float(rect["x"])))),
        str(int(round(float(rect["y"])))),
        str(int(round(float(rect["width"])))),
        str(int(round(float(rect["height"])))),
    ]
    result = subprocess.run(
        arguments,
        check=False,
        capture_output=True,
        text=True,
        timeout=120,
    )
    if result.returncode != 0:
        raise base.SmokeFailure(
            "Camera-overlay inspector failed: " + (result.stderr.strip() or result.stdout.strip())
        )
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise base.SmokeFailure("camera-overlay inspector returned invalid JSON") from error
    if not isinstance(payload, dict):
        raise base.SmokeFailure("camera-overlay inspector did not return an object")
    differences = payload.get("spatialMeanAbsoluteDifference")
    overlay_variance = payload.get("overlayVariance")
    overlay_edges = payload.get("overlayEdgeEnergy")
    temporal = payload.get("temporalMeanAbsoluteDifference")
    if payload.get("frameSamples") != 3 or payload.get("sampleCount", 0) <= 0:
        raise base.SmokeFailure("camera-overlay inspector decoded insufficient video samples")
    if not isinstance(differences, list) or len(differences) != 3:
        raise base.SmokeFailure("camera-overlay inspector omitted spatial differences")
    if max(float(value) for value in differences) < 0.015:
        raise base.SmokeFailure(
            f"the baked camera region was not distinguishable from the opposite fixture corner: {differences}"
        )
    if not isinstance(overlay_variance, list) or not isinstance(overlay_edges, list):
        raise base.SmokeFailure("camera-overlay inspector omitted texture metrics")
    if max(float(value) for value in overlay_variance) < 0.00005 and max(
        float(value) for value in overlay_edges
    ) < 0.001:
        raise base.SmokeFailure("the camera overlay region contained no meaningful image texture")
    if not isinstance(temporal, list) or len(temporal) != 2:
        raise base.SmokeFailure("camera-overlay inspector omitted temporal differences")
    return payload


def run(executable: Path) -> dict[str, Any]:
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise base.SmokeFailure(f"MCP executable is missing or not executable: {executable}")

    m1e.prepare_recording_fixture()
    process = subprocess.Popen(
        [str(executable)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        bufsize=0,
    )
    active_sessions: set[str] = set()
    tone_process: subprocess.Popen[bytes] | None = None
    try:
        tools = m1e.initialize(process)
        names = {item.get("name") for item in tools if isinstance(item, dict)}
        if "mupaw_cameras_list" not in names:
            raise base.SmokeFailure("M3a tools/list omitted mupaw_cameras_list")
        if "mupaw_recording_update_camera_overlay" not in names:
            raise base.SmokeFailure("M3a tools/list omitted camera overlay update tool")
        start_tool = next(
            (
                item
                for item in tools
                if isinstance(item, dict) and item.get("name") == "mupaw_recording_start"
            ),
            None,
        )
        schema = start_tool.get("inputSchema") if isinstance(start_tool, dict) else None
        properties = schema.get("properties") if isinstance(schema, dict) else None
        camera_schema = properties.get("camera_overlay") if isinstance(properties, dict) else None
        camera_properties = (
            camera_schema.get("properties") if isinstance(camera_schema, dict) else None
        )
        required_camera_fields = {
            "enabled",
            "camera_device_id",
            "visible",
            "position",
            "size",
            "shape",
            "corner_radius",
            "margin",
        }
        if not isinstance(camera_properties, dict) or not required_camera_fields.issubset(
            camera_properties
        ):
            raise base.SmokeFailure("M3a camera overlay schema is incomplete")

        update_tool = next(
            (
                item
                for item in tools
                if isinstance(item, dict)
                and item.get("name") == "mupaw_recording_update_camera_overlay"
            ),
            None,
        )
        update_schema = update_tool.get("inputSchema") if isinstance(update_tool, dict) else None
        update_properties = update_schema.get("properties") if isinstance(update_schema, dict) else None
        required_update_fields = {
            "session_id",
            "visible",
            "position",
            "size",
            "shape",
            "corner_radius",
            "margin",
        }
        if not isinstance(update_properties, dict) or not required_update_fields.issubset(
            update_properties
        ):
            raise base.SmokeFailure("M3a camera update schema is incomplete")

        cameras = base.parse_json_result(
            base.call_tool(process, 3, "mupaw_cameras_list"),
            "mupaw_cameras_list",
        )
        if cameras.get("permission") != "authorized":
            raise base.SmokeFailure(
                "M3a smoke requires camera permission for the stably signed Mupaw app"
            )
        camera = choose_camera(cameras)
        camera_id = camera["id"]

        app_status, sources = m1e.app_and_sources(process, 10)
        source = m1e.select_mupaw_window_with_retry(process, sources, 100)
        source_id = source.get("id")
        if not isinstance(source_id, str):
            raise base.SmokeFailure("M3a fixture window omitted source id")

        invalid_prefix = "Mupaw-M3a-Invalid-Camera"
        before = file_set(invalid_prefix)
        invalid_device = base.expect_tool_error(
            base.call_tool(
                process,
                20,
                "mupaw_recording_start",
                {
                    "mode": "window",
                    "source_id": source_id,
                    "camera_overlay": overlay("mupaw-missing-camera"),
                    "file_name": invalid_prefix,
                },
                timeout=60,
            ),
            "mupaw_recording_start",
            "camera_device_not_found",
        )
        if file_set(invalid_prefix) != before:
            raise base.SmokeFailure("invalid camera request created an output file")

        disabled_device = base.expect_tool_error(
            base.call_tool(
                process,
                21,
                "mupaw_recording_start",
                {
                    "mode": "window",
                    "source_id": source_id,
                    "camera_overlay": {
                        "enabled": False,
                        "camera_device_id": camera_id,
                    },
                    "file_name": "Mupaw-M3a-Disabled-Camera-Device",
                },
            ),
            "mupaw_recording_start",
            "invalid_camera_overlay",
        )

        invalid_layout = base.expect_tool_error(
            base.call_tool(
                process,
                22,
                "mupaw_recording_start",
                {
                    "mode": "window",
                    "source_id": source_id,
                    "camera_overlay": overlay(camera_id, margin=0.5),
                    "file_name": "Mupaw-M3a-Invalid-Layout",
                },
            ),
            "mupaw_recording_start",
            "invalid_camera_overlay",
        )

        camera_start = m1e.start_recording(
            process,
            30,
            mode="window",
            source_id=source_id,
            frame_rate=30,
            quality="standard",
            file_name="Mupaw-M3a-Camera-Smoke",
            camera_overlay=overlay(camera_id),
        )
        camera_session = camera_start["id"]
        active_sessions.add(camera_session)
        live_camera: dict[str, Any] | None = None
        request_id = 31
        deadline = time.monotonic() + 12
        while time.monotonic() < deadline:
            time.sleep(0.35)
            status = m1e.poll_status(process, request_id, camera_session)
            request_id += 1
            if status.get("phase") not in {"starting", "recording", "stopping"}:
                raise base.SmokeFailure(
                    "M3a camera recording became terminal early: "
                    + json.dumps(status, ensure_ascii=False, sort_keys=True)
                )
            current = validate_live_camera(
                status,
                camera_id=camera_id,
                position="bottom_right",
                size="medium",
                shape="circle",
                require_frames=False,
            )
            if current.get("state") == "capturing" and current.get("frameCount", 0) >= 12:
                live_camera = current
                break
        if live_camera is None:
            raise base.SmokeFailure("M3a camera did not produce enough live frames")
        validate_live_camera(
            status,
            camera_id=camera_id,
            position="bottom_right",
            size="medium",
            shape="circle",
            require_frames=True,
        )

        invalid_runtime_update = base.expect_tool_error(
            base.call_tool(
                process,
                request_id,
                "mupaw_recording_update_camera_overlay",
                {"session_id": camera_session, "corner_radius": 0.8},
            ),
            "mupaw_recording_update_camera_overlay",
            "invalid_camera_overlay",
        )
        request_id += 1

        hidden_status = base.parse_json_result(
            base.call_tool(
                process,
                request_id,
                "mupaw_recording_update_camera_overlay",
                {
                    "session_id": camera_session,
                    "visible": False,
                    "position": "top_left",
                    "size": "large",
                    "shape": "rounded_rectangle",
                    "corner_radius": 0.3,
                    "margin": 0.08,
                },
            ),
            "mupaw_recording_update_camera_overlay",
        )
        request_id += 1
        validate_live_camera(
            hidden_status,
            camera_id=camera_id,
            visible=False,
            position="top_left",
            size="large",
            shape="rounded_rectangle",
            corner_radius=0.3,
            margin=0.08,
            minimum_control_events=2,
            require_frames=True,
        )
        time.sleep(1.0)

        visible_status = base.parse_json_result(
            base.call_tool(
                process,
                request_id,
                "mupaw_recording_update_camera_overlay",
                {"session_id": camera_session, "visible": True},
            ),
            "mupaw_recording_update_camera_overlay",
        )
        request_id += 1
        live_camera = validate_live_camera(
            visible_status,
            camera_id=camera_id,
            visible=True,
            position="top_left",
            size="large",
            shape="rounded_rectangle",
            corner_radius=0.3,
            margin=0.08,
            minimum_control_events=3,
            require_frames=True,
        )
        time.sleep(3.0)

        camera_result = base.call_tool(
            process,
            request_id,
            "mupaw_recording_stop",
            {"session_id": camera_session},
            timeout=180,
        )
        camera_summary = m1e.validate_completed(
            camera_result,
            expected_session_id=camera_session,
            expected_source_kind="window",
            expected_frame_rate=30,
            minimum_duration=2.5,
        )
        active_sessions.discard(camera_session)
        completed_camera = validate_completed_camera(
            camera_summary.get("camera"),
            camera_id=camera_id,
            visible=True,
            position="top_left",
            size="large",
            shape="rounded_rectangle",
            corner_radius=0.3,
            margin=0.08,
            minimum_control_events=3,
        )
        if camera_summary["inspection"].get("videoTrackCount") != 1:
            raise base.SmokeFailure("camera recording must contain exactly one video track")
        if camera_summary["inspection"].get("audioTrackCount") != 0:
            raise base.SmokeFailure("camera-only smoke unexpectedly contains audio")
        visual_inspection = inspect_camera_overlay(
            Path(camera_summary["file"]),
            completed_camera["overlayRectPixels"],
        )

        # Exercise camera composition through the M2a audio post-processing path as well.
        m2a.generate_two_tone(TONE_PATH, duration_seconds=4.5)
        audio_camera_region = m1e.window_region(source)
        audio_camera_start = m1e.start_recording(
            process,
            request_id + 1,
            mode="region",
            region=audio_camera_region,
            frame_rate=30,
            quality="standard",
            file_name="Mupaw-M3a-Camera-System-Audio-Smoke",
            audio_source="system_audio",
            camera_overlay=overlay(
                camera_id,
                position="top_left",
                size="small",
                shape="rounded_rectangle",
            ),
        )
        audio_camera_session = audio_camera_start["id"]
        active_sessions.add(audio_camera_session)
        tone_process = subprocess.Popen(
            ["/usr/bin/afplay", str(TONE_PATH)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        time.sleep(1.25)
        audio_camera_status = m1e.poll_status(
            process,
            request_id + 2,
            audio_camera_session,
        )
        validate_live_camera(
            audio_camera_status,
            camera_id=camera_id,
            position="top_left",
            size="small",
            shape="rounded_rectangle",
            require_frames=True,
        )
        if audio_camera_status.get("audio", {}).get("sampleBufferCount", 0) <= 0:
            raise base.SmokeFailure("camera-plus-system-audio smoke received no audio samples")
        tone_process.wait(timeout=10)
        tone_process = None
        time.sleep(0.25)
        audio_camera_result = base.call_tool(
            process,
            request_id + 3,
            "mupaw_recording_stop",
            {"session_id": audio_camera_session},
            timeout=180,
        )
        audio_camera_summary = m1e.validate_completed(
            audio_camera_result,
            expected_session_id=audio_camera_session,
            expected_source_kind="region",
            expected_frame_rate=30,
            minimum_duration=3.5,
            expected_audio_source="system_audio",
            minimum_audio_rms=0.005,
        )
        active_sessions.discard(audio_camera_session)
        validate_completed_camera(
            audio_camera_summary.get("camera"),
            camera_id=camera_id,
            position="top_left",
            size="small",
            shape="rounded_rectangle",
        )
        if audio_camera_summary["inspection"].get("videoTrackCount") != 1:
            raise base.SmokeFailure("camera-plus-audio MP4 contained more than one video track")
        if audio_camera_summary["inspection"].get("audioTrackCount") != 1:
            raise base.SmokeFailure("camera-plus-audio MP4 did not contain one AAC track")

        cancel_prefix = "Mupaw-M3a-Camera-Cancel"
        before = file_set(cancel_prefix)
        cancel_start = m1e.start_recording(
            process,
            request_id + 4,
            mode="window",
            source_id=source_id,
            frame_rate=15,
            quality="standard",
            file_name=cancel_prefix,
            camera_overlay=overlay(camera_id),
        )
        cancel_session = cancel_start["id"]
        active_sessions.add(cancel_session)
        time.sleep(1.0)
        cancelled = base.parse_json_result(
            base.call_tool(
                process,
                request_id + 5,
                "mupaw_recording_cancel",
                {"session_id": cancel_session},
                timeout=60,
            ),
            "mupaw_recording_cancel",
        )
        active_sessions.discard(cancel_session)
        if cancelled.get("phase") != "cancelled" or cancelled.get("artifact") is not None:
            raise base.SmokeFailure("cancelled M3a camera recording returned an artifact")
        time.sleep(0.3)
        if file_set(cancel_prefix) != before:
            raise base.SmokeFailure("cancelled M3a camera recording left a partial file")

        return {
            "appProcessID": app_status.get("processID"),
            "toolCount": len(tools),
            "camera": camera,
            "cameraDiscovery": cameras,
            "negativeChecks": {
                "invalidDevice": invalid_device,
                "disabledDevice": disabled_device,
                "invalidLayout": invalid_layout,
                "invalidRuntimeUpdate": invalid_runtime_update,
            },
            "liveCamera": live_camera,
            "runtimeUpdates": {
                "hidden": hidden_status.get("camera"),
                "visible": visible_status.get("camera"),
            },
            "cameraOnly": camera_summary,
            "visualInspection": visual_inspection,
            "cameraAndSystemAudio": audio_camera_summary,
            "cameraAndSystemAudioRegion": audio_camera_region,
            "cancel": {
                "sessionID": cancel_session,
                "phase": cancelled.get("phase"),
                "partialFilesRemoved": True,
            },
        }
    finally:
        if tone_process is not None and tone_process.poll() is None:
            tone_process.terminate()
            try:
                tone_process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                tone_process.kill()
        for index, session_id in enumerate(active_sessions, start=900):
            try:
                base.call_tool(
                    process,
                    index,
                    "mupaw_recording_cancel",
                    {"session_id": session_id},
                    timeout=30,
                )
            except Exception:
                pass
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=2)
        TONE_PATH.unlink(missing_ok=True)
        m1e.stop_recording_fixture()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--executable", type=Path, required=True)
    args = parser.parse_args()
    try:
        print(json.dumps(run(args.executable), indent=2, sort_keys=True, ensure_ascii=False))
        return 0
    except (base.SmokeFailure, OSError, subprocess.SubprocessError) as error:
        print(f"M3a smoke test failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
