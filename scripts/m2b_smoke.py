#!/usr/bin/env python3
"""End-to-end M2b microphone recording smoke test through MCP."""
from __future__ import annotations
import argparse, json, os, subprocess, sys, time
from pathlib import Path
from typing import Any
import m1e_smoke as m1e
import m2a_smoke as m2a
import mcp_smoke as base

TONE_PATH = Path("/tmp/mupaw-m2b-microphone-tone.wav")
MINIMUM_MICROPHONE_RMS = 0.0001
ACOUSTIC_TONE_DURATION_SECONDS = 8.0
MICROPHONE_WARMUP_SECONDS = 0.75

def file_set(prefix: str) -> set[Path]:
    return {p.resolve() for p in m1e.RECORDINGS_ROOT.glob(f"{prefix}*.mp4")}


def current_output_volume() -> tuple[int | None, bool | None]:
    volume_result = subprocess.run(
        ["osascript", "-e", "output volume of (get volume settings)"],
        check=False,
        capture_output=True,
        text=True,
        timeout=10,
    )
    mute_result = subprocess.run(
        ["osascript", "-e", "output muted of (get volume settings)"],
        check=False,
        capture_output=True,
        text=True,
        timeout=10,
    )
    try:
        volume = int(volume_result.stdout.strip()) if volume_result.returncode == 0 else None
    except ValueError:
        volume = None
    if mute_result.returncode != 0:
        muted = None
    else:
        muted = mute_result.stdout.strip().lower() == "true"
    return volume, muted


def set_output_volume(volume: int, muted: bool) -> None:
    mute_clause = "with output muted" if muted else "without output muted"
    subprocess.run(
        ["osascript", "-e", f"set volume output volume {max(0, min(100, volume))} {mute_clause}"],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=10,
    )

def run(executable: Path) -> dict[str, Any]:
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise base.SmokeFailure(f"MCP executable is missing or not executable: {executable}")
    m2a.generate_two_tone(
        TONE_PATH,
        duration_seconds=ACOUSTIC_TONE_DURATION_SECONDS,
    )
    m1e.prepare_recording_fixture()
    process = subprocess.Popen([str(executable)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
    active_sessions: set[str] = set()
    tone_process: subprocess.Popen[bytes] | None = None
    original_volume, original_muted = current_output_volume()
    try:
        tools = m1e.initialize(process)
        names = {i.get("name") for i in tools if isinstance(i, dict)}
        if "mupaw_microphones_list" not in names:
            raise base.SmokeFailure("M2b tools/list omitted mupaw_microphones_list")
        start_tool = next((i for i in tools if isinstance(i, dict) and i.get("name") == "mupaw_recording_start"), None)
        schema = start_tool.get("inputSchema") if isinstance(start_tool, dict) else None
        props = schema.get("properties") if isinstance(schema, dict) else None
        required = {"audio_source", "include_system_audio", "include_microphone", "microphone_device_id"}
        if not isinstance(props, dict) or not required.issubset(props):
            raise base.SmokeFailure("M2b recording schema omitted microphone fields")

        microphones = base.parse_json_result(base.call_tool(process, 3, "mupaw_microphones_list"), "mupaw_microphones_list")
        if microphones.get("permission") != "authorized":
            raise base.SmokeFailure("M2b microphone smoke requires microphone permission for the signed Mupaw app")
        devices = microphones.get("devices")
        if not isinstance(devices, list) or not devices:
            raise base.SmokeFailure("M2b microphone smoke found no input devices")
        default_id = microphones.get("defaultDeviceID")
        device = next((i for i in devices if isinstance(i, dict) and i.get("id") == default_id and i.get("isConnected") is True), None)
        if device is None:
            device = next((i for i in devices if isinstance(i, dict) and i.get("isConnected") is True), None)
        if not isinstance(device, dict) or not isinstance(device.get("id"), str):
            raise base.SmokeFailure("M2b found no connected microphone")
        device_id = device["id"]

        app_status, sources = m1e.app_and_sources(process, 10)
        window = m1e.select_mupaw_window_with_retry(process, sources, 100)
        window_id = window.get("id")
        if not isinstance(window_id, str):
            raise base.SmokeFailure("recording fixture omitted its window source ID")

        mixing_prefix = "Mupaw-M2b-Mixing-Rejected"
        before = file_set(mixing_prefix)
        mixing_error = base.expect_tool_error(
            base.call_tool(process, 20, "mupaw_recording_start", {
                "mode": "window", "source_id": window_id,
                "include_system_audio": True, "include_microphone": True,
                "file_name": mixing_prefix,
            }), "mupaw_recording_start", "audio_mixing_not_supported")
        if file_set(mixing_prefix) != before:
            raise base.SmokeFailure("rejected mixing request created an MP4")

        invalid_prefix = "Mupaw-M2b-Invalid-Microphone"
        before = file_set(invalid_prefix)
        invalid_error = base.expect_tool_error(
            base.call_tool(process, 21, "mupaw_recording_start", {
                "mode": "window", "source_id": window_id,
                "audio_source": "microphone", "microphone_device_id": "mupaw-missing-microphone",
                "file_name": invalid_prefix,
            }, timeout=60), "mupaw_recording_start", "microphone_device_not_found")
        if file_set(invalid_prefix) != before:
            raise base.SmokeFailure("invalid microphone request created an MP4")

        started = m1e.start_recording(
            process, 30, mode="window", source_id=window_id, frame_rate=30,
            quality="standard", file_name="Mupaw-M2b-Microphone-Smoke",
            audio_source="microphone", microphone_device_id=device_id)
        session_id = started["id"]
        active_sessions.add(session_id)
        time.sleep(MICROPHONE_WARMUP_SECONDS)
        set_output_volume(100, muted=False)
        tone_process = subprocess.Popen(
            ["/usr/bin/afplay", str(TONE_PATH)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        active: dict[str, Any] | None = None
        request_id = 31
        while tone_process.poll() is None:
            time.sleep(0.5)
            active = m1e.poll_status(process, request_id, session_id)
            request_id += 1
            if active.get("phase") not in {"starting", "recording", "stopping"}:
                raise base.SmokeFailure(
                    "microphone recording became terminal before stop: "
                    + json.dumps(active, ensure_ascii=False, sort_keys=True)
                )
            m1e.validate_active_status(
                active,
                expected_frame_rate=30,
                expected_audio_source="microphone",
                expected_device_id=device_id,
            )
        tone_process.wait(timeout=10)
        tone_process = None
        time.sleep(0.5)
        result = base.call_tool(
            process,
            request_id,
            "mupaw_recording_stop",
            {"session_id": session_id},
            timeout=120,
        )
        microphone = m1e.validate_completed(
            result, expected_session_id=session_id, expected_source_kind="window",
            expected_frame_rate=30, minimum_duration=4.0,
            expected_audio_source="microphone", expected_device_id=device_id,
            minimum_audio_rms=MINIMUM_MICROPHONE_RMS)
        active_sessions.discard(session_id)
        if microphone.get("audio", {}).get("deviceName") != device.get("name"):
            raise base.SmokeFailure("completed microphone device name mismatch")
        microphone["testSignal"] = "acoustic capture of a locally played 48 kHz stereo 440/880 Hz tone"

        cancel_prefix = "Mupaw-M2b-Microphone-Cancel"
        before = file_set(cancel_prefix)
        cancel_start = m1e.start_recording(
            process, 40, mode="window", source_id=window_id, frame_rate=15,
            quality="standard", file_name=cancel_prefix,
            audio_source="microphone", microphone_device_id=device_id)
        cancel_session = cancel_start["id"]
        active_sessions.add(cancel_session)
        time.sleep(0.8)
        cancelled = base.parse_json_result(base.call_tool(process, 41, "mupaw_recording_cancel", {"session_id": cancel_session}, timeout=60), "mupaw_recording_cancel")
        active_sessions.discard(cancel_session)
        if cancelled.get("phase") != "cancelled" or cancelled.get("artifact") is not None:
            raise base.SmokeFailure("cancelled microphone recording returned an artifact")
        time.sleep(0.2)
        if file_set(cancel_prefix) != before:
            raise base.SmokeFailure("cancelled microphone recording left a partial MP4")

        return {
            "appProcessID": app_status.get("processID"), "toolCount": len(tools),
            "microphones": microphones,
            "negativeChecks": {"mixing": mixing_error, "invalidDevice": invalid_error},
            "microphone": microphone,
            "cancel": {"sessionID": cancel_session, "phase": cancelled.get("phase"), "partialFilesRemoved": True},
        }
    finally:
        if tone_process is not None and tone_process.poll() is None:
            tone_process.terminate()
            try: tone_process.wait(timeout=2)
            except subprocess.TimeoutExpired: tone_process.kill()
        for index, session_id in enumerate(active_sessions, start=90):
            try: base.call_tool(process, index, "mupaw_recording_cancel", {"session_id": session_id}, timeout=30)
            except Exception: pass
        process.terminate()
        try: process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill(); process.wait(timeout=2)
        if original_volume is not None:
            set_output_volume(
                original_volume,
                muted=original_muted if original_muted is not None else False,
            )
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
        print(f"M2b smoke test failed: {error}", file=sys.stderr)
        return 1

if __name__ == "__main__":
    raise SystemExit(main())
