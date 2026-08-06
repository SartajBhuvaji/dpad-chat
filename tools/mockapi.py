#!/usr/bin/env python3
"""A scriptable stand-in for the chat completions endpoint and GitHub releases.

Exists so the failure paths in the client are testable. A live API cannot be
asked to return 429 on demand, and proving that word wrap works should not cost
tokens. The scenario is chosen by the user message: send "scenario:unauthorized"
and the server answers 401.

It also answers the two GitHub endpoints /update uses, under
``/updates/<scenario>/``, and serves a real tarball built in memory. Pointing
the updater at a directory of fixtures would test the parsing and skip the part
that actually breaks: the download and the unpack.

    tools/mockapi.py --port 8080
    tools/mockapi.py --port 0 --port-file /tmp/port   # ephemeral, for tests

Standard library only: contributors should not need to install anything, and
the CI harness is a minimal Alpine image.
"""

from __future__ import annotations

import argparse
import gzip
import io
import json
import pathlib
import re
import sys
import tarfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Scenarios that behave differently across calls need state; a lock keeps the
# threading server honest.
_state_lock = threading.Lock()
_call_counts: dict[str, int] = {}

MAX_BODY_BYTES = 1 << 20

# Scenarios that have something to stream. Everything else is an error, which
# the real API also returns as a plain body rather than as events.
STREAMABLE = {"ok", "long", "multiline", "stream_cut", "echo_payload"}

# Small enough to keep the suite quick, large enough that a client which
# buffered the whole response would be visibly different from one that does not.
STREAM_DELAY = 0.02

LONG_REPLY = (
    "The SigmaStar SSD202D is the system-on-chip inside the Miyoo Mini and "
    "Mini Plus, pairing two ARM Cortex-A7 cores at 1.2 GHz with 128 MB of "
    "on-package DDR3 memory."
)


# --- GitHub releases -------------------------------------------------------

# What each update scenario publishes. The version is what the client compares
# against its own; "none" and "no_asset" cover the two ways a check can succeed
# at the HTTP level and still have nothing to install.
UPDATE_SCENARIOS = {
    "newer": "v99.0.0",
    "older": "v0.0.1",
    "unversioned": "nightly",
    "no_asset": "v99.0.0",
    "corrupt": "v99.0.0",
    "traversal": "v99.0.0",
    "incomplete": "v99.0.0",
}

# The file set a staged tree is checked against, mirroring tools/package.py.
UPDATE_FILES = {
    "config.json": b'{"label": "D-Pad Chat"}\n',
    "launch.sh": b"#!/bin/sh\nexit 0\n",
    "chat.sh": b"#!/bin/sh\nexit 0\n",
    "apply-update.sh": b"#!/bin/sh\nexit 0\n",
    "lib/common.sh": b"DPADCHAT_VERSION='99.0.0'\n",
    "res/cacert.pem": b"# not a real bundle\n",
    "res/icon.png": b"\x89PNG\r\n\x1a\n",
}


def _tarball(scenario: str) -> bytes:
    """Build the release archive a scenario should serve."""
    if scenario == "corrupt":
        # Gzip magic followed by nothing that inflates, so the failure happens
        # where a truncated download would put it.
        return b"\x1f\x8b\x08\x00" + b"\x00" * 32

    members = dict(UPDATE_FILES)
    if scenario == "incomplete":
        del members["lib/common.sh"]

    prefix = "App/DPadChat"
    raw = io.BytesIO()
    with gzip.GzipFile(fileobj=raw, mode="wb", mtime=0) as gz:
        with tarfile.open(fileobj=gz, mode="w") as tf:  # type: ignore[arg-type]
            for name, payload in members.items():
                arcname = f"{prefix}/{name}"
                if scenario == "traversal":
                    # The entry a hostile archive would carry: it unpacks
                    # outside the directory tar was pointed at.
                    arcname = f"{prefix}/../../../etc/{name}"
                info = tarfile.TarInfo(arcname)
                info.size = len(payload)
                info.mode = 0o755 if name.endswith(".sh") else 0o644
                info.mtime = 0
                tf.addfile(info, io.BytesIO(payload))
    return raw.getvalue()


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


RELEASE_PATH = re.compile(r"^/updates/(?P<scenario>[^/]+)/repos/[^/]+/[^/]+/releases/latest$")
ASSET_PATH = re.compile(r"^/updates/(?P<scenario>[^/]+)/assets/(?P<name>[A-Za-z0-9._-]+)$")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self) -> None:  # noqa: N802 - name fixed by BaseHTTPRequestHandler
        release = RELEASE_PATH.match(self.path)
        if release:
            self._release(release.group("scenario"))
            return

        asset = ASSET_PATH.match(self.path)
        if asset:
            self._asset(asset.group("scenario"), asset.group("name"))
            return

        self._send_json(404, _error(f"Unknown path {self.path}", "not_found"))

    def _release(self, scenario: str) -> None:
        if scenario == "none":
            # What GitHub returns for a repository with no releases, and for one
            # the caller cannot see. The client cannot tell those apart either.
            self._send_json(404, {"message": "Not Found"})
            return

        if scenario == "forbidden":
            self._send_json(403, {"message": "Bad credentials"})
            return

        if scenario not in UPDATE_SCENARIOS:
            self._send_json(404, {"message": f"Unknown update scenario '{scenario}'"})
            return

        base = f"http://{self.headers.get('Host', '127.0.0.1')}/updates/{scenario}/assets"

        # The zip is always present, so a client that picks the wrong asset
        # fails by downloading something it cannot unpack rather than by
        # finding nothing at all.
        assets = [{"name": "DPadChat.zip", "url": f"{base}/DPadChat.zip"}]
        if scenario != "no_asset":
            assets.insert(0, {"name": "DPadChat.tar.gz", "url": f"{base}/DPadChat.tar.gz"})

        tag = UPDATE_SCENARIOS[scenario]
        self._send_json(200, {"tag_name": tag, "name": tag, "assets": assets})

    def _asset(self, scenario: str, name: str) -> None:
        if scenario not in UPDATE_SCENARIOS:
            self._send_json(404, {"message": "Not Found"})
            return

        # Only the tarball is real. A client that reached for the zip would
        # otherwise unpack it happily and the asset choice would go untested.
        body = _tarball(scenario) if name.endswith(".tar.gz") else b"PK\x03\x04not-a-tarball"
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

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

        # A streaming request gets server-sent events. Errors stay plain JSON,
        # exactly as the real API behaves: the failure is known before the
        # stream starts, so there is nothing to stream.
        if payload.get("stream") and scenario in STREAMABLE:
            self._stream(scenario, prompt, payload)
            return

        if scenario == "ok":
            self._send_json(200, _completion(f"You said: {prompt}"))

        elif scenario == "long":
            # Exercises wrapping: far wider than the device's terminal.
            self._send_json(200, _completion(LONG_REPLY))

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

    def _stream(self, scenario: str, prompt: str, payload: dict) -> None:
        if scenario == "stream_cut":
            # Half a reply, then the connection drops: the client has already
            # printed tokens it cannot retry.
            chunks = ["this reply stops ", "half"]
            cut = True
        elif scenario == "long":
            chunks = LONG_REPLY.split(" ")
            chunks = [c + " " for c in chunks]
            cut = False
        elif scenario == "multiline":
            chunks = ["first line\n", "second line\n", "third line"]
            cut = False
        elif scenario == "echo_payload":
            # Split into fixed-size pieces so the client has to reassemble it,
            # which is also what proves nothing is dropped between events.
            body = json.dumps(payload, sort_keys=True)
            chunks = [body[i : i + 24] for i in range(0, len(body), 24)]
            cut = False
        else:
            chunks = [f"You said: {prompt}"]
            cut = False

        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()

        for chunk in chunks:
            event = {
                "choices": [{"index": 0, "delta": {"content": chunk}, "finish_reason": None}]
            }
            self.wfile.write(f"data: {json.dumps(event)}\n\n".encode())
            self.wfile.flush()
            time.sleep(STREAM_DELAY)

        if cut:
            return

        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()

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
