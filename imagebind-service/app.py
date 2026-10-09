"""
Zero-shot ImageBind activity service, in the contract Assignment 3 expects.

The model is pretrained `imagebind_huge` scoring four hand-written text
prompts (see PROMPTS). Nothing is fine-tuned and no Assignment 2 checkpoint is
loaded; to use one, replace `get_model()`.

This is the off-glasses half of the system. Nothing runs on the phone or the
glasses: the app posts one JPEG (and optionally one short WAV) here, and gets
back a label, a confidence, and the full distribution over the four activities.

    POST /predict     multipart: image=<jpeg>, audio=<wav, optional>
    GET  /latest      the most recent prediction (for the Herald companion)
    GET  /health      readiness, including whether the model is actually loaded

Run locally:

    pip install -r requirements.txt
    uvicorn app:app --host 0.0.0.0 --port 8000

Run in Colab (what Assignment 2 used), exposing it over a tunnel:

    !pip install -r requirements.txt pyngrok
    from pyngrok import ngrok; print(ngrok.connect(8000))
    !uvicorn app:app --host 0.0.0.0 --port 8000

Note: the iOS client POSTs multipart/form-data to `{endpoint}/predict`. A
stock Gradio app does not accept that request, so an existing Gradio
deployment does NOT work unchanged; serve this file (or an adapter with the
same contract) instead.

Env vars: IMAGEBIND_TOKEN, LATEST_PUBLIC, PRELOAD_MODEL, AUDIO_WEIGHT,
SOFTMAX_TEMPERATURE.
"""

from __future__ import annotations

import logging
import os
import secrets
import threading
import time
from contextlib import asynccontextmanager
from typing import Optional

import torch
import torch.nn.functional as F
from fastapi import FastAPI, File, Form, Header, HTTPException, UploadFile
from fastapi.concurrency import run_in_threadpool
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("imagebind-service")

# The four Assignment 2 classes. Order is fixed: it defines the column order of
# the text embedding matrix, so changing it invalidates a cached matrix.
ACTIVITIES = ["walking", "running", "sitting", "standing"]

# Zero-shot prompts. Phrasing matters more than it looks: "a person sitting on
# a chair" pulls in chair pixels and measurably helps the sitting/standing
# split, which is this model's weakest boundary.
PROMPTS = {
    "walking": "a photo of a person walking",
    "running": "a photo of a person running or jogging",
    "sitting": "a photo of a person sitting down on a chair",
    "standing": "a photo of a person standing still and upright",
}

# Weight on the audio branch when a clip is supplied. Vision dominates because
# the audio arriving from the app is Bluetooth HFP — 8 kHz mono, upsampled,
# with nothing above 4 kHz. It carries real information about cadence
# (walking vs. running) and almost none about posture.
AUDIO_WEIGHT = float(os.environ.get("AUDIO_WEIGHT", "0.3"))

# Softmax temperature over cosine similarities. 0.05 is a hand-picked value,
# NOT ImageBind's learned logit scale (this file re-normalises the embeddings,
# which discards that scale). Confidence calibration — and therefore the app's
# 0.45 floor — has not been validated. Override with SOFTMAX_TEMPERATURE.
TEMPERATURE = float(os.environ.get("SOFTMAX_TEMPERATURE", "0.05"))

# Optional shared secret. Set IMAGEBIND_TOKEN here and in Secrets.xcconfig.
AUTH_TOKEN = os.environ.get("IMAGEBIND_TOKEN", "")

# When a token is set, /latest requires it too, unless LATEST_PUBLIC=1. The
# Herald companion cannot send a bearer token, so set LATEST_PUBLIC=1 if you
# want the mirror while the service is token-protected.
LATEST_PUBLIC = os.environ.get("LATEST_PUBLIC", "0") == "1"

# Load the model at startup (default) so the first /predict does not spend
# minutes downloading ~4.5 GB of weights and blow the client's 12 s budget.
PRELOAD_MODEL = os.environ.get("PRELOAD_MODEL", "1") != "0"


@asynccontextmanager
async def lifespan(_app):
    if PRELOAD_MODEL:
        await run_in_threadpool(get_model)
    yield


app = FastAPI(title="ImageBind Activity Service", version="1.0", lifespan=lifespan)

# The Herald companion is a separate origin polling /latest, so it needs CORS.
# Only the read-only endpoints are exposed cross-origin.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=False,
    allow_methods=["GET"],
    allow_headers=["*"],
)

_model = None
_text_embeddings = None
_device = "cuda" if torch.cuda.is_available() else "cpu"
_load_lock = threading.Lock()

# Most recent prediction, served to the Herald companion. Deliberately holds
# only the label, the scores and a timestamp — never the frame or the audio.
_latest: Optional[dict] = None
_latest_lock = threading.Lock()


def get_model():
    """Load ImageBind once, lazily. First call downloads ~4.5 GB of weights."""
    global _model, _text_embeddings
    # Double-checked: the fast path must not take the lock, or every request
    # after the load would serialize on it and concurrent predictions would
    # queue behind each other for no reason.
    if _model is not None:
        return _model
    with _load_lock:
        if _model is not None:
            return _model

        from imagebind import data as ib_data
        from imagebind.models import imagebind_model
        from imagebind.models.imagebind_model import ModalityType

        log.info("loading ImageBind onto %s …", _device)
        model = imagebind_model.imagebind_huge(pretrained=True)
        model.eval().to(_device)

        # Text embeddings never change, so compute them once at load rather
        # than on every request — it is most of the per-request cost otherwise.
        with torch.no_grad():
            inputs = {
                ModalityType.TEXT: ib_data.load_and_transform_text(
                    [PROMPTS[a] for a in ACTIVITIES], _device
                )
            }
            embeddings = model(inputs)[ModalityType.TEXT]
            _text_embeddings = F.normalize(embeddings, dim=-1)

        _model = model
        log.info("ImageBind ready")
        return _model


def _similarities(embedding, text_embeddings):
    """Cosine similarity of one embedding against the four class prompts."""
    normalized = F.normalize(embedding, dim=-1)
    return normalized @ text_embeddings.T


def _require_token(authorization: Optional[str]) -> None:
    """401 unless the configured bearer token was sent. No-op without a token."""
    if not AUTH_TOKEN:
        return
    expected = f"Bearer {AUTH_TOKEN}".encode()
    # Compare bytes: compare_digest raises TypeError on non-ASCII str input,
    # which would turn a bad header into a 500.
    sent = (authorization or "").encode("utf-8", "surrogateescape")
    if not secrets.compare_digest(sent, expected):
        raise HTTPException(status_code=401, detail="missing or invalid bearer token")


@app.post("/predict")
async def predict(
    image: UploadFile = File(...),
    audio: Optional[UploadFile] = File(None),
    source: str = Form("unknown"),
    authorization: Optional[str] = Header(None),
):
    # Enforce the token if one is configured. This used to be a bare `pass`,
    # which is worse than having no auth at all: the README and the iOS client
    # both behave as though the endpoint is gated, so a tunnel that leaked
    # would have been wide open while looking protected.
    _require_token(authorization)

    image_bytes = await image.read()
    if not image_bytes:
        raise HTTPException(status_code=400, detail="empty image part")

    audio_bytes = await audio.read() if audio is not None else None

    # ImageBind inference is CPU/GPU-bound and blocking. Running it directly in
    # an `async def` would occupy the event loop for the whole forward pass, so
    # /health and /latest would stop answering for the duration — which is
    # exactly when the Herald companion is polling for the result.
    payload = await run_in_threadpool(_infer, image_bytes, audio_bytes)

    with _latest_lock:
        global _latest
        _latest = {**payload, "received_at": time.time(), "source": source}

    log.info("%s → %s (%.2f) in %d ms", source, payload["label"],
             payload["confidence"], payload["latency_ms"])
    return JSONResponse(payload)


def _infer(image_bytes: bytes, audio_bytes: Optional[bytes]) -> dict:
    """Blocking forward pass. Always called on a worker thread."""
    started = time.perf_counter()

    import tempfile
    from imagebind import data as ib_data
    from imagebind.models.imagebind_model import ModalityType

    model = get_model()
    modalities = ["vision"]

    with tempfile.TemporaryDirectory() as tmp:
        image_path = os.path.join(tmp, "frame.jpg")
        with open(image_path, "wb") as handle:
            handle.write(image_bytes)

        inputs = {
            ModalityType.VISION: ib_data.load_and_transform_vision_data(
                [image_path], _device
            )
        }

        if audio_bytes:
            audio_path = os.path.join(tmp, "clip.wav")
            with open(audio_path, "wb") as handle:
                handle.write(audio_bytes)
            # Audio is optional. A clip that cannot be decoded (empty, wrong
            # format, too short) must degrade to a vision-only prediction,
            # not turn the whole request into a 500.
            try:
                inputs[ModalityType.AUDIO] = ib_data.load_and_transform_audio_data(
                    [audio_path], _device
                )
                modalities.append("audio")
            except Exception as error:  # noqa: BLE001 — any decode failure
                log.warning("audio clip unusable, predicting vision-only: %s", error)

        with torch.no_grad():
            try:
                embeddings = model(inputs)
            except Exception as error:  # noqa: BLE001
                if ModalityType.AUDIO not in inputs:
                    raise
                log.warning("audio forward pass failed, retrying vision-only: %s", error)
                inputs.pop(ModalityType.AUDIO)
                modalities.remove("audio")
                embeddings = model(inputs)
            logits = _similarities(embeddings[ModalityType.VISION], _text_embeddings)

            if ModalityType.AUDIO in embeddings:
                audio_logits = _similarities(
                    embeddings[ModalityType.AUDIO], _text_embeddings
                )
                # Late fusion on the similarity scores. ImageBind's whole point
                # is a shared space, so the two branches are directly
                # comparable and a weighted sum is enough — no extra head to
                # train, and nothing here contradicts Assignment 2's model.
                logits = (1 - AUDIO_WEIGHT) * logits + AUDIO_WEIGHT * audio_logits

            # Without a temperature the cosine similarities sit in a narrow
            # band and softmax comes out nearly uniform. See TEMPERATURE above:
            # the value is a hand-picked default and calibration is unverified.
            probabilities = torch.softmax(logits / TEMPERATURE, dim=-1)[0]

    scores = {name: float(probabilities[i]) for i, name in enumerate(ACTIVITIES)}
    label = max(scores, key=scores.get)

    return {
        "label": label,
        "confidence": scores[label],
        "scores": scores,
        "modalities": modalities,
        "latency_ms": int((time.perf_counter() - started) * 1000),
    }


@app.get("/latest")
async def latest(authorization: Optional[str] = Header(None)):
    """Read-only mirror for the optional Herald companion.

    Returns only the prediction. The frame and the audio clip are never stored
    and are never served — the assignment's privacy rules say not to keep raw
    media longer than a trial needs, and a display-only web page has no reason
    to see it.

    Gated by the same bearer token as /predict when one is configured, unless
    LATEST_PUBLIC=1.
    """
    if not LATEST_PUBLIC:
        _require_token(authorization)
    with _latest_lock:
        if _latest is None:
            return JSONResponse({"status": "idle"}, status_code=200)
        return JSONResponse({"status": "ok", **_latest})


@app.get("/health")
async def health():
    return {
        "status": "ok",
        "model_loaded": _model is not None,
        "device": _device,
        "activities": ACTIVITIES,
        "audio_weight": AUDIO_WEIGHT,
    }
