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


def load_fixture(name: str) -> dict:
    with open(FIXTURES_DIR / name) as f:
        return json.load(f)


def seed_function(con: sqlite3.Connection, fixture: dict):
    now = int(time.time())
    con.execute(
        """
        INSERT INTO function (id, user_id, name, type, content, meta, is_active, is_global, updated_at, created_at)
        VALUES (?, ?, ?, ?, ?, ?, 1, 0, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            content=excluded.content, meta=excluded.meta, is_active=1, updated_at=excluded.updated_at
        """,
        (
            fixture["id"],
            "system",
            fixture["name"],
            fixture["type"],
            fixture["content"],
            json.dumps(fixture.get("meta", {})),
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
    args = parser.parse_args()

    if not Path(args.db).exists():
        print(f"ERROR: {args.db} does not exist — has open-webui started at least once?", file=sys.stderr)
        sys.exit(1)

    con = sqlite3.connect(args.db)
    try:
        function_fixture = load_fixture("mem0_memory_function.json")
        model_fixture = load_fixture("qwen_memory_model.json")

        seed_function(con, function_fixture)
        seed_model(con, model_fixture, args.llm_model)
        con.commit()

        cur = con.execute("SELECT id, is_active FROM function WHERE id=?", (function_fixture["id"],))
        print("function:", cur.fetchone())
        cur = con.execute("SELECT id, base_model_id, is_active FROM model WHERE id=?", (model_fixture["id"],))
        print("model:", cur.fetchone())
    finally:
        con.close()


if __name__ == "__main__":
    main()
