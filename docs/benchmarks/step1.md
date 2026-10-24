# Step 1 benchmark — bare voice loop (WAV -> STT -> LLM -> TTS)

Measured 2026-10-24 on: Ryzen 9800X3D, RTX 5070 12 GB (driver 621.01), WSL2, Ollama 0.40.10.
All numbers are medians of 5 runs after 1 discarded warmup call. Stages run sequentially (no
streaming overlap), so `E2E = STT + LLM total + TTS`.

**Read these caveats first**
- Input audio is *synthetic* (Piper, `bench/audio/`). It proves the pipeline and gives a known
  reference; it says nothing about real-speech accuracy (Step 2).
- n = 5 per cell. Differences under ~10 % are noise.
- Reply length differs per model and drives LLM total/E2E. `qwen3:8b` answered Greek in 76 tokens
  vs Krikri's 21; tokens/s are nearly identical. Compare tok/s and token counts, not just totals.
- Factual correctness of replies was **not** graded (distances varied by model and run).
- `qwen2.5:14b-instruct` is a solo baseline: `stt` was stopped, input was the reference text, so its
  E2E **excludes STT** (add roughly 200-230 ms for a like-for-like figure — it would not fit anyway).

## Configuration

| Stage | Setting |
|---|---|
| STT | `stt` service: faster-whisper large-v3-turbo, int8_float16, beam 1, VAD on, language forced to the file's language (design rule: configured default first, auto only as fallback) |
| LLM | Ollama `/api/chat` streaming, `num_ctx 4096`, temperature 0.7, `num_predict 160`, system prompt "answer in 1-2 short sentences, same language as the user". `qwen3:8b` with `think=false` (0 reasoning chars and no `<think>` in any run). |
| TTS | `tts` service: Piper CPU, 4 threads, `en_US-lessac-medium`, `el_GR-joy-medium` |
| Prompt cache | **Cold prompt** (nonce at the start of the system prompt) is the primary result. See "warm prompt" below. |

## End-to-end, cold prompt (primary)

| Model | Lang | STT ms | LLM TTFT ms | LLM total ms | tokens (tok/s) | TTS ms | **E2E ms** |
|---|---|---:|---:|---:|---|---:|---:|
| qwen3:8b (think off) | en | 196 | 38 | 308 | 26 (97.0) | 89 | **584** |
| qwen3:8b (think off) | el | 228 | 62 | 857 | 76 (95.8) | 111 | **1198** |
| Krikri-8B-Instruct v1 Q4_K_M | en | 207 | 38 | 204 | 17 (102.7) | 81 | **492** |
| Krikri-8B-Instruct v1 Q4_K_M | el | 235 | 37 | 245 | 21 (101.8) | 133 | **620** |
| qwen2.5:14b-instruct (solo, no STT) | en | - | 64 | 552 | 28 (58.0) | 94 | 641 (excl. STT) |
| qwen2.5:14b-instruct (solo, no STT) | el | - | 105 | 2466 | 134 (56.6) | 183 | 2654 (excl. STT) |

**Warm prompt** (identical prompt every run, so Ollama reuses its prefix cache): TTFT drops to
14 ms (8B) / 22-24 ms (14B); E2E moves 2-10 % for the 8B models and 8-18 % for the 14B (mostly
reply-length variance, not caching). An earlier run without the nonce showed this
and was discarded as the primary result because it understates TTFT for a new turn.

## VRAM (nvidia-smi, total 12227 MiB; Windows desktop alone is ~1.7-2.1 GB)

| Resident set | Used MiB | LLM adds | Free MiB |
|---|---:|---:|---:|
| desktop + stt | 3092 | - | 9135 |
| desktop + stt + qwen3:8b | 8379 | +5287 | 3848 |
| desktop + stt + Krikri Q4_K_M | 8141 | +5049 | 4086 |
| desktop + qwen2.5:14b (stt stopped) | 10608 | +8747 | 1619 |

Baseline drifts ~±170 MiB between runs (desktop). An 8B model + stt leaves ~3.8-4.1 GB free; the
14B leaves 1.6 GB *without* stt, so it cannot co-reside with Whisper (~1.1-1.2 GB) inside the
10 GB budget. `stt` peak during inference: ~+130 MiB over its idle footprint.
Krikri's Modelfile sets `num_ctx 131072`; the numbers above use 4096. A client that does not
override it would allocate a far larger KV cache.

## Tool calling (Ollama tools API, `get_time`) — `bench/tool_call_test.py`, 5 runs per cell

| Model | Lang | Valid call | 2nd turn uses result | Control (no tool needed) clean |
|---|---|---:|---:|---:|
| qwen3:8b (think off) | en | 5/5 | 5/5 | 5/5 |
| qwen3:8b (think off) | el | 5/5 | 5/5 | 5/5 |
| Krikri v1 Q4_K_M | en | 5/5 | 5/5 | 5/5 |
| Krikri v1 Q4_K_M | el | **0/5** | - | 5/5 |

Krikri in Greek writes prose about the tool instead of calling it (and leaks template text such as
"Cutting Knowledge: ..."). Tested through Ollama's stock Llama-3.1 tool template; a different
template/system prompt might change this — not tried. Verdict: **qwen3:8b can be the brain;
Krikri is a Greek-language specialist, not a reliable tool caller in Greek.**

## Greek TTS voice selection (TTS -> STT round trip, 5 fresh trials per text)

Piper is stochastic, so each trial synthesizes fresh. WER is word-level vs the input text, STT
language forced to `el`.

| Voice | short (18 chars) mean WER / exact | long (201 chars) mean WER / exact | long synth ms (audio s) |
|---|---|---|---|
| el_GR-joy-medium (**default**) | 0.350 / 1 of 5 | 0.017 / 2 of 5 | 237 (16.5) |
| el_GR-rapunzelina-medium | 0.600 / 0 of 5 | 0.072 / 0 of 5 | 135 (10.5) |
| el_GR-rapunzelina-low (kept for comparison only) | 0.500 / 0 of 5 | 0.061 / 0 of 5 | 117 (10.8) |

English (`en_US-lessac-medium`): 5/5 exact on both texts. Short Greek utterances are unreliable
for *every* voice, so the cause is partly Whisper on short Greek clips (and auto-detect misfires,
seen as mk/sl) — separating TTS from STT error needs real human recordings (Step 2).

## Reproduce

```bash
# State: stop the keepalive sidecar and unload the 14B for the test session (restore afterwards!)
docker stop ollama-keepalive && ollama stop qwen2.5:14b-instruct
docker compose --profile voice up -d --no-deps stt tts       # never a bare `docker compose up`

python3 bench/tts_roundtrip.py --runs 5 --roundtrip --trials 5     # TTS timing + round trip
python3 bench/tool_call_test.py --models "qwen3:8b,hf.co/ilsp/Llama-Krikri-8B-Instruct-GGUF:Q4_K_M" --runs 5
python3 bench/voice_loop.py --models "qwen3:8b,hf.co/ilsp/Llama-Krikri-8B-Instruct-GGUF:Q4_K_M" --runs 5
python3 bench/voice_loop.py --models "qwen3:8b,hf.co/ilsp/Llama-Krikri-8B-Instruct-GGUF:Q4_K_M" --runs 5 --warm-prompt

docker compose --profile voice stop stt                      # 14B baseline: stt not resident
python3 bench/voice_loop.py --models qwen2.5:14b-instruct --runs 5 --no-stt

# Restore
docker compose --profile voice stop stt tts && docker start ollama-keepalive
ollama ps && nvidia-smi --query-gpu=memory.used,memory.free --format=csv,noheader
```

Krikri import: `ollama pull hf.co/ilsp/Llama-Krikri-8B-Instruct-GGUF:Q4_K_M` (blob sha256
`e3f93427fe0f...` matches the Hugging Face listing). Alternate Greek voice:
`TTS_VOICE_EL=el_GR-rapunzelina-medium docker compose --profile voice up -d --no-deps --force-recreate tts`.
