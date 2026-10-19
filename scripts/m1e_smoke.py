#!/usr/bin/env python3
"""End-to-end M1e video-only MP4 recording smoke test through MCP."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import plistlib
import shutil
import stat
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any
from urllib.parse import unquote, urlparse

import mcp_smoke as base

ROOT = Path(__file__).resolve().parents[1]
INSPECTOR_SOURCE = ROOT / "scripts" / "inspect_mp4.swift"
FIXTURE_SOURCE = ROOT / "scripts" / "recording_fixture.swift"
FIXTURE_APP = Path("/tmp/MupawRecordingFixture.app")
FIXTURE_BINARY = FIXTURE_APP / "Contents" / "MacOS" / "MupawRecordingFixture"
FIXTURE_BUNDLE_ID = "com.xiaodou.mupaw.recording-fixture"
RECORDING_TOOLS = {
    "mupaw_recording_start",
    "mupaw_recording_status",
    "mupaw_recording_stop",
    "mupaw_recording_cancel",
}
RECORDINGS_ROOT = (
    Path.home() / "Library" / "Application Support" / "Mupaw" / "Recordings"
).resolve()


def initialize(process: subprocess.Popen[bytes]) -> list[dict[str, Any]]:
    base.write_message(
        process,
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": base.PROTOCOL_VERSION,
                "capabilities": {},
                "clientInfo": {"name": "mupaw-m1e-smoke", "version": "1"},
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
    missing = RECORDING_TOOLS - names
    if missing:
        raise base.SmokeFailure(f"M1e tools/list omitted: {sorted(missing)}")

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
    required = {
        "mode",
        "source_id",
        "region",
        "format",
        "frame_rate",
        "quality",
        "include_cursor",
        "include_system_audio",
        "exclude_mupaw_ui",
        "file_name",
    }
    if not isinstance(properties, dict) or not required.issubset(properties):
        raise base.SmokeFailure("mupaw_recording_start schema is incomplete")
    return [item for item in tools if isinstance(item, dict)]


def app_and_sources(
    process: subprocess.Popen[bytes], request_id: int
) -> tuple[dict[str, Any], list[Any]]:
    status = base.parse_status(base.call_tool(process, request_id, "mupaw_app_status"))
    permissions = status.get("permissions")
    if status.get("running") is not True:
        raise base.SmokeFailure("Mupaw.app is not running")
    if not isinstance(permissions, dict) or permissions.get("screenCapture") != "authorized":
        raise base.SmokeFailure("Screen capture permission is not authorized")

    payload = base.parse_json_result(
        base.call_tool(process, request_id + 1, "mupaw_sources_list"),
        "mupaw_sources_list",
    )
    sources = payload.get("sources")
    if not isinstance(sources, list):
        raise base.SmokeFailure("mupaw_sources_list omitted sources")
    return status, sources


def prepare_recording_fixture() -> None:
    stop_recording_fixture()
    should_build = not FIXTURE_BINARY.is_file()
    if not should_build:
        should_build = FIXTURE_BINARY.stat().st_mtime < FIXTURE_SOURCE.stat().st_mtime
    if should_build:
        shutil.rmtree(FIXTURE_APP, ignore_errors=True)
        FIXTURE_BINARY.parent.mkdir(parents=True, exist_ok=True)
        compile_result = subprocess.run(
            [
                "xcrun",
                "swiftc",
                "-parse-as-library",
                str(FIXTURE_SOURCE),
                "-o",
                str(FIXTURE_BINARY),
                "-framework",
                "AppKit",
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=120,
        )
        if compile_result.returncode != 0:
            raise base.SmokeFailure(
                "Could not compile the safe recording fixture: "
                + (compile_result.stderr.strip() or compile_result.stdout.strip())
            )
        info = {
            "CFBundleExecutable": "MupawRecordingFixture",
            "CFBundleIdentifier": FIXTURE_BUNDLE_ID,
            "CFBundleName": "Mupaw Recording Fixture",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "LSUIElement": False,
            "NSHighResolutionCapable": True,
        }
        with (FIXTURE_APP / "Contents" / "Info.plist").open("wb") as handle:
            plistlib.dump(info, handle)
        sign_result = subprocess.run(
            ["codesign", "--force", "--sign", "-", "--timestamp=none", str(FIXTURE_APP)],
            check=False,
            capture_output=True,
            text=True,
            timeout=30,
        )
        if sign_result.returncode != 0:
            raise base.SmokeFailure(
                "Could not sign the safe recording fixture: "
                + (sign_result.stderr.strip() or sign_result.stdout.strip())
            )
    launch_result = subprocess.run(
        ["open", "-n", str(FIXTURE_APP)],
        check=False,
        capture_output=True,
        text=True,
        timeout=15,
    )
    if launch_result.returncode != 0:
        raise base.SmokeFailure(
            "Could not launch the safe recording fixture: "
            + (launch_result.stderr.strip() or launch_result.stdout.strip())
        )
    activate_recording_fixture()


def activate_recording_fixture() -> None:
    subprocess.run(
        [
            "osascript",
            "-e",
            f'tell application id "{FIXTURE_BUNDLE_ID}" to activate',
        ],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=10,
    )
    time.sleep(0.5)


def stop_recording_fixture() -> None:
    subprocess.run(
        ["osascript", "-e", f'tell application id "{FIXTURE_BUNDLE_ID}" to quit'],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=10,
    )
    subprocess.run(
        ["pkill", "-f", str(FIXTURE_BINARY)],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=10,
    )


def fixture_window(sources: list[Any]) -> dict[str, Any] | None:
    candidates = [
        item
        for item in sources
        if isinstance(item, dict)
        and item.get("kind") == "window"
        and item.get("applicationBundleIdentifier") == FIXTURE_BUNDLE_ID
        and int(item.get("pixelWidth", 0)) >= 800
        and int(item.get("pixelHeight", 0)) >= 500
    ]
    if not candidates:
        return None
    return max(
        candidates,
        key=lambda item: int(item.get("pixelWidth", 0))
        * int(item.get("pixelHeight", 0)),
    )


def select_mupaw_window_with_retry(
    process: subprocess.Popen[bytes], sources: list[Any], request_id: int
) -> dict[str, Any]:
    source = fixture_window(sources)
    if source is not None:
        return source

    last_sources: list[Any] = sources
    activate_recording_fixture()
    for attempt in range(24):
        if attempt > 0 and attempt % 8 == 0:
            activate_recording_fixture()
        time.sleep(0.25)
        payload = base.parse_json_result(
            base.call_tool(process, request_id + attempt, "mupaw_sources_list"),
            "mupaw_sources_list",
        )
        refreshed = payload.get("sources")
        if not isinstance(refreshed, list):
            raise base.SmokeFailure("refreshed sources payload is invalid")
        last_sources = refreshed
        source = fixture_window(refreshed)
        if source is not None:
            return source

    visible_windows = [
        item
        for item in last_sources
        if isinstance(item, dict) and item.get("kind") == "window"
    ]
    raise base.SmokeFailure(
        "No visible safe recording fixture was available after a bounded retry "
        f"({len(visible_windows)} other windows were visible)"
    )


def start_recording(
    process: subprocess.Popen[bytes],
    request_id: int,
    *,
    mode: str,
    source_id: str | None = None,
    region: dict[str, float | str] | None = None,
    frame_rate: int,
    quality: str,
    file_name: str,
    include_system_audio: bool = False,
    audio_source: str | None = None,
    include_microphone: bool = False,
    microphone_device_id: str | None = None,
    system_audio_gain: float = 1.0,
    microphone_gain: float = 1.0,
    system_audio_muted: bool = False,
    microphone_muted: bool = False,
    camera_overlay: dict[str, Any] | None = None,
) -> dict[str, Any]:
    arguments: dict[str, Any] = {
        "mode": mode,
        "format": "mp4",
        "frame_rate": frame_rate,
        "quality": quality,
        "include_cursor": False,
        "include_system_audio": include_system_audio,
        "include_microphone": include_microphone,
        "system_audio_gain": system_audio_gain,
        "microphone_gain": microphone_gain,
        "system_audio_muted": system_audio_muted,
        "microphone_muted": microphone_muted,
        "exclude_mupaw_ui": mode != "window",
        "file_name": file_name,
    }
    if source_id is not None:
        arguments["source_id"] = source_id
    if audio_source is not None:
        arguments["audio_source"] = audio_source
    if microphone_device_id is not None:
        arguments["microphone_device_id"] = microphone_device_id
    if camera_overlay is not None:
        arguments["camera_overlay"] = camera_overlay
    if region is not None:
        arguments["region"] = region
    result = base.parse_json_result(
        base.call_tool(
            process,
            request_id,
            "mupaw_recording_start",
            arguments,
            timeout=60,
        ),
        "mupaw_recording_start",
    )
    validate_active_status(
        result,
        expected_frame_rate=frame_rate,
        expected_system_audio=include_system_audio,
        expected_audio_source=audio_source,
        expected_device_id=microphone_device_id,
    )
    return result


def validate_active_status(
    status: dict[str, Any],
    *,
    expected_frame_rate: int,
    expected_system_audio: bool = False,
    expected_audio_source: str | None = None,
    expected_device_id: str | None = None,
) -> None:
    session_id = status.get("id")
    if not isinstance(session_id, str):
        raise base.SmokeFailure("recording status omitted session id")
    try:
        uuid.UUID(session_id)
    except ValueError as error:
        raise base.SmokeFailure("recording session id is not a UUID") from error
    if status.get("phase") not in {"starting", "recording", "stopping"}:
        raise base.SmokeFailure(f"recording start returned terminal phase: {status.get('phase')!r}")
    if status.get("format") != "mp4" or status.get("codec") != "h264":
        raise base.SmokeFailure("recording status omitted MP4/H.264 identity")
    if status.get("frameRate") != expected_frame_rate:
        raise base.SmokeFailure("recording status frame rate mismatch")
    width = status.get("pixelWidth")
    height = status.get("pixelHeight")
    if not isinstance(width, int) or not isinstance(height, int) or width <= 0 or height <= 0:
        raise base.SmokeFailure("recording status returned invalid dimensions")
    if width % 2 or height % 2:
        raise base.SmokeFailure("recording status dimensions are not even")
    if width > 3840 or height > 3840 or width * height > 3840 * 2160:
        raise base.SmokeFailure("recording status exceeded M1e resolution bounds")
    audio = status.get("audio")
    if not isinstance(audio, dict):
        raise base.SmokeFailure("recording status omitted audio state")
    resolved_audio_source = expected_audio_source or (
        "system_audio" if expected_system_audio else "none"
    )
    if resolved_audio_source != "none":
        if audio.get("requested") is not True or audio.get("state") not in {
            "waiting",
            "capturing",
        }:
            raise base.SmokeFailure("recording status did not expose requested audio")
        if audio.get("codec") != "aac" or audio.get("source") != resolved_audio_source:
            raise base.SmokeFailure("recording status omitted AAC audio-source identity")
        if expected_device_id is not None and audio.get("deviceID") != expected_device_id:
            raise base.SmokeFailure("recording status microphone device mismatch")
    else:
        if audio.get("requested") is not False or audio.get("state") != "disabled":
            raise base.SmokeFailure("video-only recording unexpectedly enabled audio")
        if audio.get("source") not in {None, "none"}:
            raise base.SmokeFailure("video-only recording returned an audio source")


def poll_status(
    process: subprocess.Popen[bytes], request_id: int, session_id: str
) -> dict[str, Any]:
    return base.parse_json_result(
        base.call_tool(
            process,
            request_id,
            "mupaw_recording_status",
            {"session_id": session_id},
            timeout=60,
        ),
        "mupaw_recording_status",
    )


def compile_inspector() -> Path:
    binary = Path("/tmp/mupaw-m1e-inspect-mp4")
    if (
        binary.is_file()
        and os.access(binary, os.X_OK)
        and binary.stat().st_mtime >= INSPECTOR_SOURCE.stat().st_mtime
    ):
        return binary
    result = subprocess.run(
        [
            "xcrun",
            "swiftc",
            "-parse-as-library",
            str(INSPECTOR_SOURCE),
            "-o",
            str(binary),
            "-framework",
            "AVFoundation",
            "-framework",
            "CoreMedia",
            "-framework",
            "AudioToolbox",
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raise base.SmokeFailure(
            "Could not compile the MP4 inspector: "
            + (result.stderr.strip() or result.stdout.strip())
        )
    return binary


def inspect_mp4(path: Path) -> dict[str, Any]:
    result = subprocess.run(
        [str(compile_inspector()), str(path)],
        check=False,
        capture_output=True,
        text=True,
        timeout=60,
    )
    if result.returncode != 0:
        raise base.SmokeFailure(
            "MP4 inspector failed: " + (result.stderr.strip() or result.stdout.strip())
        )
    try:
        payload = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise base.SmokeFailure("MP4 inspector returned invalid JSON") from error
    if not isinstance(payload, dict):
        raise base.SmokeFailure("MP4 inspector did not return an object")
    return payload


def validate_completed(
    tool_result: dict[str, Any],
    *,
    expected_session_id: str,
    expected_source_kind: str,
    expected_frame_rate: int,
    minimum_duration: float,
    expected_system_audio: bool = False,
    expected_audio_source: str | None = None,
    expected_device_id: str | None = None,
    minimum_audio_rms: float | None = None,
) -> dict[str, Any]:
    tool_name = "mupaw_recording_stop"
    status = base.parse_json_result(tool_result, tool_name)
    if status.get("id") != expected_session_id or status.get("phase") != "completed":
        raise base.SmokeFailure("recording stop did not return the completed session")
    artifact = status.get("artifact")
    if not isinstance(artifact, dict):
        raise base.SmokeFailure("completed recording omitted artifact metadata")
    if artifact.get("sessionID") != expected_session_id:
        raise base.SmokeFailure("recording artifact sessionID mismatch")
    if artifact.get("format") != "mp4" or artifact.get("codec") != "h264":
        raise base.SmokeFailure("recording artifact omitted MP4/H.264 identity")
    audio = artifact.get("audio")
    if not isinstance(audio, dict):
        raise base.SmokeFailure("recording artifact omitted audio metadata")
    source = artifact.get("source")
    if not isinstance(source, dict) or source.get("kind") != expected_source_kind:
        raise base.SmokeFailure("recording artifact source kind mismatch")

    preview = artifact.get("preview")
    image = base.image_content(tool_result, tool_name)
    if not isinstance(preview, dict):
        raise base.SmokeFailure("recording artifact omitted preview")
    if image.get("data") != preview.get("base64Data") or image.get("mimeType") != preview.get(
        "mimeType"
    ):
        raise base.SmokeFailure("MCP recording image block does not match preview metadata")

    file_url = artifact.get("fileURL")
    expected_hash = artifact.get("sha256")
    byte_count = artifact.get("byteCount")
    width = artifact.get("pixelWidth")
    height = artifact.get("pixelHeight")
    duration = artifact.get("durationSeconds")
    frame_count = artifact.get("frameCount")
    average_frame_rate = artifact.get("averageFrameRate")
    requested_frame_rate = artifact.get("requestedFrameRate")
    if not isinstance(file_url, str):
        raise base.SmokeFailure("recording artifact omitted fileURL")
    if not isinstance(expected_hash, str) or len(expected_hash) != 64:
        raise base.SmokeFailure("recording artifact omitted SHA-256")
    if not isinstance(byte_count, int) or byte_count <= 0:
        raise base.SmokeFailure("recording artifact byteCount is invalid")
    if not isinstance(width, int) or not isinstance(height, int) or width <= 0 or height <= 0:
        raise base.SmokeFailure("recording artifact dimensions are invalid")
    if width % 2 or height % 2 or width > 3840 or height > 3840 or width * height > 3840 * 2160:
        raise base.SmokeFailure("recording artifact dimensions exceed M1e bounds")
    if not isinstance(duration, (int, float)) or duration < minimum_duration:
        raise base.SmokeFailure("recording artifact duration is too short")
    if not isinstance(frame_count, int) or frame_count <= 0:
        raise base.SmokeFailure("recording artifact frameCount is invalid")
    if (
        not isinstance(average_frame_rate, (int, float))
        or not math.isfinite(float(average_frame_rate))
        or average_frame_rate <= 0
    ):
        raise base.SmokeFailure("recording artifact averageFrameRate is invalid")
    if average_frame_rate > expected_frame_rate * 1.5:
        raise base.SmokeFailure("recording artifact averageFrameRate exceeds its request")
    if requested_frame_rate != expected_frame_rate:
        raise base.SmokeFailure("recording artifact requestedFrameRate mismatch")

    parsed = urlparse(file_url)
    if parsed.scheme != "file":
        raise base.SmokeFailure("recording artifact returned a non-file URL")
    path = Path(unquote(parsed.path)).resolve()
    try:
        path.relative_to(RECORDINGS_ROOT)
    except ValueError as error:
        raise base.SmokeFailure(f"recording escaped the Recordings directory: {path}") from error
    if not path.is_file():
        raise base.SmokeFailure(f"recording file does not exist: {path}")
    if stat.S_IMODE(path.stat().st_mode) != 0o600:
        raise base.SmokeFailure("recording permissions are not owner read/write only")
    data = path.read_bytes()
    if len(data) != byte_count:
        raise base.SmokeFailure("recording file byte count mismatch")
    if hashlib.sha256(data).hexdigest() != expected_hash:
        raise base.SmokeFailure("recording file SHA-256 mismatch")
    if len(data) < 12 or b"ftyp" not in data[:32]:
        raise base.SmokeFailure("recording file is not an ISO MP4 container")

    inspection = inspect_mp4(path)
    if inspection.get("isPlayable") is not True:
        raise base.SmokeFailure("AVFoundation did not mark the MP4 playable")
    if inspection.get("videoTrackCount") != 1:
        raise base.SmokeFailure("recording MP4 must contain exactly one video track")
    resolved_audio_source = expected_audio_source or (
        "system_audio" if expected_system_audio else "none"
    )
    if resolved_audio_source != "none":
        if inspection.get("audioTrackCount") != 1:
            raise base.SmokeFailure("MP4 must contain one requested AAC audio track")
        if audio.get("requested") is not True or audio.get("state") != "completed":
            raise base.SmokeFailure("recording artifact did not complete requested audio")
        if audio.get("codec") != "aac" or audio.get("trackCount") != 1:
            raise base.SmokeFailure("recording artifact AAC track metadata is invalid")
        if audio.get("source") != resolved_audio_source:
            raise base.SmokeFailure("recording artifact audio source mismatch")
        if audio.get("sampleRate") != 48000:
            raise base.SmokeFailure("recording artifact audio sample rate is invalid")
        channel_count = audio.get("channelCount")
        if resolved_audio_source in {"system_audio", "system_audio_and_microphone"} and channel_count != 2:
            raise base.SmokeFailure("recording artifact system-audio channel count is invalid")
        if resolved_audio_source == "microphone" and channel_count not in {1, 2}:
            raise base.SmokeFailure("recording artifact microphone channel count is invalid")
        if expected_device_id is not None and audio.get("deviceID") != expected_device_id:
            raise base.SmokeFailure("recording artifact microphone device mismatch")
        audio_duration = audio.get("durationSeconds")
        difference = audio.get("audioVideoDurationDifferenceSeconds")
        if not isinstance(audio_duration, (int, float)) or audio_duration <= 0:
            raise base.SmokeFailure("recording artifact audio duration is invalid")
        if not isinstance(difference, (int, float)) or difference > 0.25:
            raise base.SmokeFailure("recording artifact audio/video duration difference is too large")
        audio_codec = str(inspection.get("audioCodecFourCC", "")).strip().lower()
        if not audio_codec.startswith("aac"):
            raise base.SmokeFailure(f"MP4 audio track is not AAC: {audio_codec!r}")
        if inspection.get("audioSampleRate") != 48000:
            raise base.SmokeFailure("inspected AAC sample rate does not match metadata")
        if inspection.get("audioChannelCount") != channel_count:
            raise base.SmokeFailure("inspected AAC channel count does not match metadata")
        inspected_audio_duration = inspection.get("audioDurationSeconds")
        if (
            not isinstance(inspected_audio_duration, (int, float))
            or abs(inspected_audio_duration - audio_duration) > 0.05
        ):
            raise base.SmokeFailure("inspected audio duration does not match artifact metadata")
        if minimum_audio_rms is not None:
            rms = inspection.get("audioRMS")
            peak = inspection.get("audioPeak")
            sample_count = inspection.get("decodedAudioSampleCount")
            if not isinstance(rms, (int, float)) or rms < minimum_audio_rms:
                raise base.SmokeFailure("captured audio is silent or below the RMS threshold")
            if not isinstance(peak, (int, float)) or peak <= minimum_audio_rms:
                raise base.SmokeFailure("captured audio peak is invalid")
            if not isinstance(sample_count, int) or sample_count <= 0:
                raise base.SmokeFailure("MP4 inspector decoded no audio samples")
    else:
        if inspection.get("audioTrackCount") != 0:
            raise base.SmokeFailure("video-only MP4 unexpectedly contains audio")
        if audio.get("requested") is not False or audio.get("state") != "disabled":
            raise base.SmokeFailure("video-only artifact unexpectedly reports audio")
        if audio.get("source") not in {None, "none"}:
            raise base.SmokeFailure("video-only artifact returned an audio source")
    if inspection.get("pixelWidth") != width or inspection.get("pixelHeight") != height:
        raise base.SmokeFailure("MP4 track dimensions do not match artifact metadata")
    inspected_duration = inspection.get("durationSeconds")
    if not isinstance(inspected_duration, (int, float)) or abs(inspected_duration - duration) > 0.05:
        raise base.SmokeFailure("MP4 track duration does not match artifact metadata")
    codec = str(inspection.get("codecFourCC", "")).lower()
    if codec not in {"avc1", "avc3"}:
        raise base.SmokeFailure(f"MP4 track is not H.264: {codec!r}")

    return {
        "sessionID": expected_session_id,
        "sourceKind": expected_source_kind,
        "file": str(path),
        "pixelWidth": width,
        "pixelHeight": height,
        "durationSeconds": duration,
        "frameCount": frame_count,
        "averageFrameRate": average_frame_rate,
        "byteCount": byte_count,
        "sha256": expected_hash,
        "inspection": inspection,
        "audio": audio,
        "camera": artifact.get("camera"),
    }


def window_region(source: dict[str, Any]) -> dict[str, float | str]:
    frame = source.get("framePoints")
    if not isinstance(frame, dict):
        raise base.SmokeFailure("Mupaw window source omitted framePoints")
    values = {key: frame.get(key) for key in ("x", "y", "width", "height")}
    if not all(isinstance(value, (int, float)) for value in values.values()):
        raise base.SmokeFailure("Mupaw window framePoints are invalid")
    width = float(values["width"])
    height = float(values["height"])
    margin = min(48.0, width / 6, height / 6)
    region_width = min(420.0, width - margin * 2)
    region_height = min(260.0, height - margin * 2)
    if region_width < 40 or region_height < 40:
        raise base.SmokeFailure("Mupaw window is too small for region recording smoke")
    return {
        "coordinate_space": "global_display_points",
        "x": float(values["x"]) + margin,
        "y": float(values["y"]) + margin,
        "width": region_width,
        "height": region_height,
    }


def run(executable: Path, *, include_full_screen: bool = False) -> dict[str, Any]:
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise base.SmokeFailure(f"MCP executable is missing or not executable: {executable}")

    prepare_recording_fixture()
    process = subprocess.Popen(
        [str(executable)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        bufsize=0,
    )
    active_sessions: set[str] = set()
    try:
        tools = initialize(process)
        app_status, sources = app_and_sources(process, 10)
        source = select_mupaw_window_with_retry(process, sources, 100)
        source_id = source.get("id")
        if not isinstance(source_id, str):
            raise base.SmokeFailure("selected Mupaw window omitted source id")

        full_screen_summary: dict[str, Any] | None = None
        if include_full_screen:
            display = next(
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
            if not isinstance(display, dict) or not isinstance(display.get("id"), str):
                raise base.SmokeFailure("No display source was available for full-screen recording")
            full_start = start_recording(
                process,
                14,
                mode="full_screen",
                source_id=display["id"],
                frame_rate=15,
                quality="standard",
                file_name="Mupaw-M1e-Full-Screen-Smoke",
            )
            full_session = full_start["id"]
            active_sessions.add(full_session)
            time.sleep(1.6)
            full_result = base.call_tool(
                process,
                15,
                "mupaw_recording_stop",
                {"session_id": full_session},
                timeout=90,
            )
            full_screen_summary = validate_completed(
                full_result,
                expected_session_id=full_session,
                expected_source_kind="display",
                expected_frame_rate=15,
                minimum_duration=0.8,
            )
            active_sessions.discard(full_session)

        window_start = start_recording(
            process,
            20,
            mode="window",
            source_id=source_id,
            frame_rate=30,
            quality="standard",
            file_name="Mupaw-M1e-Window-Smoke",
        )
        window_session = window_start["id"]
        active_sessions.add(window_session)
        time.sleep(1.2)

        duplicate_start = base.expect_tool_error(
            base.call_tool(
                process,
                21,
                "mupaw_recording_start",
                {
                    "mode": "window",
                    "source_id": source_id,
                    "frame_rate": 30,
                    "quality": "standard",
                },
                timeout=60,
            ),
            "mupaw_recording_start",
            "recording_in_progress",
        )
        screenshot_conflict = base.expect_tool_error(
            base.call_tool(
                process,
                22,
                "mupaw_screenshot_capture",
                {"mode": "window", "source_id": source_id, "format": "png"},
                timeout=60,
            ),
            "mupaw_screenshot_capture",
            "capture_in_progress",
        )
        active = poll_status(process, 23, window_session)
        validate_active_status(active, expected_frame_rate=30, expected_system_audio=False)
        if active.get("elapsedDurationSeconds", 0) <= 0:
            raise base.SmokeFailure("active recording did not report elapsed duration")
        time.sleep(1.2)
        window_result = base.call_tool(
            process,
            24,
            "mupaw_recording_stop",
            {"session_id": window_session},
            timeout=90,
        )
        window_summary = validate_completed(
            window_result,
            expected_session_id=window_session,
            expected_source_kind="window",
            expected_frame_rate=30,
            minimum_duration=1.5,
        )
        active_sessions.discard(window_session)
        repeated_stop = base.parse_json_result(
            base.call_tool(
                process,
                25,
                "mupaw_recording_stop",
                {"session_id": window_session},
                timeout=60,
            ),
            "mupaw_recording_stop",
        )
        if repeated_stop.get("phase") != "completed":
            raise base.SmokeFailure("repeated stop was not idempotent for a completed session")

        region = window_region(source)
        region_start = start_recording(
            process,
            30,
            mode="region",
            region=region,
            frame_rate=15,
            quality="high",
            file_name="Mupaw-M1e-Region-Smoke",
        )
        region_session = region_start["id"]
        active_sessions.add(region_session)
        time.sleep(1.6)
        region_result = base.call_tool(
            process,
            31,
            "mupaw_recording_stop",
            {"session_id": region_session},
            timeout=90,
        )
        region_summary = validate_completed(
            region_result,
            expected_session_id=region_session,
            expected_source_kind="region",
            expected_frame_rate=15,
            minimum_duration=0.8,
        )
        active_sessions.discard(region_session)
        region_summary["requestedRegion"] = region

        before_cancel = set(RECORDINGS_ROOT.glob("Mupaw-M1e-Cancel-Smoke*.mp4"))
        cancel_start = start_recording(
            process,
            40,
            mode="window",
            source_id=source_id,
            frame_rate=15,
            quality="standard",
            file_name="Mupaw-M1e-Cancel-Smoke",
        )
        cancel_session = cancel_start["id"]
        active_sessions.add(cancel_session)
        time.sleep(0.7)
        cancelled = base.parse_json_result(
            base.call_tool(
                process,
                41,
                "mupaw_recording_cancel",
                {"session_id": cancel_session},
                timeout=60,
            ),
            "mupaw_recording_cancel",
        )
        if cancelled.get("phase") != "cancelled" or cancelled.get("artifact") is not None:
            raise base.SmokeFailure("cancelled recording incorrectly claimed a completed artifact")
        active_sessions.discard(cancel_session)
        cancelled_poll = poll_status(process, 42, cancel_session)
        if cancelled_poll.get("phase") != "cancelled":
            raise base.SmokeFailure("cancelled terminal status was not retained")
        after_cancel = set(RECORDINGS_ROOT.glob("Mupaw-M1e-Cancel-Smoke*.mp4"))
        leaked = sorted(str(path) for path in after_cancel - before_cancel)
        if leaked:
            raise base.SmokeFailure(f"cancelled recording left partial files: {leaked}")

        missing_session = base.expect_tool_error(
            base.call_tool(
                process,
                43,
                "mupaw_recording_status",
                {"session_id": str(uuid.uuid4())},
                timeout=60,
            ),
            "mupaw_recording_status",
            "recording_not_found",
        )
        invalid_frame_rate = base.expect_tool_error(
            base.call_tool(
                process,
                44,
                "mupaw_recording_start",
                {
                    "mode": "window",
                    "source_id": source_id,
                    "frame_rate": 24,
                },
                timeout=60,
            ),
            "mupaw_recording_start",
            "frame_rate must be 15, 30, or 60",
        )

        recovered = base.parse_status(base.call_tool(process, 45, "mupaw_app_status"))
        if recovered.get("running") is not True:
            raise base.SmokeFailure("Mupaw.app stopped during M1e smoke")

        return {
            "toolCount": len(tools),
            "recordingTools": sorted(RECORDING_TOOLS),
            "appProcessID": app_status.get("processID"),
            "fullScreen": full_screen_summary,
            "window": window_summary,
            "region": region_summary,
            "cancel": {
                "sessionID": cancel_session,
                "phase": cancelled.get("phase"),
                "partialFilesRemoved": True,
            },
            "conflictChecks": {
                "duplicateRecording": duplicate_start,
                "screenshotDuringRecording": screenshot_conflict,
            },
            "negativeChecks": {
                "missingSession": missing_session,
                "invalidFrameRate": invalid_frame_rate,
            },
        }
    finally:
        if process.poll() is None:
            for index, session_id in enumerate(sorted(active_sessions), start=900):
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
        if process.stdin is not None:
            process.stdin.close()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
        stderr = process.stderr.read().decode("utf-8", errors="replace") if process.stderr else ""
        if process.returncode not in (0, None) and stderr:
            print(stderr, file=sys.stderr)
        stop_recording_fixture()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--executable", required=True, type=Path)
    parser.add_argument(
        "--full-screen",
        action="store_true",
        help="Also record the primary display. Cover it with non-sensitive test content first.",
    )
    args = parser.parse_args()
    try:
        result = run(args.executable.resolve(), include_full_screen=args.full_screen)
    except (base.SmokeFailure, OSError, subprocess.SubprocessError) as error:
        print(f"M1e smoke failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
