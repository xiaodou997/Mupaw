#!/usr/bin/env python3
"""End-to-end M2c mixed-audio, controls, and live-level smoke test through MCP."""

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
import m2b_smoke as m2b
import mcp_smoke as base

TONE_PATH = Path("/tmp/mupaw-m2c-mixed-audio-tone.wav")
TONE_DURATION_SECONDS = 16.0
MINIMUM_SYSTEM_RMS = 0.005
MINIMUM_MICROPHONE_RMS = 0.0001
MINIMUM_FINAL_RMS = 0.0005


def artifacts(prefix: str) -> set[Path]:
    root = m1e.RECORDINGS_ROOT
    return {
        item.resolve()
        for item in root.iterdir()
        if item.is_file() and (item.name.startswith(prefix) or "intermediate" in item.name)
    }


def choose_microphone(payload: dict[str, Any]) -> dict[str, Any]:
    devices = payload.get("devices")
    if not isinstance(devices, list) or not devices:
        raise base.SmokeFailure("M2c found no microphone input devices")
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
        raise base.SmokeFailure("M2c found no connected microphone")
    return selected


def assert_live_lane(
    audio: dict[str, Any],
    key: str,
    *,
    minimum_rms: float,
) -> dict[str, Any]:
    lane = audio.get(key)
    if not isinstance(lane, dict):
        raise base.SmokeFailure(f"live status omitted {key}")
    if lane.get("sampleBufferCount", 0) <= 0:
        raise base.SmokeFailure(f"{key} received no input samples")
    level = lane.get("currentLevel")
    if not isinstance(level, dict):
        raise base.SmokeFailure(f"{key} omitted its live level")
    if level.get("isStale") is not False:
        raise base.SmokeFailure(f"{key} live level is stale")
    rms = level.get("rms")
    peak = level.get("peak")
    if not isinstance(rms, (int, float)) or rms < minimum_rms:
        raise base.SmokeFailure(f"{key} RMS is silent or below threshold: {rms!r}")
    if not isinstance(peak, (int, float)) or peak <= minimum_rms:
        raise base.SmokeFailure(f"{key} peak is silent or below threshold: {peak!r}")
    if not isinstance(lane.get("lastSampleAt"), str):
        raise base.SmokeFailure(f"{key} omitted lastSampleAt")
    if not isinstance(lane.get("lastSourceTimestampSeconds"), (int, float)):
        raise base.SmokeFailure(f"{key} omitted its source timestamp")
    return lane


def update_controls(
    process: subprocess.Popen[bytes],
    request_id: int,
    session_id: str,
    **controls: Any,
) -> dict[str, Any]:
    return base.parse_json_result(
        base.call_tool(
            process,
            request_id,
            "mupaw_recording_update_audio_controls",
            {"session_id": session_id, **controls},
            timeout=60,
        ),
        "mupaw_recording_update_audio_controls",
    )


def run(executable: Path) -> dict[str, Any]:
    if not executable.is_file() or not os.access(executable, os.X_OK):
        raise base.SmokeFailure(f"MCP executable is missing or not executable: {executable}")

    m2a.generate_two_tone(TONE_PATH, duration_seconds=TONE_DURATION_SECONDS)
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
    original_volume, original_muted = m2b.current_output_volume()
    try:
        tools = m1e.initialize(process)
        names = {item.get("name") for item in tools if isinstance(item, dict)}
        if "mupaw_recording_update_audio_controls" not in names:
            raise base.SmokeFailure("M2c tools/list omitted audio-control updates")
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
            "audio_source",
            "system_audio_gain",
            "microphone_gain",
            "system_audio_muted",
            "microphone_muted",
        }
        if not isinstance(properties, dict) or not required.issubset(properties):
            raise base.SmokeFailure("M2c recording schema omitted audio-control fields")

        microphones = base.parse_json_result(
            base.call_tool(process, 3, "mupaw_microphones_list"),
            "mupaw_microphones_list",
        )
        if microphones.get("permission") != "authorized":
            raise base.SmokeFailure(
                "M2c mixed-audio smoke requires microphone permission for the signed app"
            )
        microphone = choose_microphone(microphones)
        microphone_id = microphone["id"]

        app_status, sources = m1e.app_and_sources(process, 10)
        window = m1e.select_mupaw_window_with_retry(process, sources, 100)
        region = m1e.window_region(window)

        invalid_prefix = "Mupaw-M2c-Invalid-Gain"
        before = artifacts(invalid_prefix)
        invalid_gain = base.expect_tool_error(
            base.call_tool(
                process,
                20,
                "mupaw_recording_start",
                {
                    "mode": "region",
                    "region": region,
                    "audio_source": "system_audio_and_microphone",
                    "microphone_device_id": microphone_id,
                    "system_audio_gain": 2.01,
                    "file_name": invalid_prefix,
                },
            ),
            "mupaw_recording_start",
            "invalid_audio_controls",
        )
        if artifacts(invalid_prefix) != before:
            raise base.SmokeFailure("invalid M2c gain created an output file")

        conflict_prefix = "Mupaw-M2c-Conflicting-Flags"
        before = artifacts(conflict_prefix)
        conflicting_source = base.expect_tool_error(
            base.call_tool(
                process,
                21,
                "mupaw_recording_start",
                {
                    "mode": "region",
                    "region": region,
                    "audio_source": "system_audio",
                    "include_microphone": True,
                    "microphone_device_id": microphone_id,
                    "file_name": conflict_prefix,
                },
            ),
            "mupaw_recording_start",
            "audio_mixing_not_supported",
        )
        if artifacts(conflict_prefix) != before:
            raise base.SmokeFailure("conflicting M2c request created an output file")

        mixed_start = m1e.start_recording(
            process,
            30,
            mode="region",
            region=region,
            frame_rate=30,
            quality="standard",
            file_name="Mupaw-M2c-Mixed-Audio-Smoke",
            audio_source="system_audio_and_microphone",
            microphone_device_id=microphone_id,
        )
        mixed_session = mixed_start["id"]
        active_sessions.add(mixed_session)

        empty_update = base.expect_tool_error(
            base.call_tool(
                process,
                31,
                "mupaw_recording_update_audio_controls",
                {"session_id": mixed_session},
            ),
            "mupaw_recording_update_audio_controls",
            "invalid_audio_controls",
        )

        m2b.set_output_volume(100, muted=False)
        tone_process = subprocess.Popen(
            ["/usr/bin/afplay", str(TONE_PATH)],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )

        request_id = 32
        phases_applied: set[str] = set()
        live_snapshots: dict[str, Any] = {}
        while tone_process.poll() is None:
            time.sleep(0.5)
            status = m1e.poll_status(process, request_id, mixed_session)
            request_id += 1
            if status.get("phase") not in {"starting", "recording", "stopping"}:
                raise base.SmokeFailure(
                    "M2c mixed recording became terminal early: "
                    + json.dumps(status, ensure_ascii=False, sort_keys=True)
                )
            m1e.validate_active_status(
                status,
                expected_frame_rate=30,
                expected_audio_source="system_audio_and_microphone",
                expected_device_id=microphone_id,
            )
            elapsed = float(status.get("elapsedDurationSeconds", 0))
            audio = status.get("audio", {})

            if elapsed >= 1.0 and "both" not in live_snapshots:
                system_lane = assert_live_lane(
                    audio,
                    "systemAudioInput",
                    minimum_rms=MINIMUM_SYSTEM_RMS,
                )
                microphone_lane = assert_live_lane(
                    audio,
                    "microphoneInput",
                    minimum_rms=MINIMUM_MICROPHONE_RMS,
                )
                live_snapshots["both"] = {
                    "system": system_lane.get("currentLevel"),
                    "microphone": microphone_lane.get("currentLevel"),
                    "mixed": audio.get("mixedLevel"),
                }

            if elapsed >= 4.0 and "system_only" not in phases_applied:
                updated = update_controls(
                    process,
                    request_id,
                    mixed_session,
                    system_audio_gain=0.1,
                    microphone_muted=True,
                )
                request_id += 1
                controls = updated.get("audio", {}).get("controls", {})
                if controls.get("microphoneMuted") is not True:
                    raise base.SmokeFailure("runtime microphone mute did not apply")
                phases_applied.add("system_only")

            if elapsed >= 8.0 and "microphone_only" not in phases_applied:
                updated = update_controls(
                    process,
                    request_id,
                    mixed_session,
                    system_audio_muted=True,
                    microphone_muted=False,
                    microphone_gain=2.0,
                )
                request_id += 1
                controls = updated.get("audio", {}).get("controls", {})
                if controls.get("systemAudioMuted") is not True:
                    raise base.SmokeFailure("runtime system-audio mute did not apply")
                phases_applied.add("microphone_only")

            if elapsed >= 12.0 and "rebalanced" not in phases_applied:
                updated = update_controls(
                    process,
                    request_id,
                    mixed_session,
                    system_audio_muted=False,
                    microphone_muted=False,
                    system_audio_gain=0.2,
                    microphone_gain=2.0,
                )
                request_id += 1
                controls = updated.get("audio", {}).get("controls", {})
                if controls.get("systemAudioGain") != 0.2 or controls.get("microphoneGain") != 2:
                    raise base.SmokeFailure("runtime gain rebalance did not apply")
                phases_applied.add("rebalanced")

        tone_process.wait(timeout=10)
        tone_process = None
        if phases_applied != {"system_only", "microphone_only", "rebalanced"}:
            raise base.SmokeFailure(f"M2c did not apply every runtime phase: {phases_applied}")
        time.sleep(0.4)

        mixed_result = base.call_tool(
            process,
            request_id,
            "mupaw_recording_stop",
            {"session_id": mixed_session},
            timeout=180,
        )
        mixed_summary = m1e.validate_completed(
            mixed_result,
            expected_session_id=mixed_session,
            expected_source_kind="region",
            expected_frame_rate=30,
            minimum_duration=14.0,
            expected_audio_source="system_audio_and_microphone",
            expected_device_id=microphone_id,
            minimum_audio_rms=MINIMUM_FINAL_RMS,
        )
        active_sessions.discard(mixed_session)
        mixed_payload = base.parse_json_result(mixed_result, "mupaw_recording_stop")
        mixed_audio = mixed_payload.get("artifact", {}).get("audio", {})
        if mixed_audio.get("controlEventCount", 0) < 4:
            raise base.SmokeFailure("completed mix omitted runtime control history")
        system_summary = mixed_audio.get("systemAudioInput", {}).get("levelSummary", {})
        microphone_summary = mixed_audio.get("microphoneInput", {}).get("levelSummary", {})
        if system_summary.get("averageRMS", 0) < MINIMUM_SYSTEM_RMS:
            raise base.SmokeFailure("completed mix system input was silent")
        if microphone_summary.get("averageRMS", 0) < MINIMUM_MICROPHONE_RMS:
            raise base.SmokeFailure("completed mix microphone input was silent")

        inspection = mixed_summary["inspection"]
        segment_rms = inspection.get("audioSegmentRMS")
        segment_counts = inspection.get("audioSegmentSampleCounts")
        if not isinstance(segment_rms, list) or len(segment_rms) != 4:
            raise base.SmokeFailure("MP4 inspector omitted four mixed-audio segments")
        if not isinstance(segment_counts, list) or any(count <= 0 for count in segment_counts):
            raise base.SmokeFailure("one or more mixed-audio segments contained no decoded samples")
        if any(not isinstance(value, (int, float)) or value <= MINIMUM_MICROPHONE_RMS for value in segment_rms):
            raise base.SmokeFailure(f"one or more final mixed-audio phases were silent: {segment_rms}")
        if segment_rms[2] <= segment_rms[1] * 2.0:
            raise base.SmokeFailure(
                "system-only and microphone-only phases were not audibly distinguishable: "
                f"{segment_rms}"
            )

        cancel_prefix = "Mupaw-M2c-Cancel"
        before = artifacts(cancel_prefix)
        cancel_start = m1e.start_recording(
            process,
            request_id + 1,
            mode="region",
            region=region,
            frame_rate=15,
            quality="standard",
            file_name=cancel_prefix,
            audio_source="system_audio_and_microphone",
            microphone_device_id=microphone_id,
        )
        cancel_session = cancel_start["id"]
        active_sessions.add(cancel_session)
        time.sleep(0.8)
        cancelled = base.parse_json_result(
            base.call_tool(
                process,
                request_id + 2,
                "mupaw_recording_cancel",
                {"session_id": cancel_session},
                timeout=60,
            ),
            "mupaw_recording_cancel",
        )
        active_sessions.discard(cancel_session)
        if cancelled.get("phase") != "cancelled" or cancelled.get("artifact") is not None:
            raise base.SmokeFailure("cancelled M2c recording returned an artifact")
        time.sleep(0.25)
        if artifacts(cancel_prefix) != before:
            raise base.SmokeFailure("cancelled M2c recording left a partial file")

        return {
            "appProcessID": app_status.get("processID"),
            "toolCount": len(tools),
            "microphone": microphone,
            "requestedRegion": region,
            "negativeChecks": {
                "invalidGain": invalid_gain,
                "conflictingSource": conflicting_source,
                "emptyUpdate": empty_update,
            },
            "liveLevels": live_snapshots,
            "runtimePhases": sorted(phases_applied),
            "mixed": mixed_summary,
            "mixedAudio": mixed_audio,
            "segmentRMS": segment_rms,
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
        if original_volume is not None:
            m2b.set_output_volume(
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
        print(f"M2c smoke test failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
