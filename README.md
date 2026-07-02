# ai-stack

Local, fully-offline AI stack: Open WebUI + Mem0/OpenMemory (long-term memory)
+ Qdrant (vector store) + n8n (automation) + Playwright/Trafilatura (web
extraction). Chat/embedding models run on a **native host Ollama install** —
not containerized.

## Prerequisites

- Docker + Docker Compose v2 (`docker compose version`)
- [Ollama](https://ollama.com) installed natively on the host (WSL2, Linux, or macOS)
- NVIDIA GPU + drivers strongly recommended for the 14B chat model; CPU-only works but is slow
- ~10GB disk for models, ~2GB for containers/volumes

Pull the required models before first boot:

```bash
ollama pull qwen2.5:14b-instruct
ollama pull nomic-embed-text
```

## Install

```bash
git clone git@github.com:gmathiou4/ai-stack.git
cd ai-stack
cp .env.example .env
# edit .env: set N8N_ENCRYPTION_KEY (openssl rand -hex 32), review OLLAMA_BASE_URL
docker compose up -d
```

First build compiles the patched `mem0` image (see "Mem0 patches" below) —
expect a few minutes on first run.

## Port map

| Service      | Host port (default) | Purpose                          |
|--------------|----------------------|-----------------------------------|
| open-webui   | 3000                  | Chat UI                          |
| n8n          | 5678                  | Workflow automation              |
| mem0         | 8765 (127.0.0.1 only) | OpenMemory REST API              |
| mem0_store   | 6333 / 6334 (127.0.0.1 only) | Qdrant HTTP / gRPC        |

`mem0` and `mem0_store` bind to `127.0.0.1` only — not exposed on the LAN.
Adjust in `.env` if you need remote access (and add auth in front of them
first, neither has any).

## First-run checklist

1. **Verify all containers are up:**
   ```bash
   docker compose ps
   ```
   Expect 7 services, `open-webui` shows `(healthy)`.

2. **Seed the OpenMemory user** (OpenMemory does NOT auto-create users on a
   plain REST write — a write for an unknown user 404s "User not found").
   The simplest seed is one inferred write, which also doubles as the smoke
   test in step 4.

3. **Verify the Qdrant collection came up at the right dimensionality:**
   ```bash
   curl -s http://127.0.0.1:6333/collections/${QDRANT_COLLECTION:-openmemory_yorgos} | python3 -m json.tool | grep -A2 '"vectors"'
   ```
   Expect `"size": 768` (or whatever `EMBED_DIMS` you set). If it shows the
   wrong size, your embedder model changed after the collection already
   existed — mem0 does not re-dimension an existing collection. Delete it and
   let the next write recreate it:
   ```bash
   curl -s -X DELETE http://127.0.0.1:6333/collections/${QDRANT_COLLECTION:-openmemory_yorgos}
   ```

4. **End-to-end smoke test:**
   ```bash
   bash scripts/test-mem0.sh
   ```
   Pushes LLM/embedder config, writes an inferred memory, reads it back,
   confirms the Qdrant collection exists. The write and the Qdrant-collections
   steps should succeed cleanly; the "reading memories back" step currently
   returns `Internal Server Error` — see Troubleshooting below, this is a
   known upstream bug, not a sign your install is broken.

5. **Enable memory in Open WebUI:** create/import a model with the Mem0
   filter function attached (`Workspace → Functions → Mem0 Memory`, toggle
   it **on** — this is a separate step from binding it to a model; a newly
   created function defaults to disabled and binding alone does not enable
   it). Attach the filter to a model under `Workspace → Models → [model] →
   Filters`, and turn the model's built-in Memory feature **off** (the Mem0
   filter replaces it).

## Mem0 patches

`mem0/openmemory-mcp` ships with two bugs this Kit patches at build time
(`Dockerfile.mem0` bakes 3 files into the image — see file headers for
details):

1. **Vector store misconfigured for local embeddings.** Upstream hardcodes
   OpenAI's 1536-dim embedder assumptions; patched to read
   `EMBED_DIMS`/`QDRANT_HOST`/`QDRANT_PORT`/`QDRANT_COLLECTION` from env.
2. **Two separate config layers must agree.** `memory.py`
   (`get_default_memory_config()`, the mem0-client itself) and `config.py`
   (`get_default_configuration()`, the `/config` API's DB-seed defaults) are
   independent functions — the `/config` API serves from the database, not
   the file, so the file only seeds an *empty* database. Both are patched to
   read the same `LLM_MODEL`/`EMBED_MODEL` env vars.
3. **Categorization hardcoded to OpenAI's gpt-4o-mini.** Every inferred
   write triggered a non-fatal error (`categorization.py` used a bare
   `OpenAI()` client with no base_url override, so it always hit real OpenAI
   with a dummy key). Repointed at Ollama's OpenAI-compatible endpoint.

`DATABASE_URL` uses a **4-slash** `sqlite:////data/openmemory.db` path
(`sqlite:///relative` vs `sqlite:////absolute` — three vs four slashes
matters) backed by a **named volume on a directory** — WSL2/Docker Desktop
single-file bind-mounts are broken at the runc level and silently wipe the
DB on container recreate. Never bind-mount the DB file directly.

## Troubleshooting

**`docker logs mem0` shows `AttributeError: 'Completions' object has no
attribute ...` or similar on writes.** You're running the unpatched upstream
image. Rebuild: `docker compose build --no-cache mem0 && docker compose up -d mem0`.

**Qdrant collection has the wrong vector size / writes silently fail to
embed.** See "First-run checklist" step 3 above — delete and let it recreate.

**`open-webui` can't reach `mem0`/`qdrant`/`ollama`.** All containers reach
the host via `host.docker.internal` + `extra_hosts: host.docker.internal:host-gateway`
(works on WSL2/Docker Desktop and Docker Engine ≥20.10 on Linux). Verify from
inside the container:
```bash
docker exec open-webui getent hosts host.docker.internal
docker exec open-webui python3 -c "import urllib.request; print(urllib.request.urlopen('http://mem0:8765/api/v1/config/mem0/llm', timeout=5).read())"
```

**Web search / page extraction returns `428 Precondition Required`.** The
`playwright` container's version must exactly match the `playwright` pin in
Open WebUI's own `requirements.txt` (currently `1.58.0`). Never bump one
without checking the other.

**Memory isn't recalled/stored in chat despite the backend working via
curl.** Check the Mem0 filter function is toggled **on** in
`Workspace → Functions` — a function newly created via script/API defaults
to disabled, and binding it to a model via `filterIds` does not implicitly
enable it. This is a distinct step from the model binding.

**SearXNG.** Permanently disabled in this Kit — a WSL2 bind-mount issue at
the runc level that isn't worth re-fighting. Don't attempt to re-enable the
commented-out block in `docker-compose.yml` without reading its comment
first. DuckDuckGo (`duckduckgo`, no extra service) is the active web-search
engine.

**Open WebUI RAG/web-search settings don't match what's in `.env`.** These
settings are DB-authoritative (`webui.db`) once configured via the UI — env
vars only seed first-boot defaults, they don't override an existing DB value.

**`GET /api/v1/memories/?user_id=...` (the "reading memories back" step in
`scripts/test-mem0.sh`) returns `Internal Server Error`.** This is a known bug
in the upstream `mem0/openmemory-mcp` image itself (`routers/memories.py`'s
`list_memories`), not something this Kit's patches touch or introduce:
the endpoint outer-joins `App`/`Category` for filtering but never maps the
join results onto the `app_name`/`categories` fields the `MemoryResponse`
schema expects, so Pydantic serialization fails on every call. Writes
(`POST /api/v1/memories/`) and Qdrant reads are unaffected — memory storage
and the Open WebUI chat filter's recall path both work. Only this specific
list/pagination endpoint is broken. No workaround shipped in this Kit yet;
tracked as a known limitation.
