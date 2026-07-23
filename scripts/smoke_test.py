#!/usr/bin/env python3
"""
End-to-end contract check between the iOS client and the ImageBind service.

The point of this script is that it does not trust either side's description of
the contract. It:

  1. starts `imagebind-service/mock_server.py`,
  2. builds a multipart request byte-for-byte the way `HTTPImageBindClient`
     does in Swift,
  3. posts it and captures the real response,
  4. pipes that response through the **actual Swift decoder**
     (`swift run corecheck --decode`), not a Python reimplementation of it,
  5. asserts the client and the service agree about what was said.

Steps 4 and 5 are the reason this exists. A hand-written mock and a
hand-written client will happily agree on a contract that neither implements
correctly; running the real decoder over real bytes is what catches that.

    python3 scripts/smoke_test.py

Exits non-zero on the first disagreement.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MOCK = ROOT / "imagebind-service" / "mock_server.py"
CORE = ROOT / "ActivityAssistantCore"
PORT = 8731
BASE = f"http://127.0.0.1:{PORT}"

# Mirrors CapturedFrame.sample() / CapturedAudio.sample() in Swift.
JPEG = (b"\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00"
        b"\xff\xd9")
WAV = (b"RIFF$\x00\x00\x00WAVEfmt \x10\x00\x00\x00\x01\x00\x01\x00"
       b"\x80>\x00\x00\x00}\x00\x00\x02\x00\x10\x00data\x00\x00\x00\x00")

failures: list[str] = []
checks = 0


def check(condition: bool, message: str) -> None:
    global checks
    checks += 1
    if condition:
        print(f"  \033[32m✓\033[0m {message}")
    else:
        print(f"  \033[31m✗\033[0m {message}")
        failures.append(message)


def multipart(image: bytes, audio: bytes | None) -> tuple[bytes, str]:
    """Byte-for-byte the body `HTTPImageBindClient.multipartBody` produces."""
    boundary = "Boundary-SMOKETEST"
    out = bytearray()

    def part(name, filename, mime, payload):
        out.extend(f"--{boundary}\r\n".encode())
        out.extend(
            f'Content-Disposition: form-data; name="{name}"; filename="{filename}"\r\n'.encode()
        )
        out.extend(f"Content-Type: {mime}\r\n\r\n".encode())
        out.extend(payload)
        out.extend(b"\r\n")

    part("image", "frame.jpg", "image/jpeg", image)
    if audio is not None:
        part("audio", "clip.wav", "audio/wav", audio)
    out.extend(f"--{boundary}\r\n".encode())
    out.extend(b'Content-Disposition: form-data; name="source"\r\n\r\n')
    out.extend(b"raybandisplay-dat-ios\r\n")
    out.extend(f"--{boundary}--\r\n".encode())

    return bytes(out), f"multipart/form-data; boundary={boundary}"


def post(path: str, image=JPEG, audio=WAV, timeout=15):
    body, content_type = multipart(image, audio)
    request = urllib.request.Request(
        f"{BASE}{path}", data=body, headers={"Content-Type": content_type}
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, response.read()
    except urllib.error.HTTPError as error:
        return error.code, error.read()


def swift_decode(payload: bytes) -> tuple[int, str]:
    """Run the real Swift decoder over these exact bytes."""
    result = subprocess.run(
        ["swift", "run", "--quiet", "corecheck", "--decode"],
        input=payload,
        cwd=CORE,
        capture_output=True,
    )
    return result.returncode, result.stdout.decode().strip()


def parse_fields(line: str) -> dict[str, str]:
    fields = {}
    for token in line.split():
        if "=" in token:
            key, _, value = token.partition("=")
            fields[key] = value
    return fields


def main() -> int:
    print("Building the Swift decoder …")
    build = subprocess.run(
        ["swift", "build", "--quiet", "--product", "corecheck"],
        cwd=CORE, capture_output=True,
    )
    if build.returncode != 0:
        print(build.stderr.decode())
        return 1

    print(f"Starting the mock service on :{PORT} …")
    server = subprocess.Popen(
        [sys.executable, str(MOCK), "--port", str(PORT)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    try:
        for _ in range(50):
            try:
                urllib.request.urlopen(f"{BASE}/health", timeout=1).read()
                break
            except Exception:
                time.sleep(0.1)
        else:
            print("mock server never became healthy")
            return 1

        print("\n\033[1mService contract\033[0m")
        status, body = post("/predict?mode=ok&label=walking&confidence=0.88")
        check(status == 200, f"POST /predict returns 200 (got {status})")
        payload = json.loads(body)
        check(set(payload) >= {"label", "confidence", "scores"},
              "response carries label, confidence and scores")
        check(abs(sum(payload["scores"].values()) - 1.0) < 1e-3,
              f"scores sum to 1 (got {sum(payload['scores'].values()):.4f})")
        check(payload["modalities"] == ["vision", "audio"],
              "service reports both modalities when audio is attached")

        print("\n\033[1mSwift client decodes what the service actually sends\033[0m")
        code, line = swift_decode(body)
        fields = parse_fields(line)
        check(code == 0, f"Swift decoder accepts the body (exit {code}: {line})")
        check(fields.get("label") == payload["label"],
              f"labels agree: swift={fields.get('label')} service={payload['label']}")
        check(abs(float(fields.get("confidence", -1)) - payload["confidence"]) < 1e-3,
              "confidences agree")
        check(float(fields.get("margin", -1)) > 0,
              f"top-1 outscores the runner-up (margin {fields.get('margin')})")
        check(fields.get("modalities") == "audio+vision",
              f"modalities survive the round trip (got {fields.get('modalities')})")

        print("\n\033[1mVision-only request\033[0m")
        status, body = post("/predict?mode=ok&label=sitting", audio=None)
        payload = json.loads(body)
        check(payload["modalities"] == ["vision"],
              "omitting the audio part yields a vision-only prediction")
        code, line = swift_decode(body)
        check(parse_fields(line).get("modalities") == "vision",
              "Swift agrees it was vision-only")

        print("\n\033[1mLow-confidence path\033[0m")
        status, body = post("/predict?mode=low&label=sitting")
        payload = json.loads(body)
        check(payload["confidence"] < 0.45,
              f"below the 0.45 client floor (got {payload['confidence']})")
        code, line = swift_decode(body)
        check(code == 0, "a low-confidence body still decodes cleanly")
        check(float(parse_fields(line).get("margin", -1)) > 0,
              "even a low-confidence response has a positive margin")

        print("\n\033[1mFailure paths the app must survive\033[0m")
        status, _ = post("/predict?mode=error")
        check(status == 503, f"mode=error returns 503 (got {status})")

        status, body = post("/predict?mode=garbage")
        check(status == 200, "mode=garbage returns 200 with a non-JSON body")
        code, line = swift_decode(body)
        check(code != 0, "Swift rejects an HTML body instead of guessing")
        check("Malformed" in line or "malformed" in line,
              f"…and reports it as malformed (got {line!r})")

        status, _ = post("/predict", image=b"")
        check(status == 400, f"an empty image part is rejected (got {status})")

        code, line = swift_decode(b'{"label":"cycling","confidence":0.9,"scores":{"cycling":0.9}}')
        check(code != 0 and "Unknown label" in line,
              f"an out-of-vocabulary label is refused (got {line!r})")

        print("\n\033[1mDegenerate confidences keep a consistent argmax\033[0m")
        # Regression: below 1/n the leftover mass forced another class above the
        # stated label, so the service described a prediction that contradicted
        # itself and the Swift decoder reported a negative margin.
        for requested in ["0.05", "0.2", "0.26", "0.3"]:
            status, body = post(f"/predict?mode=ok&label=walking&confidence={requested}")
            payload = json.loads(body)
            top = max(payload["scores"], key=payload["scores"].get)
            check(top == payload["label"],
                  f"conf={requested}: stated label is the argmax (top={top})")
            code, line = swift_decode(body)
            margin = float(parse_fields(line).get("margin", -1))
            check(code == 0 and margin > 0,
                  f"conf={requested}: Swift sees a positive margin ({margin})")

        print("\n\033[1mHerald mirror endpoint\033[0m")
        post("/predict?mode=ok&label=running&confidence=0.9")
        with urllib.request.urlopen(f"{BASE}/latest", timeout=5) as response:
            latest = json.loads(response.read())
            cors = response.headers.get("Access-Control-Allow-Origin")
        check(latest.get("status") == "ok", "/latest reports a prediction")
        check(latest.get("label") == "running",
              f"/latest mirrors the most recent call (got {latest.get('label')})")
        check(cors == "*", "/latest sends CORS headers so Herald can read it")
        check("image" not in latest and "audio" not in latest,
              "/latest never exposes the raw frame or clip")

        print()
        if failures:
            print(f"\033[31m{len(failures)} failure(s), {checks - len(failures)} passed.\033[0m")
            return 1
        print(f"\033[32m{checks} checks passed.\033[0m")
        return 0
    finally:
        server.terminate()
        server.wait(timeout=5)


if __name__ == "__main__":
    sys.exit(main())
