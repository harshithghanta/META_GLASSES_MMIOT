#!/usr/bin/env python3
"""
Zero-dependency mock of the ImageBind service.

Runs on the Python standard library alone — no torch, no FastAPI, no 4.5 GB of
weights — so the full app → network → prediction → HUD path can be exercised
on a laptop, in CI, and while the real Colab tunnel is down.

    python3 imagebind-service/mock_server.py --port 8000

Binds 127.0.0.1 by default. To reach it from an iPhone on the same Wi-Fi, add
`--host 0.0.0.0` and point the app at http://<your-mac-LAN-IP>:8000.

It speaks the same contract as `app.py`, and it can be told to misbehave on
purpose, which is how the required endpoint-failure trial is reproduced without
waiting for Colab to actually die:

    /predict                 -> a normal, confident prediction
    /predict?mode=low        -> below the confidence floor (fallback path)
    /predict?mode=timeout    -> hangs past the client's 12 s budget
    /predict?mode=error      -> HTTP 503
    /predict?mode=garbage    -> 200 with an unparseable body
    /predict?label=running   -> force a particular activity

Calling /predict with no query at all walks a fixed six-step cycle: the four
activities, then a low-confidence answer, then a timeout. That is for driving
the app by hand across a full set of trials. The smoke test and the trial
replay both pass explicit modes instead, so they stay deterministic regardless
of how many requests preceded them.
"""

from __future__ import annotations

import argparse
import json
import random
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

ACTIVITIES = ["walking", "running", "sitting", "standing"]
MODES = {"ok", "low", "timeout", "error", "garbage"}

# Deterministic by default: a mock that returns different numbers on every run
# makes a failing check impossible to reproduce.
RNG = random.Random(20260722)

_latest = None
_latest_lock = threading.Lock()
_call_count = 0
_count_lock = threading.Lock()


def parse_multipart(body: bytes, content_type: str) -> dict[str, bytes]:
    """Split a multipart body into {field name: payload}.

    Just enough of RFC 7578 to validate what the iOS client sends — the real
    service uses Starlette's parser, so this only has to be correct for the
    one body shape `HTTPImageBindClient.multipartBody` produces.
    """
    if "boundary=" not in content_type:
        return {}
    boundary = content_type.split("boundary=", 1)[1].strip().strip('"')
    delimiter = b"--" + boundary.encode()

    parts: dict[str, bytes] = {}
    for chunk in body.split(delimiter):
        if b"\r\n\r\n" not in chunk:
            continue
        head, _, payload = chunk.partition(b"\r\n\r\n")
        match = re.search(rb'name="([^"]+)"', head)
        if not match:
            continue
        # Strip exactly the one CRLF that precedes the next delimiter. A bare
        # rstrip(b"\r\n") also ate trailing 0x0D/0x0A bytes that belong to a
        # binary payload (e.g. the last PCM sample of a WAV).
        if payload.endswith(b"\r\n"):
            payload = payload[:-2]
        parts[match.group(1).decode()] = payload
    return parts


def clamp_confidence(confidence: float) -> float:
    """Force a requested confidence into the range a 4-class argmax allows.

    Below 1/n the other classes must absorb 1 - c between them, so one of them
    necessarily outscores the stated label. `?confidence=0.2` used to return
    `{"label": "walking", "walking": 0.2, "sitting": 0.31, "standing": 0.31}` —
    a prediction contradicting its own label, which the Swift client then
    reported with a negative top-1/top-2 margin.

    Clamping has to happen HERE rather than inside `distribution()`, so that the
    value written to `payload["confidence"]` is the same one the scores were
    built from. Clamping only the scores swaps one inconsistency for another.
    """
    floor = 1.0 / len(ACTIVITIES)
    if not (confidence == confidence):        # NaN
        return 0.82
    return max(floor + 0.01, min(1.0, confidence))


def distribution(label: str, confidence: float) -> dict[str, float]:
    """Spread the remaining mass over the other three classes.

    The runner-up is always the class this model actually confuses `label`
    with, so the mock's margins look like the real ones rather than a flat
    tail. sitting/standing is the pair that matters — see docs/REPORT.md.
    """
    confusions = {
        "walking": "running",
        "running": "walking",
        "sitting": "standing",
        "standing": "sitting",
    }
    others = [a for a in ACTIVITIES if a != label]
    runner_up = confusions[label]
    remainder = 1.0 - confidence

    # Never let the runner-up outscore the stated label...
    runner_up_score = min(remainder * 0.6, confidence * 0.9)
    rest = (remainder - runner_up_score) / (len(others) - 1)

    # ...and never let the tail overtake it either. Near the floor the leftover
    # mass is big enough that capping only the runner-up is not sufficient.
    if rest > runner_up_score:
        runner_up_score = rest = remainder / len(others)

    scores = {label: confidence, runner_up: runner_up_score}
    for activity in others:
        if activity != runner_up:
            scores[activity] = rest
    return {a: round(scores[a], 4) for a in ACTIVITIES}


def next_scripted_call() -> tuple[str, str, float]:
    """The six-step cycle served to requests with no query string (manual runs)."""
    global _call_count
    with _count_lock:
        index = _call_count
        _call_count += 1

    script = [
        ("ok", "walking", 0.88),
        ("ok", "running", 0.91),
        ("ok", "sitting", 0.69),
        ("ok", "standing", 0.57),
        ("low", "sitting", 0.34),
        ("timeout", "standing", 0.0),
    ]
    return script[index % len(script)]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        print(f"[mock] {self.address_string()} {fmt % args}")

    # -- helpers ---------------------------------------------------------

    def _send_json(self, payload: dict, status: int = 200):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def _send_raw(self, body: bytes, status: int = 200, content_type="text/plain"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    # -- routes ----------------------------------------------------------

    def do_GET(self):
        route = urlparse(self.path).path
        if route == "/health":
            return self._send_json(
                {"status": "ok", "model_loaded": False, "device": "mock",
                 "activities": ACTIVITIES}
            )
        if route == "/latest":
            with _latest_lock:
                if _latest is None:
                    return self._send_json({"status": "idle"})
                return self._send_json({"status": "ok", **_latest})
        return self._send_json({"error": "not found"}, status=404)

    def do_POST(self):
        parsed = urlparse(self.path)
        if parsed.path != "/predict":
            return self._send_json({"error": "not found"}, status=404)

        query = parse_qs(parsed.query)
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length) if length else b""

        # Validate the multipart body the way the real service does, so a
        # client bug shows up here rather than as a confusing model result.
        content_type = self.headers.get("Content-Type", "")
        if "multipart/form-data" not in content_type:
            return self._send_json(
                {"error": f"expected multipart/form-data, got {content_type!r}"},
                status=400,
            )
        parts = parse_multipart(body, content_type)
        # Check the payload, not just the header. A client bug that sends a
        # well-formed part with zero bytes in it is exactly the kind of thing
        # this mock exists to catch, and `b'name="image"' in body` would miss.
        if not parts.get("image"):
            return self._send_json({"error": "missing or empty image part"}, status=400)
        has_audio = bool(parts.get("audio"))

        mode = query.get("mode", [None])[0]
        forced_label = query.get("label", [None])[0]

        # Reject bad query parameters with a 400 instead of letting the handler
        # raise (which dropped the connection with no response at all).
        if forced_label is not None and forced_label not in ACTIVITIES:
            return self._send_json(
                {"error": f"unknown label {forced_label!r}; expected one of {ACTIVITIES}"},
                status=400,
            )
        if mode is not None and mode not in MODES:
            return self._send_json(
                {"error": f"unknown mode {mode!r}; expected one of {sorted(MODES)}"},
                status=400,
            )
        try:
            requested_confidence = float(query.get("confidence", ["0.82"])[0])
            delay = query.get("delay", [None])[0]
            delay = None if delay is None else float(delay)
        except ValueError as error:
            return self._send_json({"error": f"bad numeric parameter: {error}"}, status=400)

        if mode is None and forced_label is None:
            mode, label, confidence = next_scripted_call()
        else:
            label = forced_label or RNG.choice(ACTIVITIES)
            confidence = requested_confidence
            mode = mode or "ok"

        if mode == "timeout":
            # Outlast the iOS client's 12 s budget without closing the socket,
            # which is exactly how a recycled Colab tunnel behaves.
            time.sleep(20.0 if delay is None else delay)
            return self._send_json({"error": "too late"}, status=504)

        if mode == "error":
            return self._send_json({"error": "upstream unavailable"}, status=503)

        if mode == "garbage":
            return self._send_raw(b"<html>tunnel expired</html>", 200, "text/html")

        if mode == "low":
            confidence = min(confidence, 0.34)

        confidence = clamp_confidence(confidence)

        payload = {
            "label": label,
            "confidence": confidence,
            "scores": distribution(label, confidence),
            "modalities": ["vision", "audio"] if has_audio else ["vision"],
            "latency_ms": RNG.randint(280, 620),
        }

        global _latest
        with _latest_lock:
            _latest = {**payload, "received_at": time.time(), "source": "mock"}

        # A little latency so the Analyzing states are actually visible.
        time.sleep(0.35 if delay is None else delay)
        return self._send_json(payload)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument(
        "--host", default="127.0.0.1",
        help="interface to bind (default 127.0.0.1; use 0.0.0.0 to accept LAN connections from a phone)",
    )
    args = parser.parse_args()

    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"[mock] ImageBind mock listening on http://{args.host}:{args.port}")
    print("[mock] POST /predict  ·  GET /latest  ·  GET /health")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n[mock] stopped")


if __name__ == "__main__":
    main()
