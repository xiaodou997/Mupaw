#!/usr/bin/env python3
"""End-to-end M1c OCR and color-sampling smoke test through MCP."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

import m1b_smoke as m1b
import mcp_smoke as base

ANALYSIS_TOOLS = {
    "mupaw_project_ocr",
    "mupaw_project_color_sample",
}
HEX_RGB = re.compile(r"^#[0-9A-F]{6}$")
HEX_RGBA = re.compile(r"^#[0-9A-F]{8}$")


def rect_values(value: Any, label: str) -> dict[str, float]:
    if not isinstance(value, dict):
        raise base.SmokeFailure(f"{label} omitted a rectangle")
    result: dict[str, float] = {}
    for key in ("x", "y", "width", "height"):
        component = value.get(key)
        if not isinstance(component, (int, float)):
            raise base.SmokeFailure(f"{label}.{key} is not numeric")
        result[key] = float(component)
    if result["width"] <= 0 or result["height"] <= 0:
        raise base.SmokeFailure(f"{label} has non-positive dimensions")
    return result


def validate_rect_within(
    value: Any,
    *,
    label: str,
    width: int,
    height: int,
) -> dict[str, float]:
    rect = rect_values(value, label)
    epsilon = 0.01
    if rect["x"] < -epsilon or rect["y"] < -epsilon:
        raise base.SmokeFailure(f"{label} starts outside the original image")
    if rect["x"] + rect["width"] > width + epsilon:
        raise base.SmokeFailure(f"{label} exceeds the original image width")
    if rect["y"] + rect["height"] > height + epsilon:
        raise base.SmokeFailure(f"{label} exceeds the original image height")
    return rect


def validate_sampled_color(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise base.SmokeFailure(f"{label} omitted sampled color metadata")
    rgba = value.get("rgba")
    if not isinstance(rgba, dict):
        raise base.SmokeFailure(f"{label}.rgba is missing")
    for component in ("red", "green", "blue", "alpha"):
        number = rgba.get(component)
        if not isinstance(number, (int, float)) or not 0 <= float(number) <= 1:
            raise base.SmokeFailure(f"{label}.rgba.{component} is outside 0...1")
    hex_rgb = value.get("hexRGB")
    hex_rgba = value.get("hexRGBA")
    if not isinstance(hex_rgb, str) or HEX_RGB.fullmatch(hex_rgb) is None:
        raise base.SmokeFailure(f"{label}.hexRGB is invalid: {hex_rgb!r}")
    if not isinstance(hex_rgba, str) or HEX_RGBA.fullmatch(hex_rgba) is None:
        raise base.SmokeFailure(f"{label}.hexRGBA is invalid: {hex_rgba!r}")
    luminance = value.get("relativeLuminance")
    if not isinstance(luminance, (int, float)) or not 0 <= float(luminance) <= 1:
        raise base.SmokeFailure(f"{label}.relativeLuminance is invalid")
    if not isinstance(value.get("isDark"), bool):
        raise base.SmokeFailure(f"{label}.isDark is missing")
    return value


def validate_ocr(
    payload: dict[str, Any],
    *,
    project_id: str,
    revision: int,
    width: int,
    height: int,
) -> dict[str, Any]:
    if payload.get("projectID") != project_id:
        raise base.SmokeFailure("OCR projectID mismatch")
    if payload.get("projectRevision") != revision:
        raise base.SmokeFailure("OCR project revision mismatch")
    if payload.get("source") != "original":
        raise base.SmokeFailure("OCR did not report immutable-original analysis")
    engine = payload.get("recognitionEngine")
    if engine not in {"vision_fast", "vision_accurate"}:
        raise base.SmokeFailure(f"OCR returned an invalid recognitionEngine: {engine!r}")
    effective_languages = payload.get("effectiveRecognitionLanguages")
    if not isinstance(effective_languages, list) or not all(
        isinstance(value, str) and value for value in effective_languages
    ):
        raise base.SmokeFailure("OCR omitted effectiveRecognitionLanguages")
    detected_languages = payload.get("detectedLanguages")
    if not isinstance(detected_languages, list) or not all(
        isinstance(value, str) and value and value != "und" for value in detected_languages
    ):
        raise base.SmokeFailure("OCR omitted valid detectedLanguages")
    validate_rect_within(
        payload.get("analyzedRegion"),
        label="OCR analyzedRegion",
        width=width,
        height=height,
    )
    full_text = payload.get("fullText")
    observations = payload.get("observations")
    if not isinstance(full_text, str) or not isinstance(observations, list):
        raise base.SmokeFailure("OCR omitted fullText or observations")
    if not observations:
        raise base.SmokeFailure("OCR returned no observations for the visible Mupaw window")
    if len(observations) > 512:
        raise base.SmokeFailure("OCR returned more than the bounded observation count")

    observation_text: list[str] = []
    identifiers: set[str] = set()
    for index, observation in enumerate(observations):
        if not isinstance(observation, dict):
            raise base.SmokeFailure(f"OCR observation {index} is not an object")
        identifier = observation.get("id")
        text = observation.get("text")
        confidence = observation.get("confidence")
        language = observation.get("language")
        if not isinstance(identifier, str) or not identifier:
            raise base.SmokeFailure(f"OCR observation {index} omitted id")
        if identifier in identifiers:
            raise base.SmokeFailure(f"OCR observation id is duplicated: {identifier}")
        identifiers.add(identifier)
        if not isinstance(text, str) or not text.strip():
            raise base.SmokeFailure(f"OCR observation {index} omitted text")
        if not isinstance(confidence, (int, float)) or not 0 <= float(confidence) <= 1:
            raise base.SmokeFailure(f"OCR observation {index} has invalid confidence")
        if not isinstance(language, str) or not language:
            raise base.SmokeFailure(f"OCR observation {index} omitted language")
        validate_rect_within(
            observation.get("boundingBox"),
            label=f"OCR observation {index} boundingBox",
            width=width,
            height=height,
        )
        observation_text.append(text)

    if full_text != "\n".join(observation_text):
        raise base.SmokeFailure("OCR fullText does not match ordered observations")
    if "mupaw" not in full_text.casefold():
        raise base.SmokeFailure(f"OCR did not recognize the visible Mupaw title: {full_text!r}")
    return payload


def validate_point_sample(
    payload: dict[str, Any],
    *,
    project_id: str,
    revision: int,
    width: int,
    height: int,
) -> dict[str, Any]:
    if payload.get("projectID") != project_id or payload.get("projectRevision") != revision:
        raise base.SmokeFailure("Point color result project identity mismatch")
    if payload.get("source") != "original" or payload.get("mode") != "point":
        raise base.SmokeFailure("Point color result source or mode mismatch")
    point = payload.get("point")
    if not isinstance(point, dict):
        raise base.SmokeFailure("Point color result omitted point")
    x = point.get("x")
    y = point.get("y")
    if not isinstance(x, (int, float)) or not isinstance(y, (int, float)):
        raise base.SmokeFailure("Point color coordinates are invalid")
    if not 0 <= float(x) < width or not 0 <= float(y) < height:
        raise base.SmokeFailure("Point color coordinates exceed the original image")
    if payload.get("sampledPixelCount") != 1:
        raise base.SmokeFailure("Point color result did not sample exactly one pixel")
    validate_sampled_color(payload.get("primaryColor"), "point primaryColor")
    if payload.get("averageColor") is not None:
        raise base.SmokeFailure("Point color result unexpectedly included averageColor")
    return payload


def validate_region_sample(
    payload: dict[str, Any],
    *,
    project_id: str,
    revision: int,
    width: int,
    height: int,
) -> dict[str, Any]:
    if payload.get("projectID") != project_id or payload.get("projectRevision") != revision:
        raise base.SmokeFailure("Region color result project identity mismatch")
    if payload.get("source") != "original" or payload.get("mode") != "region":
        raise base.SmokeFailure("Region color result source or mode mismatch")
    validate_rect_within(
        payload.get("region"),
        label="color region",
        width=width,
        height=height,
    )
    sample_count = payload.get("sampledPixelCount")
    if not isinstance(sample_count, int) or not 1 <= sample_count <= 65_536:
        raise base.SmokeFailure("Region color sampledPixelCount is outside the bounded range")
    primary = validate_sampled_color(payload.get("primaryColor"), "region primaryColor")
    average = validate_sampled_color(payload.get("averageColor"), "region averageColor")
    validate_sampled_color(payload.get("centerColor"), "region centerColor")
    validate_sampled_color(payload.get("dominantColor"), "region dominantColor")
    if primary != average:
        raise base.SmokeFailure("Region primaryColor does not equal averageColor")
    return payload


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
        missing = ANALYSIS_TOOLS - tool_names
        if missing:
            raise base.SmokeFailure(f"M1c tools/list omitted: {sorted(missing)}")

        artifact, capture_summary = m1b.capture_fixture(process, 10)
        capture_url = artifact.get("fileURL")
        capture_hash = artifact.get("sha256")
        artifact_id = artifact.get("id")
        width = artifact.get("pixelWidth")
        height = artifact.get("pixelHeight")
        if not all(isinstance(value, str) for value in (capture_url, capture_hash, artifact_id)):
            raise base.SmokeFailure("Capture artifact omitted M1c project-create fields")
        if not isinstance(width, int) or not isinstance(height, int) or width <= 0 or height <= 0:
            raise base.SmokeFailure("Capture artifact omitted M1c dimensions")

        created = m1b.project_state(
            process,
            20,
            "mupaw_project_create",
            {
                "source_file_url": capture_url,
                "source_sha256": capture_hash,
                "source_artifact_id": artifact_id,
                "title": "Mupaw M1c OCR and Color Smoke",
            },
        )
        project_id = created["id"]
        revision = created.get("revision")
        if revision != 1:
            raise base.SmokeFailure("M1c project did not start at revision 1")
        original_path = m1b.file_path_from_url(created.get("originalFileURL"), "M1c project")
        if not original_path.is_file():
            raise base.SmokeFailure("M1c project original does not exist")
        project_document = original_path.parent / "project.json"
        if not project_document.is_file():
            raise base.SmokeFailure("M1c project document does not exist")
        original_before = hashlib.sha256(original_path.read_bytes()).hexdigest()
        document_before = hashlib.sha256(project_document.read_bytes()).hexdigest()
        if original_before != capture_hash:
            raise base.SmokeFailure("M1c project original SHA-256 differs from capture")

        ocr_payload = base.parse_json_result(
            base.call_tool(
                process,
                21,
                "mupaw_project_ocr",
                {
                    "project_id": project_id,
                    "expected_revision": revision,
                    "recognition_level": "accurate",
                    "recognition_languages": [],
                    "uses_language_correction": True,
                    "minimum_confidence": 0.05,
                },
                timeout=180.0,
            ),
            "mupaw_project_ocr",
        )
        ocr = validate_ocr(
            ocr_payload,
            project_id=project_id,
            revision=revision,
            width=width,
            height=height,
        )

        point_payload = base.parse_json_result(
            base.call_tool(
                process,
                22,
                "mupaw_project_color_sample",
                {
                    "project_id": project_id,
                    "expected_revision": revision,
                    "mode": "point",
                    "point": {"x": width // 2, "y": height // 2},
                },
            ),
            "mupaw_project_color_sample",
        )
        point = validate_point_sample(
            point_payload,
            project_id=project_id,
            revision=revision,
            width=width,
            height=height,
        )

        region_request = {
            "x": max(0, width // 8),
            "y": max(0, height // 8),
            "width": max(1, width - 2 * (width // 8)),
            "height": max(1, height - 2 * (height // 8)),
        }
        region_payload = base.parse_json_result(
            base.call_tool(
                process,
                23,
                "mupaw_project_color_sample",
                {
                    "project_id": project_id,
                    "expected_revision": revision,
                    "mode": "region",
                    "region": region_request,
                },
            ),
            "mupaw_project_color_sample",
        )
        region = validate_region_sample(
            region_payload,
            project_id=project_id,
            revision=revision,
            width=width,
            height=height,
        )

        negative = {
            "missingPoint": base.expect_tool_error(
                base.call_tool(
                    process,
                    30,
                    "mupaw_project_color_sample",
                    {"project_id": project_id, "mode": "point"},
                ),
                "mupaw_project_color_sample",
                "invalid_request",
            ),
            "outsidePoint": base.expect_tool_error(
                base.call_tool(
                    process,
                    31,
                    "mupaw_project_color_sample",
                    {
                        "project_id": project_id,
                        "mode": "point",
                        "point": {"x": width, "y": 0},
                    },
                ),
                "mupaw_project_color_sample",
                "invalid_request",
            ),
            "invalidConfidence": base.expect_tool_error(
                base.call_tool(
                    process,
                    32,
                    "mupaw_project_ocr",
                    {"project_id": project_id, "minimum_confidence": 2},
                ),
                "mupaw_project_ocr",
                "invalid_request",
            ),
            "tooManyLanguages": base.expect_tool_error(
                base.call_tool(
                    process,
                    33,
                    "mupaw_project_ocr",
                    {
                        "project_id": project_id,
                        "recognition_languages": ["en-US"] * 9,
                    },
                ),
                "mupaw_project_ocr",
                "invalid_request",
            ),
            "staleRevision": base.expect_tool_error(
                base.call_tool(
                    process,
                    34,
                    "mupaw_project_ocr",
                    {"project_id": project_id, "expected_revision": 999},
                ),
                "mupaw_project_ocr",
                "project_version_conflict",
            ),
        }

        fetched = m1b.project_state(
            process,
            35,
            "mupaw_project_get",
            {"project_id": project_id},
        )
        if fetched.get("revision") != revision or fetched.get("content") != created.get("content"):
            raise base.SmokeFailure("Read-only M1c analysis changed the project state")
        if hashlib.sha256(original_path.read_bytes()).hexdigest() != original_before:
            raise base.SmokeFailure("M1c analysis changed the immutable project original")
        if hashlib.sha256(project_document.read_bytes()).hexdigest() != document_before:
            raise base.SmokeFailure("M1c analysis changed the project document")

        return {
            "toolCount": len(tool_names),
            "analysisTools": sorted(ANALYSIS_TOOLS),
            "capture": capture_summary,
            "project": {
                "id": project_id,
                "revision": fetched.get("revision"),
                "originalFile": str(original_path),
                "originalSHA256": original_before,
            },
            "ocr": {
                "observationCount": len(ocr.get("observations", [])),
                "fullTextPreview": ocr.get("fullText", "")[:240],
                "analyzedRegion": ocr.get("analyzedRegion"),
                "recognitionLevel": ocr.get("recognitionLevel"),
                "recognitionEngine": ocr.get("recognitionEngine"),
                "effectiveRecognitionLanguages": ocr.get(
                    "effectiveRecognitionLanguages"
                ),
                "detectedLanguages": ocr.get("detectedLanguages"),
            },
            "pointColor": {
                "point": point.get("point"),
                "hexRGBA": point.get("primaryColor", {}).get("hexRGBA"),
            },
            "regionColor": {
                "region": region.get("region"),
                "sampledPixelCount": region.get("sampledPixelCount"),
                "average": region.get("averageColor", {}).get("hexRGBA"),
                "center": region.get("centerColor", {}).get("hexRGBA"),
                "dominant": region.get("dominantColor", {}).get("hexRGBA"),
            },
            "negativeChecks": negative,
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
        print(f"M1c MCP smoke test failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps(summary, indent=2, sort_keys=True, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
