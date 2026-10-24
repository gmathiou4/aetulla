"""STT service: POST /transcribe (audio upload) -> text + detected language + per-stage timings.

The model is loaded once at startup and kept resident. /health returns 503 until the
warmup (which triggers the sm_120 PTX JIT, see Dockerfile) has finished, so the compose
healthcheck only goes green when the first real request will be fast.
"""
import io
import os
import threading
import time
from contextlib import asynccontextmanager

import numpy as np
from faster_whisper import WhisperModel
from faster_whisper.audio import decode_audio
from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.responses import JSONResponse

MODEL = os.environ.get("STT_MODEL", "deepdml/faster-whisper-large-v3-turbo-ct2")
COMPUTE_TYPE = os.environ.get("STT_COMPUTE_TYPE", "int8_float16")
BEAM_SIZE = int(os.environ.get("STT_BEAM_SIZE", "1"))  # 1 = lowest latency; raise for accuracy
MAX_UPLOAD_BYTES = 25 * 1024 * 1024
LANGS = {"auto": None, "en": "en", "el": "el"}

state = {"model": None, "ready": False, "warmup_s": None, "load_s": None}
gpu_lock = threading.Lock()  # one inference at a time on the single resident model


def _warmup(model: WhisperModel) -> None:
    # Noise + tone, VAD *off*: with VAD on, synthetic audio is filtered as non-speech and the
    # decoder never runs, so the decoder kernels would not get JIT-compiled.
    sr = 16000
    x = (0.05 * np.random.randn(sr * 4)
         + 0.3 * np.sin(2 * np.pi * 220 * np.arange(sr * 4) / sr)).astype(np.float32)
    # Cover the three code paths real requests take: auto-detect, en, el.
    for lang in (None, "en", "el"):
        segs, _ = model.transcribe(x, beam_size=BEAM_SIZE, language=lang, vad_filter=False)
        list(segs)  # transcribe() is lazy; consume it to run the decoder


@asynccontextmanager
async def lifespan(_: FastAPI):
    t0 = time.perf_counter()
    model = WhisperModel(MODEL, device="cuda", compute_type=COMPUTE_TYPE)
    state["load_s"] = round(time.perf_counter() - t0, 2)
    t1 = time.perf_counter()
    _warmup(model)
    state["warmup_s"] = round(time.perf_counter() - t1, 2)
    state["model"], state["ready"] = model, True
    print(f"ready: model={MODEL} compute={COMPUTE_TYPE} load={state['load_s']}s warmup={state['warmup_s']}s",
          flush=True)
    yield


app = FastAPI(lifespan=lifespan)


@app.get("/health")
def health():
    body = {"ready": state["ready"], "model": MODEL, "compute_type": COMPUTE_TYPE,
            "load_s": state["load_s"], "warmup_s": state["warmup_s"]}
    return JSONResponse(body, status_code=200 if state["ready"] else 503)


@app.post("/transcribe")
def transcribe(file: UploadFile = File(...), language: str = Form("auto")):
    if not state["ready"]:
        raise HTTPException(503, "model not ready")
    if language not in LANGS:
        raise HTTPException(400, f"language must be one of {sorted(LANGS)}")
    raw = file.file.read(MAX_UPLOAD_BYTES + 1)
    if len(raw) > MAX_UPLOAD_BYTES:
        raise HTTPException(413, "upload too large")

    t0 = time.perf_counter()
    try:
        audio = decode_audio(io.BytesIO(raw), sampling_rate=16000)  # PyAV: any format -> 16 kHz mono
    except Exception as e:
        raise HTTPException(400, f"could not decode audio: {e}")
    t_decode = time.perf_counter()

    with gpu_lock:
        t_lock = time.perf_counter()
        # transcribe() does feature extraction + VAD (+ language detection) up front and returns a
        # lazy generator; the decoder runs while we consume it. Time the two parts separately.
        segs, info = state["model"].transcribe(
            audio, beam_size=BEAM_SIZE, language=LANGS[language],
            vad_filter=True, condition_on_previous_text=False)
        t_prep = time.perf_counter()
        text = " ".join(s.text.strip() for s in segs).strip()
        t_end = time.perf_counter()

    return {
        "text": text,
        "language": info.language,
        "language_probability": round(info.language_probability, 3),
        "audio_s": round(info.duration, 2),
        "speech_s": round(info.duration_after_vad, 2),
        "timings_ms": {
            "audio_decode": round((t_decode - t0) * 1000, 1),
            "lock_wait": round((t_lock - t_decode) * 1000, 1),
            "vad_and_lang": round((t_prep - t_lock) * 1000, 1),
            "asr": round((t_end - t_prep) * 1000, 1),
            "total": round((t_end - t0) * 1000, 1),
        },
    }
