#!/usr/bin/env python3
"""Reproducible smoke test for the local Mupaw MCP stdio server."""

from __future__ import annotations

import argparse
import json
import os
import selectors
import subprocess
import sys
from pathlib import Path
from typing import Any

PROTOCOL_VERSION = "2025-11-25"
EXPECTED_TOOLS = {
    "mupaw_app_status",
    "mupaw_capabilities_get",
    "mupaw_sources_list",
    "mupaw_screenshot_capture",
}


class SmokeFailure(RuntimeError):
    pass


def write_message(process: subprocess.Popen[bytes], payload: dict[str, Any]) -> None:
    if process.stdin is None:
        raise SmokeFailure("MCP process stdin is unavailable")
    process.stdin.write(json.dumps(payload, separators=(",", ":")).encode("utf-8") + b"\n")
    process.stdin.flush()


def read_message(process: subprocess.Popen[bytes], timeout: float = 8.0) -> dict[str, Any]:
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
    return result_for(read_message(process), request_id)


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


def run(executable: Path, require_running: bool) -> dict[str, Any]:
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

        status = parse_status(call_tool(process, 3, "mupaw_app_status"))
        if require_running and not status["running"]:
            raise SmokeFailure(
                "Mupaw.app is not reachable. Start it with `make run`, then retry."
            )

        capability_summary: dict[str, Any] | None = None
        source_check: dict[str, Any] | None = None
        availability_check: dict[str, Any] | None = None
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
            expected_available = {"source-enumeration", "screenshot", "agent-mcp"}
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

        return {
            "server": server_info,
            "protocolVersion": initialize.get("protocolVersion"),
            "toolNames": sorted(tool_names),
            "appStatus": status,
            "availabilityCheck": availability_check,
            "capabilities": capability_summary,
            "sourcesCheck": source_check,
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
    args = parser.parse_args()

    try:
        summary = run(args.executable.resolve(), args.require_running)
    except SmokeFailure as error:
        print(f"MCP smoke test failed: {error}", file=sys.stderr)
        return 1

    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
