#!/usr/bin/env python3
"""
Seed Open WebUI's webui.db with the Mem0 filter function and a
memory-enabled model entry, on a fresh install where no admin account
exists yet (so the authenticated REST API isn't usable).

Idempotent: safe to re-run, uses INSERT OR REPLACE keyed on id.

Usage: python3 seed_openwebui.py --db /path/to/webui.db --llm-model qwen2.5:14b-instruct
"""
import argparse
import json
import sqlite3
import sys
import time
from pathlib import Path

FIXTURES_DIR = Path(__file__).parent / "fixtures"

# mem0/mem0_store are always reachable by their compose service name from
# any container on the ai-stack_default network, regardless of host OS —
# unlike host.docker.internal (which the fixture's Valve class defaults use
# as a *fallback*), this needs no OS detection and works identically on
# WSL2/Docker Desktop/macOS/native Linux, and doesn't depend on the mem0/
# mem0_store ports being reachable via the host network stack at all.
MEM0_CONTAINER_URL = "http://mem0:8765"
QDRANT_CONTAINER_URL = "http://mem0_store:6333"


def load_fixture(name: str) -> dict:
    with open(FIXTURES_DIR / name) as f:
        return json.load(f)


def seed_function(con: sqlite3.Connection, fixture: dict, valves: dict):
    now = int(time.time())
    con.execute(
        """
        INSERT INTO function (id, user_id, name, type, content, meta, valves, is_active, is_global, updated_at, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, 1, 0, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            content=excluded.content, meta=excluded.meta, valves=excluded.valves,
            is_active=1, updated_at=excluded.updated_at
        """,
        (
            fixture["id"],
            "system",
            fixture["name"],
            fixture["type"],
            fixture["content"],
            json.dumps(fixture.get("meta", {})),
            json.dumps(valves),
            now,
            now,
        ),
    )


def seed_model(con: sqlite3.Connection, fixture: dict, llm_model: str):
    now = int(time.time())
    fixture["base_model_id"] = llm_model
    con.execute(
        """
        INSERT INTO model (id, user_id, base_model_id, name, params, meta, is_active, updated_at, created_at)
        VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            base_model_id=excluded.base_model_id, params=excluded.params, meta=excluded.meta,
            is_active=1, updated_at=excluded.updated_at
        """,
        (
            fixture["id"],
            "system",
            fixture["base_model_id"],
            fixture["name"],
            json.dumps(fixture.get("params", {})),
            json.dumps(fixture.get("meta", {})),
            now,
            now,
        ),
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", required=True, help="Path to webui.db")
    parser.add_argument("--llm-model", required=True, help="Chat model id to bind (e.g. qwen2.5:14b-instruct)")
    parser.add_argument("--mem0-user-id", default="yorgos", help="OpenMemory user_id namespace (must match mem0's MEM0_USER_ID)")
    parser.add_argument("--qdrant-collection", default="openmemory_yorgos", help="Qdrant collection (must match mem0's QDRANT_COLLECTION)")
    parser.add_argument("--embed-model", default="nomic-embed-text", help="Embedding model (must match mem0's EMBED_MODEL)")
    parser.add_argument("--ollama-url", default="http://host.docker.internal:11434", help="Ollama base URL reachable from inside open-webui (must match OLLAMA_BASE_URL)")
    args = parser.parse_args()

    if not Path(args.db).exists():
        print(f"ERROR: {args.db} does not exist — has open-webui started at least once?", file=sys.stderr)
        sys.exit(1)

    con = sqlite3.connect(args.db)
    try:
        function_fixture = load_fixture("mem0_memory_function.json")
        model_fixture = load_fixture("qwen_memory_model.json")

        # Overrides the Filter's Pydantic Valves() class defaults at runtime
        # (Open WebUI does `Valves(**valves_db)` — see utils/filter.py) so the
        # actually-running filter reflects the resolved .env config, not the
        # fixture's hardcoded "yorgos"/"openmemory_yorgos"/"host.docker.internal"
        # source-code defaults. Without this, changing MEM0_USER_ID/
        # QDRANT_COLLECTION/EMBED_MODEL/OLLAMA_BASE_URL in .env has no effect
        # on the chat-time recall/store path — only on mem0's own config and
        # this script's caller's own self-test.
        valves = {
            "user_id": args.mem0_user_id,
            "openmemory_url": MEM0_CONTAINER_URL,
            "qdrant_url": QDRANT_CONTAINER_URL,
            "ollama_url": args.ollama_url,
            "collection": args.qdrant_collection,
            "embed_model": args.embed_model,
        }

        seed_function(con, function_fixture, valves)
        seed_model(con, model_fixture, args.llm_model)
        con.commit()

        cur = con.execute("SELECT id, is_active, valves FROM function WHERE id=?", (function_fixture["id"],))
        print("function:", cur.fetchone())
        cur = con.execute("SELECT id, base_model_id, is_active FROM model WHERE id=?", (model_fixture["id"],))
        print("model:", cur.fetchone())
    finally:
        con.close()


if __name__ == "__main__":
    main()
