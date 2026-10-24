"""TTS service (Piper, CPU): POST /synthesize -> audio/wav, timings in response headers.

Voices live in the /voices volume. On startup each file is hash-checked against voices.json;
missing or corrupt files are (re)downloaded from a revision-pinned URL and re-verified, so a
tampered or truncated download never reaches the ONNX loader.
"""
import hashlib
import io
import json
import os
import threading
import time
import urllib.request
import wave
from contextlib import asynccontextmanager
from pathlib import Path

import onnxruntime
from fastapi import FastAPI, HTTPException
from fastapi.responses import JSONResponse, Response
from piper import PiperVoice, SynthesisConfig
from piper.config import PiperConfig
from pydantic import BaseModel, Field

VOICES_DIR = Path(os.environ.get("TTS_VOICES_DIR", "/voices"))
THREADS = int(os.environ.get("TTS_THREADS", "4"))  # intra-op threads per synthesis; also cap CPUs in compose
MAX_CHARS = 2000
MANIFEST = json.loads((Path(__file__).parent / "voices.json").read_text())

state = {"voices": {}, "ready": False, "load_s": None, "warmup_s": None}
lock = threading.Lock()  # one synthesis at a time: bounds CPU use


def sha256_of(p: Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def ensure_file(rel_dir: str, name: str, want: str) -> Path:
    dest = VOICES_DIR / name
    if dest.exists() and sha256_of(dest) == want:
        return dest
    url = f"{MANIFEST['base_url']}/{MANIFEST['revision']}/{rel_dir}/{name}"
    print(f"downloading {name} <- {url}", flush=True)
    tmp = dest.with_suffix(dest.suffix + ".part")
    urllib.request.urlretrieve(url, tmp)
    got = sha256_of(tmp)
    if got != want:
        tmp.unlink(missing_ok=True)
        raise RuntimeError(f"checksum mismatch for {name}: expected {want}, got {got}")
    tmp.rename(dest)  # atomic: a half-written file never carries the final name
    return dest


def load_voice(entry: dict) -> PiperVoice:
    paths = {n: ensure_file(entry["dir"], n, h) for n, h in entry["files"].items()}
    onnx_path = next(p for n, p in paths.items() if n.endswith(".onnx"))
    cfg_path = next(p for n, p in paths.items() if n.endswith(".onnx.json"))
    so = onnxruntime.SessionOptions()
    so.intra_op_num_threads = THREADS  # PiperVoice.load() doesn't expose this, so build the session ourselves
    so.inter_op_num_threads = 1
    session = onnxruntime.InferenceSession(str(onnx_path), sess_options=so, providers=["CPUExecutionProvider"])
    return PiperVoice(session=session, config=PiperConfig.from_dict(json.loads(cfg_path.read_text())),
                      download_dir=Path("/tmp"))


def synth_wav(voice: PiperVoice, text: str, speed: float) -> tuple[bytes, float]:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        voice.synthesize_wav(text, w, syn_config=SynthesisConfig(length_scale=1.0 / speed))
    data = buf.getvalue()
    with wave.open(io.BytesIO(data)) as r:
        return data, r.getnframes() / r.getframerate()


@asynccontextmanager
async def lifespan(_: FastAPI):
    t0 = time.perf_counter()
    for lang, entry in MANIFEST["voices"].items():
        state["voices"][lang] = (entry["name"], load_voice(entry))
    state["load_s"] = round(time.perf_counter() - t0, 2)
    t1 = time.perf_counter()
    for lang, (_, v) in state["voices"].items():  # first call per voice pays one-off ONNX/espeak init
        synth_wav(v, "Warm up." if lang == "en" else "Δοκιμή.", 1.0)
    state["warmup_s"] = round(time.perf_counter() - t1, 2)
    state["ready"] = True
    print(f"ready: voices={[n for n, _ in state['voices'].values()]} threads={THREADS} "
          f"load={state['load_s']}s warmup={state['warmup_s']}s", flush=True)
    yield


app = FastAPI(lifespan=lifespan)


class Req(BaseModel):
    text: str = Field(min_length=1, max_length=MAX_CHARS)
    language: str = "en"  # en | el  (selects the voice)
    speed: float = Field(1.0, ge=0.5, le=2.0)  # 1.0 normal, 2.0 twice as fast


@app.get("/health")
def health():
    body = {"ready": state["ready"], "threads": THREADS, "load_s": state["load_s"],
            "warmup_s": state["warmup_s"], "voices": {k: n for k, (n, _) in state["voices"].items()}}
    return JSONResponse(body, status_code=200 if state["ready"] else 503)


@app.post("/synthesize")
def synthesize(req: Req):
    if not state["ready"]:
        raise HTTPException(503, "voices not ready")
    if req.language not in state["voices"]:
        raise HTTPException(400, f"language must be one of {sorted(state['voices'])}")
    name, voice = state["voices"][req.language]
    t0 = time.perf_counter()
    with lock:
        t_lock = time.perf_counter()
        data, audio_s = synth_wav(voice, req.text, req.speed)
        t_end = time.perf_counter()
    synth_ms = (t_end - t_lock) * 1000
    return Response(data, media_type="audio/wav", headers={
        "X-Voice": name,
        "X-Audio-Seconds": f"{audio_s:.3f}",
        "X-Synth-Ms": f"{synth_ms:.1f}",
        "X-Lock-Wait-Ms": f"{(t_lock - t0) * 1000:.1f}",
        "X-Total-Ms": f"{(t_end - t0) * 1000:.1f}",
        "X-RTF": f"{(synth_ms / 1000) / audio_s:.3f}",  # <1 = faster than real time
        "Access-Control-Expose-Headers": "X-Voice,X-Audio-Seconds,X-Synth-Ms,X-Lock-Wait-Ms,X-Total-Ms,X-RTF",
    })
