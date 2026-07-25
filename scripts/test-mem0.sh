#!/bin/bash
# Load .env (if present in the current directory) so LLM_MODEL/MEM0_USER_ID
# below reflect what's actually configured, not always the hardcoded
# fallback — same pattern setup.sh uses and for the same reason: pushing a
# model that isn't pulled makes mem0 block on Ollama's streaming /api/pull
# and wedges the whole container (see note below).
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

MEM0_USER_ID="${MEM0_USER_ID:-default_user}"
LLM_MODEL="${LLM_MODEL:-qwen2.5:14b-instruct}"

echo "=== Pushing LLM config (model: ${LLM_MODEL}) ==="
# Must read LLM_MODEL from env, not hardcode it — pushing a model that isn't
# already pulled makes mem0 call Ollama's /api/pull, a long-lived streaming
# endpoint. mem0's client blocks on that stream and the whole container stops
# responding to ANY request (health check included) until the pull finishes
# or it's restarted. Confirmed this wedges mem0 service-wide, not just this
# test, when LLM_MODEL was swapped to a smaller model per the README's 8GB
# RAM guidance but this script still pushed the hardcoded 14b default.
LLM_PAYLOAD=$(LLM_MODEL="$LLM_MODEL" python3 -c '
import json, os
print(json.dumps({"provider": "ollama", "config": {"model": os.environ["LLM_MODEL"], "temperature": 0.1, "max_tokens": 2000, "ollama_base_url": "http://host.docker.internal:11434"}}))
')
curl -sS -X PUT http://localhost:8765/api/v1/config/mem0/llm \
  -H "Content-Type: application/json" \
  -d "$LLM_PAYLOAD"
echo; echo

echo "=== Pushing embedder config ==="
curl -sS -X PUT http://localhost:8765/api/v1/config/mem0/embedder \
  -H "Content-Type: application/json" \
  -d '{"provider":"ollama","config":{"model":"nomic-embed-text","ollama_base_url":"http://host.docker.internal:11434"}}'
echo; echo

echo "=== Writing test memory (may take 20-40s for qwen extraction) ==="
# JSON built via python3's json.dumps, not manual string interpolation — a
# MEM0_USER_ID containing '"', '\', or other JSON-significant characters
# can't corrupt the request body.
WRITE_PAYLOAD=$(MEM0_USER_ID="$MEM0_USER_ID" python3 -c '
import json, os
print(json.dumps({"user_id": os.environ["MEM0_USER_ID"], "text": "Test user likes hiking and reads science fiction novels.", "infer": True, "app": "openwebui"}))
')
curl -sS --max-time 90 -X POST http://localhost:8765/api/v1/memories/ \
  -H "Content-Type: application/json" \
  -d "$WRITE_PAYLOAD"
echo; echo

echo "=== Reading memories back ==="
# NOTE: GET /api/v1/memories/?user_id=... (list_memories) has a known upstream
# serialization bug (500 on every call — see README Troubleshooting). POST
# /filter builds MemoryResponse objects manually and does not hit it.
FILTER_PAYLOAD=$(MEM0_USER_ID="$MEM0_USER_ID" python3 -c '
import json, os
print(json.dumps({"user_id": os.environ["MEM0_USER_ID"], "page": 1, "size": 20}))
')
curl -sS -X POST http://localhost:8765/api/v1/memories/filter \
  -H "Content-Type: application/json" \
  -d "$FILTER_PAYLOAD"
echo; echo

echo "=== Qdrant collections (should contain openmemory_default) ==="
curl -sS http://localhost:6333/collections
echo
