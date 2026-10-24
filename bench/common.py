"""Shared helpers for the voice-loop benchmarks (stdlib only)."""
import json, subprocess, time, urllib.error, urllib.request, uuid

OLLAMA = "http://127.0.0.1:11434"


def post_json(url, payload, timeout=300):
    req = urllib.request.Request(url, json.dumps(payload).encode(), {"Content-Type": "application/json"})
    return json.loads(urllib.request.urlopen(req, timeout=timeout).read())


def get_json(url, timeout=30):
    return json.loads(urllib.request.urlopen(url, timeout=timeout).read())


def vram_used_mib():
    out = subprocess.check_output(["nvidia-smi", "--query-gpu=memory.used", "--format=csv,noheader,nounits"], text=True)
    return int(out.strip().splitlines()[0])


def loaded_models():
    return [m["name"] for m in get_json(f"{OLLAMA}/api/ps").get("models", [])]


def unload_all():
    """Evict every model from Ollama so each candidate is measured alone (keep_alive=0 unloads immediately)."""
    for name in loaded_models():
        post_json(f"{OLLAMA}/api/generate", {"model": name, "keep_alive": 0, "prompt": ""})
    for _ in range(30):
        if not loaded_models():
            break
        time.sleep(0.5)
    time.sleep(1.5)  # let the driver release the memory before nvidia-smi is read


def stt(base, wav, lang):
    b = uuid.uuid4().hex
    body = (f'--{b}\r\nContent-Disposition: form-data; name="language"\r\n\r\n{lang}\r\n'
            f'--{b}\r\nContent-Disposition: form-data; name="file"; filename="a.wav"\r\nContent-Type: audio/wav\r\n\r\n').encode() \
           + wav + f"\r\n--{b}--\r\n".encode()
    req = urllib.request.Request(f"{base}/transcribe", body, {"Content-Type": f"multipart/form-data; boundary={b}"})
    t = time.perf_counter()
    r = json.loads(urllib.request.urlopen(req, timeout=120).read())
    r["wall_ms"] = (time.perf_counter() - t) * 1000
    return r


def tts(base, text, lang):
    req = urllib.request.Request(f"{base}/synthesize", json.dumps({"text": text, "language": lang}).encode(),
                                 {"Content-Type": "application/json"})
    t = time.perf_counter()
    r = urllib.request.urlopen(req, timeout=120)
    wav = r.read()
    h = {k.lower(): v for k, v in r.getheaders()}
    return {"wav": wav, "wall_ms": (time.perf_counter() - t) * 1000, "synth_ms": float(h["x-synth-ms"]),
            "audio_s": float(h["x-audio-seconds"]), "voice": h["x-voice"]}


def chat_stream(model, messages, think=None, options=None, keep_alive="30m"):
    """Stream /api/chat. TTFT = request sent -> first non-empty *content* chunk.
    Also counts reasoning chunks so a 'thinking disabled' run can be verified to emit none."""
    payload = {"model": model, "messages": messages, "stream": True, "keep_alive": keep_alive,
               "options": options or {}}
    if think is not None:
        payload["think"] = think
    req = urllib.request.Request(f"{OLLAMA}/api/chat", json.dumps(payload).encode(), {"Content-Type": "application/json"})
    t0 = time.perf_counter()
    ttft, text, thinking, final = None, [], [], {}
    with urllib.request.urlopen(req, timeout=300) as r:
        for line in r:
            if not line.strip():
                continue
            c = json.loads(line)
            m = c.get("message", {})
            if m.get("thinking"):
                thinking.append(m["thinking"])
            if m.get("content"):
                if ttft is None:
                    ttft = (time.perf_counter() - t0) * 1000
                text.append(m["content"])
            if c.get("done"):
                final = c
    total = (time.perf_counter() - t0) * 1000
    ev_s = final.get("eval_duration", 0) / 1e9
    content = "".join(text)
    return {"ttft_ms": ttft, "total_ms": total, "text": content,
            "eval_count": final.get("eval_count", 0), "tok_s": (final.get("eval_count", 0) / ev_s) if ev_s else 0.0,
            "prompt_tokens": final.get("prompt_eval_count", 0), "load_ms": final.get("load_duration", 0) / 1e6,
            "thinking_chars": len("".join(thinking)), "think_tag_in_content": "<think>" in content}
