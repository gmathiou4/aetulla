#!/usr/bin/env python3
"""Phase 1a end-to-end benchmark: WAV -> stt -> LLM -> tts (stdlib only).

  # 8B candidates with stt resident:
  python3 bench/voice_loop.py --models qwen3:8b,hf.co/ilsp/Llama-Krikri-8B-Instruct-GGUF:Q4_K_M --runs 5
  # solo baseline, stt stopped: LLM + TTS only, input = known reference text instead of STT output
  python3 bench/voice_loop.py --models qwen2.5:14b-instruct --runs 5 --no-stt

Each model is measured alone (all others evicted first). One discarded warmup call per model
loads it; its load time is reported separately. Stages are sequential (no streaming overlap),
so e2e = stt + llm_total + tts. STT language is forced to the file's language (design rule:
configured default language first, auto only as fallback).
"""
import argparse, json, pathlib, re, statistics, uuid
from common import chat_stream, loaded_models, stt, tts, unload_all, vram_used_mib

AUDIO = pathlib.Path(__file__).parent / "audio"
REF = {  # used with --no-stt; identical to the text of the fixtures (see audio/README.md)
    "en": "Hello, can you tell me what the capital of France is, and how far it is from Berlin?",
    "el": "Καλημέρα, μπορείς να μου πεις ποια είναι η πρωτεύουσα της Ελλάδας και πόσο μακριά είναι από την Κρήτη;",
}
SYSTEM = ("You are a helpful voice assistant. Answer in 1-2 short sentences. "
          "Always reply in the same language as the user's message.")
OPTIONS = {"temperature": 0.7, "num_ctx": 4096, "num_predict": 160}  # num_ctx matches the pinned 14B's 4096


def med(xs):
    return statistics.median(xs) if xs else float("nan")


def speakable(s):  # strip markdown/newlines that the TTS would read or choke on
    return re.sub(r"\s+", " ", re.sub(r"[*_`#>]+", "", s)).strip()[:600]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", required=True)
    ap.add_argument("--runs", type=int, default=5)
    ap.add_argument("--no-stt", action="store_true")
    ap.add_argument("--stt", default="http://127.0.0.1:8010")
    ap.add_argument("--tts", default="http://127.0.0.1:8020")
    ap.add_argument("--warm-prompt", action="store_true", help="reuse Ollama's prompt cache (understates TTFT)")
    ap.add_argument("--json", help="write raw per-run results here")
    a = ap.parse_args()
    results = {}

    for model in a.models.split(","):
        think = False if model.startswith("qwen3") else None  # qwen3: disable reasoning; other models have no switch
        unload_all()
        base = vram_used_mib()
        warm = chat_stream(model, [{"role": "user", "content": "Say hi."}], think=think, options=OPTIONS)
        vram = vram_used_mib()
        print(f"\n=== {model}  think={think}  stt={'off' if a.no_stt else 'on'} ===")
        print(f"loaded: {loaded_models()} | load {warm['load_ms']:.0f} ms | VRAM {base} -> {vram} MiB (+{vram - base}) | free {12227 - vram} MiB")
        res = {"vram_base": base, "vram_loaded": vram, "load_ms": warm["load_ms"], "runs": []}

        for lang in ("en", "el"):
            wav = (AUDIO / f"{lang}_01.wav").read_bytes()
            rows = []
            for i in range(a.runs):
                if a.no_stt:
                    heard, stt_ms = REF[lang], 0.0
                else:
                    r = stt(a.stt, wav, lang)
                    heard, stt_ms = r["text"], r["wall_ms"]
                # The transcript is identical every run, so without a nonce Ollama reuses the cached prompt
                # prefix and TTFT collapses to ~14 ms. A fresh nonce at the *start* of the prompt invalidates the
                # whole prefix = cold prompt (worst case for a new conversation). --warm-prompt keeps the cache.
                sysmsg = SYSTEM if a.warm_prompt else f"[turn {uuid.uuid4().hex[:8]}] {SYSTEM}"
                llm = chat_stream(model, [{"role": "system", "content": sysmsg}, {"role": "user", "content": heard}],
                                  think=think, options=OPTIONS)
                speech = tts(a.tts, speakable(llm["text"]) or ".", lang)
                e2e = stt_ms + llm["total_ms"] + speech["wall_ms"]
                rows.append({"lang": lang, "heard": heard, "reply": llm["text"], "stt_ms": stt_ms, "ttft_ms": llm["ttft_ms"],
                             "llm_ms": llm["total_ms"], "tok_s": llm["tok_s"], "tokens": llm["eval_count"],
                             "tts_ms": speech["wall_ms"], "tts_synth_ms": speech["synth_ms"], "audio_s": speech["audio_s"],
                             "e2e_ms": e2e, "thinking_chars": llm["thinking_chars"], "think_tag": llm["think_tag_in_content"]})
            res["runs"] += rows
            leak = sum(r["thinking_chars"] for r in rows) + sum(r["think_tag"] for r in rows)
            print(f"[{lang}] median of {a.runs}: STT {med([r['stt_ms'] for r in rows]):6.0f} ms | LLM TTFT {med([r['ttft_ms'] for r in rows]):6.0f} ms"
                  f" | LLM total {med([r['llm_ms'] for r in rows]):6.0f} ms ({med([r['tokens'] for r in rows]):.0f} tok, {med([r['tok_s'] for r in rows]):.1f} tok/s)"
                  f" | TTS {med([r['tts_ms'] for r in rows]):5.0f} ms (audio {med([r['audio_s'] for r in rows]):.1f} s)"
                  f" | E2E {med([r['e2e_ms'] for r in rows]):6.0f} ms | reasoning leaked: {leak}")
            print(f"     heard: {rows[0]['heard']}\n     reply: {rows[0]['reply']}")
        results[model] = res

    if a.json:
        pathlib.Path(a.json).write_text(json.dumps(results, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
