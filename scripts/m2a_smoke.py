#!/usr/bin/env python3
"""End-to-end M2a optional system-audio recording smoke test through MCP."""

from __future__ import annotations

import argparse
import json
import math
import os
import struct
import subprocess
import sys
import time
import wave
from pathlib import Path
from typing import Any

import m1e_smoke as m1e
import mcp_smoke as base

TONE_PATH = Path("/tmp/mupaw-m2a-system-audio-tone.wav")


def generate_two_tone(path: Path, duration_seconds: float = 4.0) -> None:
    sample_rate = 48_000
    channels = 2
    amplitude = 0.16
    frame_count = int(sample_rate * duration_seconds)
    midpoint = frame_count // 2
    with wave.open(str(path), "wb") as output:
        output.setnchannels(channels)
        output.setsampwidth(2)
        output.setframerate(sample_rate)
        frames = bytearray()
        for index in range(frame_count):
            frequency = 440.0 if index < midpoint else 880.0
            fade = min(1.0, index / 1_200, (frame_count - index) / 1_200)
            value = int(
                math.sin(2 * math.pi * frequency * index / sample_rate)
                * amplitude
                * fade
                * 32767
            )
            packed = struct.pack("<h", value)
            frames.extend(packed)
            frames.extend(packed)
        output.writeframes(frames)
    os.chmod(path, 0o600)


def find_display(sources: list[Any]) -> dict[str, Any]:
    primary = next(
        (
            item
            for item in sources
            if isinstance(item, dict)
            and item.get("kind") == "display"
            and item.get("isPrimaryDisplay") is True
        ),
        None,
    )
    if isinstance(primary, dict):
        return primary
    display = next(
        (item for item in sources if isinstance(item, dict) and item.get("kind") == "display"),
        None,
    )
    if not isinstance(display, dict):
        raise base.SmokeFailure("No display source is available for M2a system-audio capture")
    return display


def run(executable: Path) -> dict[str, Any]:
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise base.SmokeFailure(f"MCP executable is missing or not executable: {executable}")

    generate_two_tone(TONE_PATH)
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
        if not isinstance(properties, dict) or "include_system_audio" not in properties:
            raise base.SmokeFailure("M2a recording schema omitted include_system_audio")

        app_status, sources = m1e.app_and_sources(process, 10)
        window = m1e.select_mupaw_window_with_retry(process, sources, 100)
        window_id = window.get("id")
        if not isinstance(window_id, str):
            raise base.SmokeFailure("Mupaw window source omitted its identifier")

        # Backward compatibility: the M1e path still produces exactly one video track and no audio.
        silent_start = m1e.start_recording(
            process,
            20,
            mode="window",
            source_id=window_id,
            frame_rate=15,
            quality="standard",
            file_name="Mupaw-M2a-Video-Only-Smoke",
            include_system_audio=False,
        )
        silent_session = silent_start["id"]
        active_sessions.add(silent_session)
        time.sleep(1.2)
        silent_result = base.call_tool(
            process,
            21,
            "mupaw_recording_stop",
            {"session_id": silent_session},
            timeout=90,
        )
        silent_summary = m1e.validate_completed(
            silent_result,
            expected_session_id=silent_session,
            expected_source_kind="window",
            expected_frame_rate=15,
            minimum_duration=0.8,
            expected_system_audio=False,
        )
        active_sessions.discard(silent_session)

        # Use a structured region (display filter) so the test records only a safe Mupaw area
        # while ScreenCaptureKit receives the system-wide two-tone source from afplay.
        region = m1e.window_region(window)
        audio_start = m1e.start_recording(
            process,
            30,
            mode="region",
            region=region,
            frame_rate=30,
            quality="standard",
            file_name="Mupaw-M2a-System-Audio-Smoke",
            include_system_audio=True,
        )
        audio_session = audio_start["id"]
        active_sessions.add(audio_session)

        tone_process = subprocess.Popen(
            ["/usr/bin/afplay", str(TONE_PATH)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        time.sleep(1.0)
        active = m1e.poll_status(process, 31, audio_session)
        m1e.validate_active_status(
            active,
            expected_frame_rate=30,
            expected_system_audio=True,
        )
        if active.get("audio", {}).get("sampleBufferCount", 0) <= 0:
            raise base.SmokeFailure("active M2a recording received no system-audio samples")

        tone_process.wait(timeout=10)
        tone_process = None
        time.sleep(0.35)
        audio_result = base.call_tool(
            process,
            32,
            "mupaw_recording_stop",
            {"session_id": audio_session},
            timeout=120,
        )
        audio_summary = m1e.validate_completed(
            audio_result,
            expected_session_id=audio_session,
            expected_source_kind="region",
            expected_frame_rate=30,
            minimum_duration=3.5,
            expected_system_audio=True,
            minimum_audio_rms=0.01,
        )
        active_sessions.discard(audio_session)
        audio_summary["requestedRegion"] = region
        audio_summary["testSignal"] = "stereo 440 Hz then 880 Hz, 48 kHz"

        return {
            "appProcessID": app_status.get("processID"),
            "toolCount": len(tools),
            "videoOnly": silent_summary,
            "systemAudio": audio_summary,
        }
    finally:
        if tone_process is not None and tone_process.poll() is None:
            tone_process.terminate()
            try:
                tone_process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                tone_process.kill()
        for index, session_id in enumerate(active_sessions, start=90):
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
        print(json.dumps(run(args.executable), indent=2, sort_keys=True))
        return 0
    except (base.SmokeFailure, OSError, subprocess.SubprocessError) as error:
        print(f"M2a smoke test failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
