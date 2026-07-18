# CLAUDE.md — ~/ai-stack project

Local AI stack: Open WebUI + Mem0 + Qdrant + Ollama on WSL2.
Skills at `~/projects/skills/`. Load on demand, not speculatively.

Two shippable products live in this repo now (see "Kit + Full Stack" below):
a **Docker Compose Kit** for technical users and a **Full Stack `setup.sh`
installer** for non-technical users. Both are built on the stack described
in this file.

## Who you're working with

DevOps/SRE engineer, Central Europe timezone. WSL2 Ubuntu 24.04 on Windows 11.
Greek speaker. Personal PC: Ryzen 9800X3D + RTX 5070 + 32GB DDR5.

## How to respond — non-negotiable

- **Brutally honest.** No filler, no sugar-coating, no toxic positivity.
- **Get to the point.** Skip preamble.
- **Don't repeat failed suggestions.** If a fix doesn't work, say so and pivot.
- **Don't invent facts.** Say "I don't know" or "verify this."

## Output format

- **Technical (DevOps, infra, code):** Checklist → Steps → Code → Validation.
  Annotate non-obvious code inline. Docker Compose baseline.
- **vi only** for editing. Full-file replacements for YAML/JSON/configs. Never
  partial diffs — indentation context is invisible in chat.
- Always end with a validation command (`docker compose config`,
  `python -m json.tool`, `curl ... | jq`, `nginx -t`).

## Stack inventory — what runs here

All containers in `docker-compose.yml`. Default network `ai-stack_default`.
Ollama runs natively on the host (WSL2), reached via
`host.docker.internal:11434` — never containerize Ollama here.

- **open-webui** (ghcr.io/open-webui/open-webui:v0.9.6) — port 3000 — chat UI, RAG, web search
- **ollama** (host, not container) — port 11434 — LLM runtime
- **ollama-keepalive** — sidecar that pings Ollama every 20min to keep the chat model warm
- **mem0** (`mem0-patched:local`, built from `Dockerfile.mem0`) — port 8765 — temporal memory, OpenMemory REST API. **Not the upstream image** — 3 vendor bugs patched at build time, see below.
- **mem0_store** (qdrant/qdrant:v1.12.4) — ports 6333/6334 — vector store
- **searxng** + **searxng-redis** — **permanently disabled** (commented out in `docker-compose.yml`), broken WSL2 bind-mount at the runc level. DuckDuckGo is the active `RAG_WEB_SEARCH_ENGINE` instead. Do not re-attempt the mount without reading the compose file's comment on it first.
- **playwright** + **web-extractor** — Trafilatura page extraction for RAG. `playwright`'s version (`v1.58.0-noble`) must exactly match the `playwright` pin in Open WebUI's own `requirements.txt` — never bump one without checking the other (mismatch → `428 Precondition Required`).
- **n8n** (n8nio/n8n:1.74.0) — port 5678 — workflow automation

All images pinned to a digest or explicit version tag — no `:latest` in any
active (uncommented) service.

## Active models on host Ollama

- **qwen2.5:14b-instruct** — default chat, kept warm by keepalive
- **gemma3:12b** — multilingual fallback (better Greek than qwen)
- **qwen2.5-coder:14b** — code tasks
- **deepseek-r1:14b** — reasoning
- **qwen2.5vl:7b** — vision
- **nomic-embed-text** — RAG embeddings (768-dim, used by Mem0)

## Mem0 / Qdrant — known quirks (already fixed, don't redo)

`mem0`'s image is no longer the stock `mem0/openmemory-mcp` — it's a custom
build (`Dockerfile.mem0`, base pinned to digest) that bakes in **3 patched
files at build time** (not runtime-mounted):

- `memory.py.patched` → `/usr/src/openmemory/app/utils/memory.py` — the
  mem0-client config (`get_default_memory_config()`). Vector store dims/host,
  LLM/embedder model, all read from env (`EMBED_DIMS`, `QDRANT_HOST`,
  `QDRANT_PORT`, `QDRANT_COLLECTION`, `LLM_MODEL`, `EMBED_MODEL`,
  `OLLAMA_BASE_URL`), never hardcoded.
- `config.py.patched` → `/usr/src/openmemory/app/routers/config.py` — the
  `/config` REST API's DB-seed defaults (`get_default_configuration()`).
  **This is a separate function from `memory.py`'s** — the `/config` API
  serves from the database, not the file, so the file only seeds an *empty*
  DB. Both must stay patched and read the same env vars, or they drift.
- `categorization.py.patched` → `/usr/src/openmemory/app/utils/categorization.py`
  — upstream hardcoded a bare `OpenAI()` client with no `base_url`, so every
  inferred write threw a non-fatal `AttributeError` against real OpenAI with
  a dummy key. Repointed at Ollama's OpenAI-compatible endpoint, model from
  `LLM_MODEL`.

Other things to remember:

- Vector store collection: `openmemory_yorgos` in Qdrant at `mem0_store:6333`,
  born at whatever `EMBED_DIMS` was set to on first write. Mem0 does **not**
  re-dimension an existing collection — if it's wrong, delete the (empty)
  collection and let the next write recreate it.
- LLM + embedder config can also be pushed live via `PUT
  /api/v1/config/mem0/llm` and `PUT /api/v1/config/mem0/embedder` — this
  does NOT persist across `docker compose rm`/rebuild; the env-driven
  defaults above are what actually ships. Smoke-test script: `scripts/test-mem0.sh`.
- `DATABASE_URL=sqlite:////data/openmemory.db` — **4 slashes = absolute
  path**, backed by a **named volume on a directory** (`mem0_data:/data`).
  WSL2/Docker-Desktop single-file bind-mounts are broken at the runc level
  and silently wipe the DB on recreate — never bind-mount the DB file
  directly.
- OpenMemory does **not** auto-create users on a plain REST write — an
  unknown `user_id` 404s "User not found". `setup.sh` seeds the user via one
  inferred write; a Kit user following the README's first-run checklist does
  the same manually.
- **`GET /api/v1/memories/?user_id=...` (list_memories) is broken upstream**
  — 500s on every call (Pydantic serialization bug in vendor
  `routers/memories.py`, joins `App`/`Category` but never maps them onto the
  response fields). Not a bug in any of our patches — do not try to fix by
  touching `memory.py.patched`/`config.py.patched`/`categorization.py.patched`.
  Use `POST /api/v1/memories/filter` instead (builds `MemoryResponse`
  manually, doesn't hit it) — `scripts/test-mem0.sh` and `setup.sh` both do
  this already. The actual chat recall path is unaffected either way: the
  installed Mem0 filter's `inlet()` goes straight to Qdrant `points/search`,
  and `outlet()` is a `POST`, neither goes through the broken endpoint.

## Open WebUI Mem0 filter — gotchas

- It's a **Filter** (`inlet` recall + `outlet` store), REST not MCP. `inlet`
  embeds the query via Ollama, does a Qdrant `points/search` filtered by
  `user_id`, injects top-K `payload.data` as a system block — trust-recalled
  -facts instruction baked directly into that injected block (Option B), so
  it survives regardless of which model/system-prompt it's bound to.
  `outlet` is `POST /api/v1/memories/ {user_id, text, infer:true}`. Hooks
  fail open — never break chat on error.
- **A Function newly created via script/API defaults to `is_active=0`.**
  Binding it to a model via `filterIds` does **not** implicitly enable it —
  `utils/filter.py::get_sorted_filter_ids` excludes globally-inactive
  functions regardless of per-model binding. This bit us once already: the
  live filter existed, was bound to a model, and still never fired in chat
  because it was never toggled on after creation (confirmed via
  created_at/updated_at — not a restart/recreate artifact, just never
  flipped). `installer/seed_openwebui.py` sets `is_active=1` directly at
  insert time specifically to prevent this from ever reproducing on a fresh
  install.
- Base Ollama models can't hold a system prompt or filter binding in Open
  WebUI — only custom model entries can. Always ship a pre-made model entry
  (`installer/fixtures/qwen_memory_model.json`), never rely on the base model.

## Kit + Full Stack (installer/, setup.sh, README.md)

Two products ship from this repo:

- **Docker Compose Kit** (technical users): `git clone` → `cp .env.example
  .env` → `docker compose up -d`. See `README.md` for the full install +
  first-run checklist + troubleshooting.
- **Full Stack installer** (non-technical users): `bash setup.sh` — ≤3
  questions, detects the right `OLLAMA_BASE_URL` for the host OS, pulls
  required models, brings the stack up, seeds the OpenMemory user + the
  pre-configured memory-enabled model/filter, runs an end-to-end recall
  check, prints a green/red summary.

`installer/` layout:
- `detect_ollama_host.sh` — WSL2/macOS → `host.docker.internal`; Linux-native
  Docker ≥20.10 → same (via `extra_hosts: host-gateway`); older Engine →
  bridge gateway IP fallback.
- `pull_models.sh` — idempotent required+optional `ollama pull`. Presence
  check matches both the untagged and implicit-`:latest` forms of a model
  name (`ollama list` shows untagged pulls as `name:latest`) — exact-match
  against the bare name alone always reports a false MISSING.
- `seed_openwebui.py` + `fixtures/*.json` — seeds the Mem0 filter Function
  and the memory-enabled Model directly into `webui.db` via SQLite
  (`INSERT ... ON CONFLICT DO UPDATE`, idempotent), sidestepping the
  admin-auth bootstrap problem on a fresh install (no admin account exists
  yet, so the authenticated REST API isn't usable). Run this via `docker cp`
  + `docker exec` **inside** the `open-webui` container, not against the
  `docker inspect`-reported host volume path — on Docker Desktop
  (Mac/Windows/WSL2, this Kit's primary target) named-volume data lives
  inside Docker Desktop's own VM and isn't reachable at that path from the
  host.
- `smoke_test_notes.md` — the Playwright UI smoke test is currently
  **blocked**, not automated: the Playwright MCP tool used to drive it is
  hardcoded to the `chrome` browser channel, which needs root to install
  (`apt-get install google-chrome-stable`) and this environment has no
  passwordless sudo. The underlying functionality it would confirm (recall
  path, seeding, active function/model) is independently verified via direct
  API/DB checks instead — see that file for exactly what is and isn't
  covered, and how to finish it once the MCP browser is fixed.

`setup.sh` has no compose-level healthcheck gate for `mem0` (only
`open-webui` has one) — it polls `mem0`'s `/docs` before writing, since a
container recreate can still be mid-boot right after `docker compose up -d`
returns. If you add new post-`up` steps that hit a service other than
`open-webui`, don't assume it's ready just because the compose command
returned.

**Testing `setup.sh` locally:** its `docker-compose.yml` uses fixed
`container_name` values (`mem0`, `n8n`, `open-webui`, etc.) — running it
from *any* directory, including a scratch clone in `/tmp`, recreates those
same-named containers regardless of which checkout started them. `docker
compose down` (no `-v`) the live stack first to free the names/ports before
testing a scratch clone, then bring the live stack back up afterward —
named volumes aren't touched by `down` and reattach automatically.

## Skills — load when relevant

- `~/projects/skills/linux-environment.md` — WSL2, Ubuntu, bash, Ollama systemd,
  full Open WebUI/Trafilatura stack docs, model fleet, vi conventions
- `~/projects/skills/devops-runbook.md` — triage templates, Kafka/HANA/Redis/
  Postgres/Mongo/Cassandra commands, incident response
- `~/projects/skills/local-ai-setup.md` — Windows-side install (Ollama, WebUI,
  n8n, ComfyUI, MCP configs, NVIDIA driver checks)

These files are rough — legacy extract, not yet rewritten. Flag duplication or
stale info when you spot it.
