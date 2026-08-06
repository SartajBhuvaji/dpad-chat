#!/usr/bin/env python3
"""A scriptable stand-in for the chat completions endpoint.

Exists so the failure paths in the client are testable. A live API cannot be
asked to return 429 on demand, and proving that word wrap works should not cost
tokens. The scenario is chosen by the user message: send "scenario:unauthorized"
and the server answers 401.

    tools/mockapi.py --port 8080
    tools/mockapi.py --port 0 --port-file /tmp/port   # ephemeral, for tests

Standard library only: contributors should not need to install anything, and
the CI harness is a minimal Alpine image.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Scenarios that behave differently across calls need state; a lock keeps the
# threading server honest.
_state_lock = threading.Lock()
_call_counts: dict[str, int] = {}

MAX_BODY_BYTES = 1 << 20


def _next_count(scenario: str) -> int:
    with _state_lock:
        _call_counts[scenario] = _call_counts.get(scenario, 0) + 1
        return _call_counts[scenario]


def _completion(text: str) -> dict:
    return {
        "id": "chatcmpl-mock",
        "object": "chat.completion",
        "model": "mock",
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": text},
                "finish_reason": "stop",
            }
        ],
        "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0},
    }


def _error(message: str, err_type: str) -> dict:
    return {"error": {"message": message, "type": err_type, "code": None}}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    # Quiet by default: the test suite drives this and its output is noise.
    def log_message(self, fmt: str, *args) -> None:
        if self.server.verbose:  # type: ignore[attr-defined]
            sys.stderr.write("mockapi: " + fmt % args + "\n")

    def do_POST(self) -> None:  # noqa: N802 - name fixed by BaseHTTPRequestHandler
        if not self.path.endswith("/chat/completions"):
            self._send_json(404, _error(f"Unknown path {self.path}", "invalid_request"))
            return

        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            self._send_json(400, _error("Bad Content-Length", "invalid_request"))
            return

        if length > MAX_BODY_BYTES:
            self._send_json(413, _error("Body too large", "invalid_request"))
            return

        raw = self.rfile.read(length)

        # Authorization is checked first so a missing header fails the way the
        # real API fails, not with a confusing scenario error.
        auth = self.headers.get("Authorization", "")
        if not re.fullmatch(r"Bearer \S+", auth):
            self._send_json(
                401, _error("Missing or malformed Authorization header", "invalid_request_error")
            )
            return

        try:
            payload = json.loads(raw)
        except json.JSONDecodeError as exc:
            self._send_json(400, _error(f"Invalid JSON: {exc}", "invalid_request_error"))
            return

        prompt = self._last_user_message(payload)
        self._dispatch(prompt, payload)

    @staticmethod
    def _last_user_message(payload: dict) -> str:
        for message in reversed(payload.get("messages", [])):
            if message.get("role") == "user":
                return str(message.get("content", ""))
        return ""

    def _dispatch(self, prompt: str, payload: dict) -> None:
        scenario = "ok"
        if prompt.startswith("scenario:"):
            scenario = prompt.split(":", 1)[1].strip() or "ok"

        if scenario == "ok":
            self._send_json(200, _completion(f"You said: {prompt}"))

        elif scenario == "long":
            # Exercises wrapping: far wider than the device's terminal.
            self._send_json(
                200,
                _completion(
                    "The SigmaStar SSD202D is the system-on-chip inside the "
                    "Miyoo Mini and Mini Plus, pairing two ARM Cortex-A7 cores "
                    "at 1.2 GHz with 128 MB of on-package DDR3 memory."
                ),
            )

        elif scenario == "multiline":
            self._send_json(200, _completion("first line\nsecond line\nthird line"))

        elif scenario == "unauthorized":
            self._send_json(401, _error("Incorrect API key provided", "invalid_request_error"))

        elif scenario == "rate_limit":
            # 429 on the first call, success on the second: proves the client
            # retries rather than merely reporting the failure.
            if _next_count("rate_limit") == 1:
                self._send_json(429, _error("Rate limit reached", "rate_limit_error"))
            else:
                self._send_json(200, _completion("recovered after rate limit"))

        elif scenario == "rate_limit_always":
            self._send_json(429, _error("Rate limit reached", "rate_limit_error"))

        elif scenario == "server_error":
            self._send_json(500, _error("Internal server error", "server_error"))

        elif scenario == "malformed":
            self._send_raw(200, b'{"choices": [{"message": {"content": "trunc')

        elif scenario == "empty":
            self._send_json(
                200,
                {
                    "choices": [
                        {"index": 0, "message": {"role": "assistant", "content": ""},
                         "finish_reason": "content_filter"}
                    ]
                },
            )

        elif scenario == "slow":
            time.sleep(float(payload.get("mock_delay", 5)))
            self._send_json(200, _completion("eventually"))

        elif scenario == "echo_payload":
            # Lets tests assert on what the client actually sent.
            self._send_json(200, _completion(json.dumps(payload, sort_keys=True)))

        else:
            self._send_json(400, _error(f"Unknown scenario '{scenario}'", "invalid_request_error"))

    def _send_json(self, status: int, body: dict) -> None:
        self._send_raw(status, json.dumps(body).encode())

    def _send_raw(self, status: int, body: bytes) -> None:
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8080, help="0 picks a free port")
    parser.add_argument(
        "--port-file",
        type=pathlib.Path,
        help="write the bound port here; how tests learn an ephemeral port",
    )
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    server.verbose = args.verbose  # type: ignore[attr-defined]
    port = server.server_address[1]

    # Written only once the socket is bound, so a test that waits for this file
    # cannot race the server's startup.
    if args.port_file:
        args.port_file.write_text(str(port))

    print(f"listening on {args.host}:{port}", flush=True)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
