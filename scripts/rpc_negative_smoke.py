#!/usr/bin/env python3
"""Exercise Mupaw's authenticated loopback RPC error paths against a running app."""

from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import socket
import stat
import sys
import time
from pathlib import Path
from typing import Any

MAX_FRAME_BYTES = 4 * 1024 * 1024
PROTOCOL_VERSION = 1
UNKNOWN_RESPONSE_ID = "unknown"
DEFAULT_DESCRIPTOR = (
    Path.home() / "Library" / "Application Support" / "Mupaw" / "agent-connection.json"
)


class SmokeFailure(RuntimeError):
    pass


def load_descriptor_once(path: Path) -> dict[str, Any]:
    if not path.is_file():
        raise SmokeFailure(f"Connection descriptor is missing: {path}")

    mode = stat.S_IMODE(path.stat().st_mode)
    if mode != 0o600:
        raise SmokeFailure(f"Connection descriptor mode is {oct(mode)}, expected 0o600")

    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SmokeFailure(f"Could not read connection descriptor: {error}") from error
    if not isinstance(value, dict):
        raise SmokeFailure("Connection descriptor is not a JSON object")

    port = value.get("port")
    token = value.get("token")
    process_id = value.get("processID")
    protocol_version = value.get("protocolVersion")
    if not isinstance(port, int) or not 1 <= port <= 65_535:
        raise SmokeFailure("Connection descriptor has an invalid port")
    if not isinstance(token, str) or not token:
        raise SmokeFailure("Connection descriptor has an invalid token")
    if not isinstance(process_id, int) or process_id <= 0:
        raise SmokeFailure("Connection descriptor has an invalid processID")
    if protocol_version != PROTOCOL_VERSION:
        raise SmokeFailure(
            f"Connection descriptor protocol version is {protocol_version!r}, expected {PROTOCOL_VERSION}"
        )

    try:
        os.kill(process_id, 0)
    except OSError as error:
        raise SmokeFailure(f"Mupaw process {process_id} is not running") from error
    return value


def wait_for_descriptor(path: Path, wait_seconds: float) -> dict[str, Any]:
    deadline = time.monotonic() + max(0.0, wait_seconds)
    last_error: Exception | None = None
    while True:
        try:
            descriptor = load_descriptor_once(path)
            with socket.create_connection(("127.0.0.1", descriptor["port"]), timeout=1):
                return descriptor
        except (OSError, SmokeFailure) as error:
            last_error = error
        if time.monotonic() >= deadline:
            raise SmokeFailure(f"Mupaw RPC did not become ready: {last_error}") from last_error
        time.sleep(0.1)


def encode_request(
    request_id: str,
    token: str,
    method: str = "ping",
    protocol_version: int = PROTOCOL_VERSION,
    parameters: Any = None,
) -> bytes:
    payload: dict[str, Any] = {
        "id": request_id,
        "protocolVersion": protocol_version,
        "token": token,
        "method": method,
        "parameters": {} if parameters is None else parameters,
    }
    return json.dumps(payload, separators=(",", ":")).encode("utf-8") + b"\n"


def read_response(sock: socket.socket) -> dict[str, Any]:
    data = bytearray()
    while len(data) < MAX_FRAME_BYTES:
        try:
            chunk = sock.recv(64 * 1024)
        except socket.timeout as error:
            raise SmokeFailure("Timed out waiting for an RPC response") from error
        if not chunk:
            break
        newline = chunk.find(b"\n")
        if newline >= 0:
            if len(data) + newline + 1 > MAX_FRAME_BYTES:
                raise SmokeFailure("RPC response exceeded the maximum frame size")
            data.extend(chunk[:newline])
            break
        data.extend(chunk)

    if not data:
        raise SmokeFailure("RPC server closed the connection without a response")
    if len(data) >= MAX_FRAME_BYTES:
        raise SmokeFailure("RPC response was not newline terminated within the frame limit")
    try:
        value = json.loads(data)
    except json.JSONDecodeError as error:
        raise SmokeFailure(f"RPC server returned invalid JSON: {data[:160]!r}") from error
    if not isinstance(value, dict):
        raise SmokeFailure("RPC response was not a JSON object")
    return value


def exchange(
    port: int,
    payload: bytes,
    *,
    timeout: float = 10.0,
    tolerate_send_error: bool = False,
) -> dict[str, Any]:
    with socket.create_connection(("127.0.0.1", port), timeout=timeout) as sock:
        sock.settimeout(timeout)
        try:
            sock.sendall(payload)
        except OSError as error:
            if not tolerate_send_error:
                raise SmokeFailure(f"Could not send RPC frame: {error}") from error
        try:
            sock.shutdown(socket.SHUT_WR)
        except OSError:
            pass
        return read_response(sock)


def assert_success(response: dict[str, Any], request_id: str) -> None:
    if response.get("id") != request_id:
        raise SmokeFailure(
            f"Success response id mismatch: expected {request_id!r}, received {response.get('id')!r}"
        )
    if response.get("error") is not None:
        raise SmokeFailure(f"Expected success for {request_id}, received {response.get('error')!r}")
    if not isinstance(response.get("result"), dict):
        raise SmokeFailure(f"Success response {request_id} omitted its object result")


def assert_error(response: dict[str, Any], request_id: str, code: str) -> None:
    if response.get("id") != request_id:
        raise SmokeFailure(
            f"Error response id mismatch: expected {request_id!r}, received {response.get('id')!r}"
        )
    error = response.get("error")
    if not isinstance(error, dict) or error.get("code") != code:
        raise SmokeFailure(
            f"Expected RPC error {code!r} for {request_id!r}, received {error!r}"
        )
    if response.get("result") is not None:
        raise SmokeFailure(f"Error response {request_id!r} unexpectedly included a result")


def run(descriptor_path: Path, wait_seconds: float) -> dict[str, Any]:
    descriptor = wait_for_descriptor(descriptor_path, wait_seconds)
    port = descriptor["port"]
    token = descriptor["token"]

    checks: dict[str, str] = {}

    response = exchange(port, encode_request("valid-ping", token))
    assert_success(response, "valid-ping")
    checks["validPing"] = "ok"

    response = exchange(port, encode_request("unauthorized", "wrong-token"))
    assert_error(response, "unauthorized", "unauthorized")
    checks["unauthorizedToken"] = "unauthorized"

    response = exchange(
        port,
        encode_request(
            "unauthorized-unknown-method",
            "wrong-token",
            method="does_not_exist",
        ),
    )
    assert_error(response, "unauthorized-unknown-method", "unauthorized")
    checks["authenticationBeforeMethodResolution"] = "unauthorized"

    response = exchange(
        port,
        encode_request("protocol-mismatch", token, protocol_version=PROTOCOL_VERSION + 1),
    )
    assert_error(response, "protocol-mismatch", "protocol_mismatch")
    checks["protocolMismatch"] = "protocol_mismatch"

    response = exchange(port, encode_request("unknown-method", token, method="does_not_exist"))
    assert_error(response, "unknown-method", "unknown_method")
    checks["unknownMethod"] = "unknown_method"

    missing_method = {
        "id": "missing-method",
        "protocolVersion": PROTOCOL_VERSION,
        "token": token,
        "parameters": {},
    }
    response = exchange(
        port,
        json.dumps(missing_method, separators=(",", ":")).encode("utf-8") + b"\n",
    )
    assert_error(response, "missing-method", "invalid_request")
    checks["missingField"] = "invalid_request"

    response = exchange(port, b'{"id":"malformed",\n')
    assert_error(response, UNKNOWN_RESPONSE_ID, "invalid_request")
    checks["malformedJSON"] = "invalid_request"

    response = exchange(port, b"\n")
    assert_error(response, UNKNOWN_RESPONSE_ID, "invalid_request")
    checks["emptyRequest"] = "invalid_request"

    oversized_id = "x" * 257
    response = exchange(port, encode_request(oversized_id, token))
    assert_error(response, UNKNOWN_RESPONSE_ID, "invalid_request")
    checks["oversizedIdentifier"] = "invalid_request"

    oversized_frame = b"x" * MAX_FRAME_BYTES + b"\n"
    response = exchange(
        port,
        oversized_frame,
        timeout=20,
        tolerate_send_error=True,
    )
    assert_error(response, UNKNOWN_RESPONSE_ID, "frame_too_large")
    checks["oversizedFrame"] = "frame_too_large"

    with socket.create_connection(("127.0.0.1", port), timeout=5) as sock:
        sock.sendall(b'{"id":"disconnect"')
    time.sleep(0.05)
    response = exchange(port, encode_request("post-disconnect", token))
    assert_success(response, "post-disconnect")
    checks["clientDisconnectRecovery"] = "ok"

    def concurrent_ping(index: int) -> str:
        request_id = f"concurrent-{index}"
        concurrent_response = exchange(port, encode_request(request_id, token))
        assert_success(concurrent_response, request_id)
        return request_id

    concurrent_count = 32
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as executor:
        completed = list(executor.map(concurrent_ping, range(concurrent_count)))
    if len(completed) != concurrent_count:
        raise SmokeFailure(
            f"Concurrent RPC check completed {len(completed)} of {concurrent_count} requests"
        )

    return {
        "descriptor": {
            "mode": "0o600",
            "port": port,
            "processID": descriptor["processID"],
            "protocolVersion": descriptor["protocolVersion"],
        },
        "checks": checks,
        "concurrency": {
            "workers": 8,
            "completed": concurrent_count,
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--descriptor", type=Path, default=DEFAULT_DESCRIPTOR)
    parser.add_argument("--wait-seconds", type=float, default=0)
    args = parser.parse_args()

    try:
        summary = run(args.descriptor.expanduser().resolve(), args.wait_seconds)
    except SmokeFailure as error:
        print(f"RPC negative smoke test failed: {error}", file=sys.stderr)
        return 1

    print(json.dumps(summary, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
