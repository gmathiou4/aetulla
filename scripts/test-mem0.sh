#!/bin/bash
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
curl -sS --max-time 90 -X POST http://localhost:8765/api/v1/memories/ \
  -H "Content-Type: application/json" \
  -d '{"user_id":"default_user","text":"Test user likes hiking and reads science fiction novels.","infer":true,"app":"openwebui"}'
echo; echo

echo "=== Reading memories back ==="
# NOTE: GET /api/v1/memories/?user_id=... (list_memories) has a known upstream
# serialization bug (500 on every call — see README Troubleshooting). POST
# /filter builds MemoryResponse objects manually and does not hit it.
curl -sS -X POST http://localhost:8765/api/v1/memories/filter \
  -H "Content-Type: application/json" \
  -d '{"user_id":"default_user","page":1,"size":20}'
echo; echo

echo "=== Qdrant collections (should contain openmemory_default) ==="
curl -sS http://localhost:6333/collections
echo
