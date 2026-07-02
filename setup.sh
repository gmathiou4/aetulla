#!/usr/bin/env bash
# One-shot installer: ≤3 questions -> .env -> models -> stack up -> seed ->
# verify -> smoke test -> green/red summary.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}✓${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1"; }
warn() { echo -e "${YELLOW}!${NC} $1"; }

STATUS_OK=1

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || { fail "$1 not found on PATH"; exit 1; }
}
require_cmd docker
require_cmd ollama
require_cmd python3

echo "=== ai-stack setup ==="
echo ""

# No controlling terminal (e.g. piped/CI/unattended run): skip prompts and
# take every default rather than let `read` hit EOF, which under `set -e`
# would kill the script before printing anything useful.
if [[ -t 0 ]]; then
    # ── Question 1/3: user id ───────────────────────────────────────────
    read -r -p "Memory namespace / username [yorgos]: " MEM0_USER_ID

    # ── Question 2/3: timezone ──────────────────────────────────────────
    DEFAULT_TZ=$(cat /etc/timezone 2>/dev/null || echo "Europe/Prague")
    read -r -p "Timezone [${DEFAULT_TZ}]: " TZ_INPUT

    # ── Question 3/3: optional models ────────────────────────────────────
    read -r -p "Pull optional models (coder, reasoning)? [y/N] " PULL_OPT_REPLY
else
    warn "No interactive terminal detected — using defaults for all prompts."
    DEFAULT_TZ=$(cat /etc/timezone 2>/dev/null || echo "Europe/Prague")
    MEM0_USER_ID=""
    TZ_INPUT=""
    PULL_OPT_REPLY=""
fi

MEM0_USER_ID="${MEM0_USER_ID:-yorgos}"
TZ_VALUE="${TZ_INPUT:-$DEFAULT_TZ}"
if [[ "$PULL_OPT_REPLY" =~ ^[Yy]$ ]]; then
    export PULL_OPTIONAL=all
else
    export PULL_OPTIONAL=none
fi

echo ""
echo "=== [1/6] Detecting Ollama host URL ==="
OLLAMA_BASE_URL=$(bash installer/detect_ollama_host.sh)
ok "OLLAMA_BASE_URL=${OLLAMA_BASE_URL}"

echo ""
echo "=== [2/6] Writing .env ==="
if [[ -f .env ]]; then
    warn ".env already exists, backing up to .env.bak.$(date +%s)"
    cp .env ".env.bak.$(date +%s)"
fi
cp .env.example .env
N8N_KEY=$(openssl rand -hex 32)
# Values are passed via the environment, never string-interpolated into the
# Python source, and matched by plain prefix (no regex, no sed delimiter) —
# a username/timezone containing '#', '/', or any other sed/regex
# metacharacter can't corrupt the substitution or break the script.
OLLAMA_BASE_URL="$OLLAMA_BASE_URL" MEM0_USER_ID="$MEM0_USER_ID" TZ_VALUE="$TZ_VALUE" N8N_KEY="$N8N_KEY" python3 <<'PYEOF'
import os

replacements = {
    "OLLAMA_BASE_URL": os.environ["OLLAMA_BASE_URL"],
    "MEM0_USER_ID": os.environ["MEM0_USER_ID"],
    "TZ": os.environ["TZ_VALUE"],
    "N8N_ENCRYPTION_KEY": os.environ["N8N_KEY"],
}

with open(".env") as f:
    lines = f.readlines()

out = []
for line in lines:
    stripped = line.rstrip("\n")
    matched = False
    for key, value in replacements.items():
        if stripped.startswith(f"{key}="):
            out.append(f"{key}={value}\n")
            matched = True
            break
    if not matched:
        out.append(line)

with open(".env", "w") as f:
    f.writelines(out)
PYEOF
ok ".env written"

# Load the resolved .env values into this shell so every later reference to
# ${QDRANT_COLLECTION:-...}/${EMBED_MODEL:-...}/etc. reflects what's actually
# configured instead of always silently falling back to the hardcoded
# default (which is exactly what was happening before — none of these were
# ever sourced from .env, so a customized .env had no effect on this script).
set -a
# shellcheck disable=SC1091
source .env
set +a

echo ""
echo "=== [3/6] Pulling models ==="
bash installer/pull_models.sh

echo ""
echo "=== [4/6] Bringing stack up ==="
docker compose up -d --build
echo "Waiting for open-webui health check..."
for i in $(seq 1 30); do
    status=$(docker inspect --format '{{.State.Health.Status}}' open-webui 2>/dev/null || echo "starting")
    [[ "$status" == "healthy" ]] && break
    sleep 2
done
if [[ "$status" == "healthy" ]]; then
    ok "open-webui healthy"
else
    fail "open-webui did not become healthy in time (last status: ${status})"
    STATUS_OK=0
fi

echo ""
echo "=== [5/6] Seeding OpenMemory user + Open WebUI model/function ==="
# mem0 has no compose-level healthcheck (only open-webui does) — on a
# container recreate it can still be booting Uvicorn right after
# `docker compose up -d` returns. Wait for it to accept connections before
# writing, or the seed write races a connection reset.
echo "Waiting for mem0 to accept connections..."
for i in $(seq 1 30); do
    if curl -sS --max-time 2 "http://localhost:${MEM0_PORT:-8765}/docs" >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

# seed OpenMemory user via one inferred write (also primes the smoke test data)
SEED_TEXT="Setup smoke-test fact: this user's memory namespace is ${MEM0_USER_ID}."
# JSON built via python3's json.dumps, not manual string interpolation —
# a username containing '"', '\', or other JSON-significant characters
# can't corrupt the request body.
SEED_PAYLOAD=$(MEM0_USER_ID="$MEM0_USER_ID" SEED_TEXT="$SEED_TEXT" python3 -c '
import json, os
print(json.dumps({"user_id": os.environ["MEM0_USER_ID"], "text": os.environ["SEED_TEXT"], "infer": True}))
')
if curl -sS --max-time 90 -X POST "http://localhost:${MEM0_PORT:-8765}/api/v1/memories/" \
    -H "Content-Type: application/json" \
    -d "$SEED_PAYLOAD" > /tmp/seed_write.json 2>&1; then
    ok "OpenMemory user seeded via inferred write"
else
    fail "OpenMemory seed write failed — see /tmp/seed_write.json"
    STATUS_OK=0
fi

# Run the seed script inside the open-webui container itself rather than
# against the named volume's host path. On Docker Desktop (Mac/Windows/WSL2 —
# this Kit's primary target), volume data lives inside Docker Desktop's own
# VM and is not reachable at the `docker inspect`-reported path from the
# host; docker cp + docker exec works identically on every backend.
docker cp installer/seed_openwebui.py open-webui:/tmp/seed_openwebui.py
docker cp installer/fixtures open-webui:/tmp/fixtures
# Pass the resolved config through as the seeded Filter's Valve overrides
# (see seed_openwebui.py) — without this, the wizard's namespace question
# and any .env customization of QDRANT_COLLECTION/EMBED_MODEL would have no
# effect on the actual chat-time recall/store path, only on this script's
# own self-test below.
if docker exec open-webui python3 /tmp/seed_openwebui.py \
    --db /app/backend/data/webui.db \
    --llm-model "${LLM_MODEL:-qwen2.5:14b-instruct}" \
    --mem0-user-id "${MEM0_USER_ID}" \
    --qdrant-collection "${QDRANT_COLLECTION:-openmemory_yorgos}" \
    --embed-model "${EMBED_MODEL:-nomic-embed-text}" \
    --ollama-url "${OLLAMA_BASE_URL}"; then
    ok "Open WebUI model + Mem0 filter function seeded (active)"
else
    fail "Open WebUI seeding failed"
    STATUS_OK=0
fi

echo ""
echo "=== [6/6] Verifying 768-dim collection + end-to-end recall ==="
COLLECTION="${QDRANT_COLLECTION:-openmemory_yorgos}"
DIMS=$(curl -s "http://localhost:${QDRANT_HTTP_PORT:-6333}/collections/${COLLECTION}" | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['config']['params']['vectors']['size'])" 2>/dev/null || echo "ERR")
if [[ "$DIMS" == "${EMBED_DIMS:-768}" ]]; then
    ok "Qdrant collection '${COLLECTION}' at ${DIMS} dims"
else
    fail "Qdrant collection dims mismatch (got '${DIMS}', expected ${EMBED_DIMS:-768})"
    STATUS_OK=0
fi

sleep 3  # let the inferred write from step 5 finish embedding
# NOTE: GET /api/v1/memories/ (list_memories) has a known upstream serialization
# bug (500 on every call — see README Troubleshooting). POST /filter builds
# MemoryResponse objects manually and does not hit it; same fix as
# scripts/test-mem0.sh.
RECALL_PAYLOAD=$(MEM0_USER_ID="$MEM0_USER_ID" python3 -c '
import json, os
print(json.dumps({"user_id": os.environ["MEM0_USER_ID"], "page": 1, "size": 5}))
')
RECALL=$(curl -s -X POST "http://localhost:${MEM0_PORT:-8765}/api/v1/memories/filter" \
    -H "Content-Type: application/json" \
    -d "$RECALL_PAYLOAD" || echo "ERR")
if echo "$RECALL" | grep -qF -- "${MEM0_USER_ID}"; then
    ok "End-to-end recall check passed"
else
    fail "Recall check found no memories for ${MEM0_USER_ID}"
    STATUS_OK=0
fi

echo ""
echo "======================================"
if [[ "$STATUS_OK" -eq 1 ]]; then
    echo -e "${GREEN}✅ Setup complete.${NC} Open http://localhost:${OPEN_WEBUI_PORT:-3000}, log in (first account = admin), select the memory-enabled model."
else
    echo -e "${RED}❌ Setup finished with errors — see above.${NC}"
    exit 1
fi
