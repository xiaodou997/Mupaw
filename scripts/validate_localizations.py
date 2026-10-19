#!/usr/bin/env python3
"""Validate Mupaw localization resources with Apple's property-list parser."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
RESOURCE_ROOT = ROOT / "Resources" / "MupawApp"
LANGUAGES = ("en", "zh-Hans")
TABLES = ("Localizable.strings", "InfoPlist.strings")
REQUIRED_LOCALIZABLE_KEYS = {
    "app.tagline",
    "action.capture",
    "action.request_screen_access",
    "permission.screen_capture",
    "rpc.ready.format",
    "capture.error.source_not_found.format",
    "capture.mode.full_screen",
    "capture.mode.window",
    "capture.mode.region",
    "capture.region.instructions",
    "capture.error.invalid_region",
    "shortcut.status.conflict",
    "editor.tool.style",
    "editor.style.preset.ocean",
    "editing.detail.invalid_visual_style",
    "workspace.mode.recording",
    "recording.action.start",
    "recording.error.finalization_failed.format",
    "recording.system_audio",
    "recording.audio_source",
    "recording.audio_source.microphone",
    "recording.microphone.device",
    "recording.microphone.request_permission",
    "recording.error.audio_mixing_not_supported",
    "recording.audio.state.completed",
    "recording.metadata.audio_sync_difference",
}
REQUIRED_INFO_KEYS = {
    "NSCameraUsageDescription",
    "NSMicrophoneUsageDescription",
}


class LocalizationFailure(RuntimeError):
    pass


def load_strings(path: Path) -> dict[str, str]:
    if not path.is_file():
        raise LocalizationFailure(f"Missing localization file: {path.relative_to(ROOT)}")

    result = subprocess.run(
        ["plutil", "-convert", "json", "-o", "-", str(path)],
        check=False,
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        message = result.stderr.strip() or result.stdout.strip()
        raise LocalizationFailure(f"Invalid strings file {path.relative_to(ROOT)}: {message}")

    try:
        value: Any = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise LocalizationFailure(f"plutil returned invalid JSON for {path.relative_to(ROOT)}") from error

    if not isinstance(value, dict) or not all(isinstance(key, str) and isinstance(item, str) for key, item in value.items()):
        raise LocalizationFailure(f"Localization table is not a string dictionary: {path.relative_to(ROOT)}")
    return value


def validate_table(table: str) -> int:
    loaded = {
        language: load_strings(RESOURCE_ROOT / f"{language}.lproj" / table)
        for language in LANGUAGES
    }
    base_keys = set(loaded[LANGUAGES[0]])

    for language, values in loaded.items():
        keys = set(values)
        missing = sorted(base_keys - keys)
        extra = sorted(keys - base_keys)
        empty = sorted(key for key, value in values.items() if not value.strip())
        if missing or extra or empty:
            parts: list[str] = []
            if missing:
                parts.append(f"missing={missing}")
            if extra:
                parts.append(f"extra={extra}")
            if empty:
                parts.append(f"empty={empty}")
            raise LocalizationFailure(f"{language}/{table} key mismatch: {'; '.join(parts)}")

    required = REQUIRED_LOCALIZABLE_KEYS if table == "Localizable.strings" else REQUIRED_INFO_KEYS
    missing_required = sorted(required - base_keys)
    if missing_required:
        raise LocalizationFailure(f"{table} is missing required keys: {missing_required}")
    return len(base_keys)


def main() -> int:
    try:
        counts = {table: validate_table(table) for table in TABLES}
    except LocalizationFailure as error:
        print(f"Localization validation failed: {error}", file=sys.stderr)
        return 1

    summary = ", ".join(f"{table}={count}" for table, count in counts.items())
    print(f"Localization validation passed for {', '.join(LANGUAGES)}: {summary}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
