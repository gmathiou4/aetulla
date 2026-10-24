# CLAUDE.md — My Aetulla (repo: ~/ai-stack)

Privacy-first, fully local, voice-first AI assistant. Built on a local AI stack
(Open WebUI + Mem0 + Qdrant + Ollama + n8n) on WSL2. Skills at
`~/projects/skills/` — load on demand, not speculatively.

## Who / how to respond

DevOps/SRE/data engineer, Central Europe timezone. Greek speaker. Capable; be
direct, no padding, brutally honest. Don't repeat failed suggestions. Don't
invent facts ("I don't know" / "verify this"). Lead with the answer.
Report order: what I did → proof (command output) → what failed/uncertain →
one recommended next step.

## Vision

Anyone can run it on consumer hardware. Voice-first: you talk, it answers,
acts through tools, reports back. Fully local by default.
Constraints: STT + LLM must fit together in 12 GB VRAM; must work fully
offline with no API key.

## Build plan (10 steps)

1. **Bare voice loop** — push-to-talk → STT → local LLM → TTS; measure latency + VRAM. *(current)*
2. Greek evaluation — STT on Greek and Cretan audio, etymology accuracy. Include
   `STT_BEAM_SIZE=1` vs `5` on Greek (accuracy vs latency): beam 1 made a gender
   agreement error (ποιο/ποια) on the Piper fixture.
3. Orchestrator + model lifecycle.
4. Mem0/Qdrant memory.
5. Tools — DDGS search, n8n, allow-listed system actions with confirmation.
6. RAG over Perseus (LSJ lexicon, mythology).
7. Heavy mode — unload voice, load bigger model, reload, spoken status report, guaranteed cleanup.
8. Optional, off-by-default Claude API route via LiteLLM (anonymised brief, numbered steps only, spend cap).
9. Streaming + wake word.
10. Packaging.

## Architecture (Step 1 target)

```
Windows client (PTT hotkey, mic, playback)   <- mic can't be captured reliably in WSL
   | HTTP over localhost
   v
WSL2 / Docker Compose (project ai-stack_default)
   STT  faster-whisper large-v3-turbo (int8/int8_float16, GPU, resident)  [new]
   LLM  host Ollama :11434 (keep_alive)                                    [existing]
   TTS  Piper on CPU, one en + one el_GR voice                             [new]
```
Step 1 splits: **1a** server pipeline + WAV benchmark script (do fully first),
**1b** minimal single-file Windows PTT client.
Results go to `docs/benchmarks/step1.md` with reproducible commands.

## Environment facts (verified 2026-10-24)

- Ryzen 9800X3D, **RTX 5070 12 GB (Blackwell, sm_120, compute cap 12.0)**.
- Windows driver 621.01, CUDA UMD 13.5 (nvidia-smi 620.67.01 in WSL).
- WSL2 sees **~23 GB RAM** (not 32), 839 GB free disk.
- Ollama 0.40.10 native on host (systemd), Docker 29.9.2, Compose v5.6.1.
  Docker runtimes: runc (default), nvidia available.
- **Idle VRAM baseline is already ~11.0 / 12.2 GB** because
  `qwen2.5:14b-instruct` is held resident (keep_alive 24h via keepalive sidecar,
  ctx 4096, 9.1 GB, 100% GPU). Free VRAM ≈ 1.2 GB. Anything GPU-side needs the
  chat model swapped/unloaded or a smaller model — budget this explicitly.
- Remote: `origin https://github.com/gmathiou4/aetulla.git`; work on `voice-loop`.

### Ollama models present
qwen3:30b-a3b (18G), qwen3:14b (9.3G, planned chat upgrade), qwen2.5:14b-instruct
(chat + Mem0 fact extraction), qwen2.5:7b, qwen2.5-coder:14b, deepseek-r1:14b,
gemma4, gemma3:12b (better Greek than qwen), qwen2.5vl:7b, qwen3.5:35b-a3b (23G),
all-minilm, **nomic-embed-text** (768-dim; hard dependency of Qdrant collection
`QDRANT_COLLECTION`, `openmemory_default` unless overridden in `.env` — never
remove/swap). No Greek-tuned model (Krikri) present.

## Running services (docker-compose.yml)

All images pinned; no `:latest` in active services. Ollama is NEVER containerized.
- **open-webui** v0.9.6 — :3000 (0.0.0.0) — chat UI, RAG, DDGS web search
- **n8n** 1.74.0 — :5678 (0.0.0.0)
- **mem0** `mem0-patched:local` (Dockerfile.mem0) — 127.0.0.1:8765
- **mem0_store** qdrant v1.12.4 — 127.0.0.1:6333/6334
- **ollama-keepalive** curl sidecar, pings every 20 min (model = `LLM_MODEL`)
- **playwright** v1.58.0-noble + **web-extractor** (Trafilatura) — internal only.
  Playwright version must equal the pin in Open WebUI's requirements.txt
  (mismatch → 428 Precondition Required).
- **stt** (`aetulla-stt:local`, `stt/`) — 127.0.0.1:8010 — faster-whisper
  large-v3-turbo on GPU, compose profile `voice`, `restart: "no"`. Start ONLY via
  `docker compose --profile voice up -d --no-deps stt` (never bare `up`). ~1.1 GB
  VRAM; needs the 14B unloaded. Volumes `stt_hf`, `stt_cuda_cache` (sm_120 PTX JIT
  cache: cold start 55 s, warm 6 s). `av` must stay pinned (19.x breaks decode).
- **tts** (`aetulla-tts:local`, `tts/`) — 127.0.0.1:8020 — Piper on CPU (en + el
  voices, sha256-verified into `tts_voices`), profile `voice`, `cpus` + `TTS_THREADS`
  capped at 4. `POST /synthesize` -> WAV, timings in `X-*` headers. No GPU needed.
- **SearXNG: permanently disabled** (WSL2 bind-mount bug at runc level). Commented
  out in compose. Do not re-add or re-attempt.
- Volumes: `ai-stack_{mem0_data,n8n_data,open-webui_data,qdrant_data}`.
  (~60 anonymous volumes also exist; do not prune without asking.)

## Repo map

- `docker-compose.yml`, `.env` (secret, gitignored), `.env.example`
- `Dockerfile.mem0` + `memory.py.patched`, `config.py.patched`,
  `categorization.py.patched` (baked at build); `memory.py.original` = reference
- `setup.sh` — Full Stack installer (<=3 questions); `installer/` — host
  detection, model pulls, `seed_openwebui.py`, fixtures, `smoke_test_notes.md`
- `scripts/test-mem0.sh` (Mem0 smoke test), `bin/update*.sh` (shell functions
  sourced from ~/.bashrc), `web-extractor/` (Trafilatura), `stt/`, `tts/`,
  `bench/` (audio fixtures, `tts_roundtrip.py`), `docs/superpowers/plans/`
- Untracked cruft (stage files by name, never `git add -A`): `backups/`, `searxng/`,
  `.serena/`, `.vscode/`, `bench-*`, `*.bak.*`, `CLAUDE_TASK_*`

## Hard rules

- Don't break the existing stack. Don't modify/restart/remove existing services,
  volumes, the Qdrant collection, or nomic-embed-text without asking.
- New services join the existing Compose project. Bind ports to `127.0.0.1` only.
- Never read/print/commit `.env` or secrets. New variables go in `.env.example`.
- Plan first. Ask before anything destructive/high-blast-radius: deleting files,
  pruning images/volumes, GPU/driver changes, pulling models >10 GB.
- Verify with real command output (nvidia-smi, docker ps, logs, timings). No
  "works" claims without proof.
- If an approach fails twice: stop, report what failed and why, propose one
  alternative. Don't loop.
- Do not push without asking. Feature branches, not main.

## Conventions

- **vi only** for editing. Full-file replacements for YAML/JSON/configs — never
  partial diffs. Annotate non-obvious code inline.
- Shell aliases/functions go in `~/.bashrc`. Docker Compose baseline; pin every image.
- Technical answers: Checklist → Steps → Code → Validation; end with a
  validation command (`docker compose config`, `curl ... | jq`, ...).

## Mem0 / Qdrant quirks (already fixed — don't redo)

- Mem0 is a custom build with 3 patched files (see Repo map). `memory.py`
  (`get_default_memory_config`) and `config.py` (`get_default_configuration`,
  seeds the DB behind `/config`) are separate functions — keep both reading the
  same env vars (`EMBED_DIMS`, `QDRANT_*`, `LLM_MODEL`, `EMBED_MODEL`,
  `OLLAMA_BASE_URL`).
- Qdrant collection `openmemory_default` (or `QDRANT_COLLECTION`) is born at the `EMBED_DIMS` of first
  write; Mem0 never re-dimensions it. Wrong size → delete the empty collection.
- Live `PUT /api/v1/config/mem0/{llm,embedder}` does not survive rebuild.
- `DATABASE_URL=sqlite:////data/openmemory.db` (4 slashes) on named volume
  `mem0_data:/data`. Never single-file bind-mount (silently wiped on WSL2).
- OpenMemory 404s "User not found" for unseeded `user_id`; seed with one
  inferred write.
- `GET /api/v1/memories/` is broken upstream (500). Use
  `POST /api/v1/memories/filter`. Chat recall path is unaffected.

## Open WebUI gotchas

- Mem0 integration is a **Filter** (`inlet` recall via Qdrant `points/search`,
  `outlet` POST store); fails open.
- Newly created Functions default `is_active=0`; binding via `filterIds` does
  not enable them. `installer/seed_openwebui.py` sets `is_active=1` on insert.
- Base Ollama models can't carry a system prompt/filter; ship a custom model
  entry (`installer/fixtures/qwen_memory_model.json`).
- RAG/web-search settings are DB-authoritative once set in the UI; env only
  seeds first boot.
- `setup.sh` testing: compose uses fixed `container_name`s, so a scratch clone
  collides with the live stack. `docker compose down` (no `-v`) first, restore after.

## Known release blockers

1. README clone line uses SSH (`git@github.com:gmathiou4/ai-stack.git`) — must be
   HTTPS and the correct repo name (`aetulla`).
2. No `LICENSE` file.
3. Open WebUI (:3000) and n8n (:5678) bind to `0.0.0.0`; the public kit's default
   must be `127.0.0.1`.
4. `bin/updatedeep.sh`: `docker compose pull` will try to pull `mem0-patched:local`
   from a registry (it is a local build; needs `--ignore-buildable` / build
   instead). Its health filter greps only `open-webui|n8n|ollama-keepalive|searxng`
   — stale (SearXNG disabled; mem0, mem0_store, web-extractor, playwright
   missing). It also runs `docker system prune -f` and (via `update`)
   `apt full-upgrade` — too aggressive for a public script.
5. mem0 on main has a healthcheck the running container lacks, so any bare
   `docker compose up` (including updatedeep.sh) recreates mem0. Plan: a deliberate
   recreate later, after a Qdrant snapshot of the live collection. Not now.
6. `stt` image is 4.86 GB — slim before the public release.
7. README says "Expect 7 services" and lists models/ports that predate this plan;
   `CLAUDE.md` skills paths (`~/projects/skills/*.md`) are legacy extracts.

## Known coupling

Mem0 fact extraction uses `qwen2.5:14b-instruct` (`LLM_MODEL`). If the voice LLM
displaces it from VRAM, every memory write forces a model swap. Moving
extraction to the voice model needs re-validation first. Not acted on yet.

## Open questions / risks (Step 1)

- **Usable VRAM budget is ~10 GB, not 12** (desktop/driver overhead). A 14B chat
  model won't co-reside with Whisper. Voice LLM candidates: `qwen3:8b`,
  Llama-Krikri 8B (GGUF source TBD, ask before importing); `qwen2.5:14b-instruct`
  is a solo baseline only (measured with no STT resident).
- GPU tests: ollama-keepalive is stopped and the 14B unloaded for the duration
  of a test session only; restore both afterwards and verify with `ollama ps` +
  `nvidia-smi`. Ask before doing this outside an approved test.
- Greek TTS: `el_GR-rapunzelina-low` garbles short utterances in the TTS->STT
  round trip; `rapunzelina/medium` and `joy/medium` exist — evaluate before Step 2.
- Krikri-8B: official GGUF is v1 only (v1.5 exists, no GGUF); ask before importing.
