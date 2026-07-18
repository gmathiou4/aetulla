#!/bin/bash
MEM0_USER_ID="${MEM0_USER_ID:-default_user}"

echo "=== Pushing LLM config ==="
curl -sS -X PUT http://localhost:8765/api/v1/config/mem0/llm \
  -H "Content-Type: application/json" \
  -d '{"provider":"ollama","config":{"model":"qwen2.5:14b-instruct","temperature":0.1,"max_tokens":2000,"ollama_base_url":"http://host.docker.internal:11434"}}'
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
