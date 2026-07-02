# Kit + Full Stack Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship two products from the working local AI stack at `~/ai-stack/`: (1) a **Docker Compose Kit** for technical users (`git clone` → `.env` → `up -d`), and (2) a **Full Stack installer** for non-technical users (one script → working memory-enabled Open WebUI).

**Architecture:** No new services. Product 1 hardens what's already running (pin images, externalize config, fix the categorization bug, document it). Product 2 is a thin automation layer on top of Product 1 (OS detection, model pulls, `.env` generation, DB-level seeding of the user/model/function, an end-to-end smoke test).

**Tech Stack:** Docker Compose, Python 3.12 (mem0/OpenMemory patches), Bash (installer scripts), SQLite (Open WebUI's `webui.db`, OpenMemory's `openmemory.db`), Qdrant REST, Ollama REST/OpenAI-compat API.

## Global Constraints

- Full-file replacements only for YAML/JSON/Dockerfile/.env/systemd/Python (indentation-sensitive) — no partial diffs.
- Every image pinned to a digest or explicit version tag. No `:latest` anywhere in shipped artifacts.
- Env-driven over hardcoded: a Kit user changes behavior via `.env`, never by editing Python.
- One logical change per commit, message explains *why*.
- Ask before destructive actions (deleting volumes, dropping Qdrant collections).
- Verify against the live system before assuming — the running containers are ground truth.
- Never reintroduce a §3 gotcha from `CLAUDE_TASK_kit-and-fullstack.md` (referenced inline per task below).

---

## Task 0: Re-enable Mem0 filter + document root cause — DONE (pre-plan)

**Status:** Already executed live during the READ phase, ahead of this plan, per explicit user instruction.

**What happened:** `function.is_active` for `mem0_memory` in `open-webui`'s `webui.db` was `0`. Traced Open WebUI's `utils/filter.py::get_sorted_filter_ids` — it intersects a model's `filterIds` against `Functions.get_functions_by_type('filter', active_only=True)`; a globally-inactive function is excluded regardless of per-model binding. So recall/store were not firing on chat turns despite the model being configured correctly.

**Root cause (not a regression):** `function.created_at = 2026-06-22T19:24:39Z`, `model.created_at = 2026-06-22T19:44:49Z`, `function.updated_at = 2026-06-22T19:47:24Z`. All three events cluster in a single ~23-minute window nine days before this session. Today's container (`Created: 2026-07-01T19:30:09Z`, `RestartCount: 0`) inherited `is_active=0` unchanged from the persisted `open-webui_data` volume — there is no recreate/restart between 06-22 and today that could have flipped it. `Function.is_active` defaults to `False` in Open WebUI's schema (`models/functions.py:28`) on every `create`. Conclusion: the function was created via API/script, the model was bound to it via `filterIds`, but the separate `POST /functions/id/{id}/toggle` call (or UI checkbox) was never made. It was never turned on — not turned off. This is the exact "checkbox hunting" gap Product 2 (§5) already targets.

**Fix applied:**
```bash
docker exec open-webui python3 -c "
import sqlite3
con = sqlite3.connect('/app/backend/data/webui.db')
cur = con.cursor()
cur.execute(\"UPDATE function SET is_active=1 WHERE id='mem0_memory'\")
con.commit()
cur.execute(\"SELECT id, is_active FROM function WHERE id='mem0_memory'\")
print(cur.fetchone())
"
```
Verified: `('mem0_memory', 1)`. No restart needed — `get_sorted_filter_ids` queries the DB per-request.

**Follow-up validation (fold into Task 15 review):** After Task 10 ships the automated model+function seeding for Product 2, confirm the seeding script explicitly sets `is_active=1` (or calls the toggle endpoint) so a fresh Full Stack install never reproduces this gap. This is why Task 10 below seeds `is_active=1` directly rather than relying on a post-creation toggle step.

---

## Phase 1 — Product 1: Docker Compose Kit

### Task 1: Fix categorization.py — repoint off hardcoded `gpt-4o-mini`

**Files:**
- Create: `categorization.py.patched` (repo root, alongside `memory.py.patched` / `config.py.patched`)
- Modify: `Dockerfile.mem0` (3rd `COPY`, done together with Task 3 to avoid a broken intermediate build)

**Root problem (§3 gotcha #4):** `/usr/src/openmemory/app/utils/categorization.py` does `openai_client = OpenAI()` (talks to real OpenAI, no base_url override) and hardcodes `model="gpt-4o-mini"` in a beta `.with_response_format(...).create(...)` call. With `OPENAI_API_KEY=ollama-dummy`, every inferred write's categorization pass throws (non-fatal, memory store still succeeds, but it's log noise and wasted retries).

**Design decision:** Point the `OpenAI` client's `base_url` at Ollama's OpenAI-compatible endpoint (`{OLLAMA_BASE_URL}/v1`) and read the model from a new `LLM_MODEL` env var (same one used by Task 2's `memory.py`/`config.py` patches, so one env var controls the chat model everywhere). Replace the beta `.with_response_format()` helper — not reliably supported against non-OpenAI backends — with a plain `chat.completions.create(response_format={"type": "json_object"})` call, and parse the JSON manually into the existing `MemoryCategories` pydantic model, stripping markdown code fences defensively in case the model wraps its JSON.

- [ ] **Step 1: Write `categorization.py.patched`**

```python
"""
Category extraction for OpenMemory memories.

Patched: originally hardcoded OpenAI's gpt-4o-mini via a bare OpenAI() client
(no base_url override), which throws against OPENAI_API_KEY=ollama-dummy on
every inferred write (non-fatal, but noisy). This patch points the OpenAI SDK
client at Ollama's OpenAI-compatible endpoint and reads the model from
LLM_MODEL, matching the memory.py/config.py patches so one env var controls
the chat model everywhere.
"""

import logging
import os
from typing import List

from dotenv import load_dotenv
from openai import OpenAI
from pydantic import BaseModel
from tenacity import retry, stop_after_attempt, wait_exponential
from app.utils.prompts import MEMORY_CATEGORIZATION_PROMPT

load_dotenv()

_ollama_base_url = os.environ.get("OLLAMA_BASE_URL", "http://host.docker.internal:11434")
openai_client = OpenAI(
    base_url=f"{_ollama_base_url.rstrip('/')}/v1",
    api_key=os.environ.get("OPENAI_API_KEY", "ollama-dummy"),
)
_categorization_model = os.environ.get("LLM_MODEL", "qwen2.5:14b-instruct")

_JSON_INSTRUCTION = (
    "\n\nRespond with a single JSON object of the form "
    '{"categories": ["category1", "category2"]} and nothing else.'
)


class MemoryCategories(BaseModel):
    categories: List[str]


def _strip_code_fence(raw: str) -> str:
    raw = raw.strip()
    if raw.startswith("```"):
        raw = raw.strip("`")
        if raw.lower().startswith("json"):
            raw = raw[4:]
    return raw.strip()


@retry(stop=stop_after_attempt(3), wait=wait_exponential(multiplier=1, min=4, max=15))
def get_categories_for_memory(memory: str) -> List[str]:
    completion = None
    try:
        messages = [
            {"role": "system", "content": MEMORY_CATEGORIZATION_PROMPT + _JSON_INSTRUCTION},
            {"role": "user", "content": memory},
        ]

        completion = openai_client.chat.completions.create(
            model=_categorization_model,
            messages=messages,
            temperature=0,
            response_format={"type": "json_object"},
        )

        raw = completion.choices[0].message.content
        parsed = MemoryCategories.model_validate_json(_strip_code_fence(raw))
        return [cat.strip().lower() for cat in parsed.categories]

    except Exception as e:
        logging.error(f"[ERROR] Failed to get categories: {e}")
        if completion is not None:
            try:
                logging.debug(f"[DEBUG] Raw response: {completion.choices[0].message.content}")
            except Exception as debug_e:
                logging.debug(f"[DEBUG] Could not extract raw response: {debug_e}")
        raise
```

- [ ] **Step 2: `response_format: json_object` support — confirmed live (2026-07-01), no fallback needed**

Tested against the installed `qwen2.5:14b-instruct` via Ollama's OpenAI-compat endpoint:
```
POST http://127.0.0.1:11434/v1/chat/completions
{"model":"qwen2.5:14b-instruct","messages":[...],"response_format":{"type":"json_object"}}
→ content: '{\n  "message": "hi",\n  "categories": ["test"]\n}'
→ json.loads(content) succeeds
```
The model added an extra `"message"` key the prompt didn't ask for — harmless, since `MemoryCategories.model_validate_json(...)` (pydantic v2, default `extra="ignore"`) drops unrecognized fields rather than rejecting them. The implementation in Step 1 is validated as written; no `response_format`-fallback branch is needed.

- [ ] **Step 3: Commit (bundled with Task 3, since Dockerfile.mem0 must add the 3rd COPY in the same logical change)**

---

### Task 2: Externalize hardcoded model/dims in `memory.py.patched` and `config.py.patched`

**Files:**
- Modify (full-file replace): `memory.py.patched`
- Modify (full-file replace): `config.py.patched`

**Provides:** three new env vars — `LLM_MODEL` (default `qwen2.5:14b-instruct`), `EMBED_MODEL` (default `nomic-embed-text`), `EMBED_DIMS` (default `768`) — consumed by Task 1 (categorization), Task 5 (compose), Task 6 (`.env.example`).

**Depends on:** none (first code change in the chain; Task 3's Dockerfile COPY order doesn't matter since all three files are copied independently).

- [ ] **Step 1: Rewrite `memory.py.patched`** — only `get_default_memory_config()` changes; everything else (Docker-host resolution, `get_memory_client`, etc.) is unchanged from the current file.

```python
"""
Memory client utilities for OpenMemory.

This module provides functionality to initialize and manage the Mem0 memory client
with automatic configuration management and Docker environment support.

Docker Ollama Configuration:
When running inside a Docker container and using Ollama as the LLM or embedder provider,
the system automatically detects the Docker environment and adjusts localhost URLs
to properly reach the host machine where Ollama is running.

Supported Docker host resolution (in order of preference):
1. OLLAMA_HOST environment variable (if set)
2. host.docker.internal (Docker Desktop for Mac/Windows)
3. Docker bridge gateway IP (typically 172.17.0.1 on Linux)
4. Fallback to 172.17.0.1

Example configuration that will be automatically adjusted:
{
    "llm": {
        "provider": "ollama",
        "config": {
            "model": "llama3.1:latest",
            "ollama_base_url": "http://localhost:11434"  # Auto-adjusted in Docker
        }
    }
}
"""

import os
import json
import hashlib
import socket
import platform

from mem0 import Memory
from app.database import SessionLocal
from app.models import Config as ConfigModel


_memory_client = None
_config_hash = None


def _get_config_hash(config_dict):
    """Generate a hash of the config to detect changes."""
    config_str = json.dumps(config_dict, sort_keys=True)
    return hashlib.md5(config_str.encode()).hexdigest()


def _get_docker_host_url():
    """
    Determine the appropriate host URL to reach host machine from inside Docker container.
    Returns the best available option for reaching the host from inside a container.
    """
    # Check for custom environment variable first
    custom_host = os.environ.get('OLLAMA_HOST')
    if custom_host:
        print(f"Using custom Ollama host from OLLAMA_HOST: {custom_host}")
        return custom_host.replace('http://', '').replace('https://', '').split(':')[0]

    # Check if we're running inside Docker
    if not os.path.exists('/.dockerenv'):
        # Not in Docker, return localhost as-is
        return "localhost"

    print("Detected Docker environment, adjusting host URL for Ollama...")

    # Try different host resolution strategies
    host_candidates = []

    # 1. host.docker.internal (works on Docker Desktop for Mac/Windows)
    try:
        socket.gethostbyname('host.docker.internal')
        host_candidates.append('host.docker.internal')
        print("Found host.docker.internal")
    except socket.gaierror:
        pass

    # 2. Docker bridge gateway (typically 172.17.0.1 on Linux)
    try:
        with open('/proc/net/route', 'r') as f:
            for line in f:
                fields = line.strip().split()
                if fields[1] == '00000000':  # Default route
                    gateway_hex = fields[2]
                    gateway_ip = socket.inet_ntoa(bytes.fromhex(gateway_hex)[::-1])
                    host_candidates.append(gateway_ip)
                    print(f"Found Docker gateway: {gateway_ip}")
                    break
    except (FileNotFoundError, IndexError, ValueError):
        pass

    # 3. Fallback to common Docker bridge IP
    if not host_candidates:
        host_candidates.append('172.17.0.1')
        print("Using fallback Docker bridge IP: 172.17.0.1")

    # Return the first available candidate
    return host_candidates[0]


def _fix_ollama_urls(config_section):
    """
    Fix Ollama URLs for Docker environment.
    Replaces localhost URLs with appropriate Docker host URLs.
    Sets default ollama_base_url if not provided.
    """
    if not config_section or "config" not in config_section:
        return config_section

    ollama_config = config_section["config"]

    # Set default ollama_base_url if not provided
    if "ollama_base_url" not in ollama_config:
        ollama_config["ollama_base_url"] = "http://host.docker.internal:11434"
    else:
        # Check for ollama_base_url and fix if it's localhost
        url = ollama_config["ollama_base_url"]
        if "localhost" in url or "127.0.0.1" in url:
            docker_host = _get_docker_host_url()
            if docker_host != "localhost":
                new_url = url.replace("localhost", docker_host).replace("127.0.0.1", docker_host)
                ollama_config["ollama_base_url"] = new_url
                print(f"Adjusted Ollama URL from {url} to {new_url}")

    return config_section


def reset_memory_client():
    """Reset the global memory client to force reinitialization with new config."""
    global _memory_client, _config_hash
    _memory_client = None
    _config_hash = None


def get_default_memory_config():
    """Get default memory client configuration with sensible defaults.

    All values below are env-overridable so a Kit user configures behavior via
    .env, never by editing this file:
      QDRANT_COLLECTION, QDRANT_HOST, QDRANT_PORT, EMBED_DIMS, LLM_MODEL,
      EMBED_MODEL, OLLAMA_BASE_URL.
    """
    return {
        "vector_store": {
            "provider": "qdrant",
            "config": {
                "collection_name": os.environ.get("QDRANT_COLLECTION", "openmemory"),
                "host": os.environ.get("QDRANT_HOST", "mem0_store"),
                "port": int(os.environ.get("QDRANT_PORT", "6333")),
                "embedding_model_dims": int(os.environ.get("EMBED_DIMS", "768")),
            }
        },
        "llm": {
            "provider": "ollama",                      # local, not openai
            "config": {
                "model": os.environ.get("LLM_MODEL", "qwen2.5:14b-instruct"),
                "temperature": 0.1,
                "max_tokens": 2000,
                "ollama_base_url": os.environ.get("OLLAMA_BASE_URL", "http://host.docker.internal:11434"),
            }
        },
        "embedder": {
            "provider": "ollama",                      # local, not openai
            "config": {
                "model": os.environ.get("EMBED_MODEL", "nomic-embed-text"),
                "ollama_base_url": os.environ.get("OLLAMA_BASE_URL", "http://host.docker.internal:11434"),
            }
        },
        "version": "v1.1"
    }

def _parse_environment_variables(config_dict):
    """
    Parse environment variables in config values.
    Converts 'env:VARIABLE_NAME' to actual environment variable values.
    """
    if isinstance(config_dict, dict):
        parsed_config = {}
        for key, value in config_dict.items():
            if isinstance(value, str) and value.startswith("env:"):
                env_var = value.split(":", 1)[1]
                env_value = os.environ.get(env_var)
                if env_value:
                    parsed_config[key] = env_value
                    print(f"Loaded {env_var} from environment for {key}")
                else:
                    print(f"Warning: Environment variable {env_var} not found, keeping original value")
                    parsed_config[key] = value
            elif isinstance(value, dict):
                parsed_config[key] = _parse_environment_variables(value)
            else:
                parsed_config[key] = value
        return parsed_config
    return config_dict


def get_memory_client(custom_instructions: str = None):
    """
    Get or initialize the Mem0 client.

    Args:
        custom_instructions: Optional instructions for the memory project.

    Returns:
        Initialized Mem0 client instance or None if initialization fails.

    Raises:
        Exception: If required API keys are not set or critical configuration is missing.
    """
    global _memory_client, _config_hash

    try:
        # Start with default configuration
        config = get_default_memory_config()

        # Variable to track custom instructions
        db_custom_instructions = None

        # Load configuration from database
        try:
            db = SessionLocal()
            db_config = db.query(ConfigModel).filter(ConfigModel.key == "main").first()

            if db_config:
                json_config = db_config.value

                # Extract custom instructions from openmemory settings
                if "openmemory" in json_config and "custom_instructions" in json_config["openmemory"]:
                    db_custom_instructions = json_config["openmemory"]["custom_instructions"]

                # Override defaults with configurations from the database
                if "mem0" in json_config:
                    mem0_config = json_config["mem0"]

                    # Update LLM configuration if available
                    if "llm" in mem0_config and mem0_config["llm"] is not None:
                        config["llm"] = mem0_config["llm"]

                        # Fix Ollama URLs for Docker if needed
                        if config["llm"].get("provider") == "ollama":
                            config["llm"] = _fix_ollama_urls(config["llm"])

                    # Update Embedder configuration if available
                    if "embedder" in mem0_config and mem0_config["embedder"] is not None:
                        config["embedder"] = mem0_config["embedder"]

                        # Fix Ollama URLs for Docker if needed
                        if config["embedder"].get("provider") == "ollama":
                            config["embedder"] = _fix_ollama_urls(config["embedder"])
            else:
                print("No configuration found in database, using defaults")

            db.close()

        except Exception as e:
            print(f"Warning: Error loading configuration from database: {e}")
            print("Using default configuration")
            # Continue with default configuration if database config can't be loaded

        # Use custom_instructions parameter first, then fall back to database value
        instructions_to_use = custom_instructions or db_custom_instructions
        if instructions_to_use:
            config["custom_fact_extraction_prompt"] = instructions_to_use

        # ALWAYS parse environment variables in the final config
        # This ensures that even default config values like "env:OPENAI_API_KEY" get parsed
        print("Parsing environment variables in final config...")
        config = _parse_environment_variables(config)

        # Check if config has changed by comparing hashes
        current_config_hash = _get_config_hash(config)

        # Only reinitialize if config changed or client doesn't exist
        if _memory_client is None or _config_hash != current_config_hash:
            print(f"Initializing memory client with config hash: {current_config_hash}")
            try:
                _memory_client = Memory.from_config(config_dict=config)
                _config_hash = current_config_hash
                print("Memory client initialized successfully")
            except Exception as init_error:
                print(f"Warning: Failed to initialize memory client: {init_error}")
                print("Server will continue running with limited memory functionality")
                _memory_client = None
                _config_hash = None
                return None

        return _memory_client

    except Exception as e:
        print(f"Warning: Exception occurred while initializing memory client: {e}")
        print("Server will continue running with limited memory functionality")
        return None


def get_default_user_id():
    return "default_user"
```

- [ ] **Step 2: Rewrite `config.py.patched`** — only `get_default_configuration()` changes to read `LLM_MODEL`/`EMBED_MODEL` from env instead of hardcoding them; every route/model class is unchanged.

```python
import os
import json
from typing import Dict, Any, Optional
from fastapi import APIRouter, HTTPException, Depends
from pydantic import BaseModel, Field
from sqlalchemy.orm import Session
from app.database import get_db
from app.models import Config as ConfigModel
from app.utils.memory import reset_memory_client

router = APIRouter(prefix="/api/v1/config", tags=["config"])

class LLMConfig(BaseModel):
    model: str = Field(..., description="LLM model name")
    temperature: float = Field(..., description="Temperature setting for the model")
    max_tokens: int = Field(..., description="Maximum tokens to generate")
    api_key: Optional[str] = Field(None, description="API key or 'env:API_KEY' to use environment variable")
    ollama_base_url: Optional[str] = Field(None, description="Base URL for Ollama server (e.g., http://host.docker.internal:11434)")

class LLMProvider(BaseModel):
    provider: str = Field(..., description="LLM provider name")
    config: LLMConfig

class EmbedderConfig(BaseModel):
    model: str = Field(..., description="Embedder model name")
    api_key: Optional[str] = Field(None, description="API key or 'env:API_KEY' to use environment variable")
    ollama_base_url: Optional[str] = Field(None, description="Base URL for Ollama server (e.g., http://host.docker.internal:11434)")

class EmbedderProvider(BaseModel):
    provider: str = Field(..., description="Embedder provider name")
    config: EmbedderConfig

class OpenMemoryConfig(BaseModel):
    custom_instructions: Optional[str] = Field(None, description="Custom instructions for memory management and fact extraction")

class Mem0Config(BaseModel):
    llm: Optional[LLMProvider] = None
    embedder: Optional[EmbedderProvider] = None

class ConfigSchema(BaseModel):
    openmemory: Optional[OpenMemoryConfig] = None
    mem0: Mem0Config

def get_default_configuration():
    """Get the default configuration with sensible defaults for LLM and embedder.

    Model names are env-overridable (LLM_MODEL, EMBED_MODEL) so this stays in
    sync with memory.py's get_default_memory_config() without duplicating a
    second hardcoded model name.
    """
    return {
        "openmemory": {
            "custom_instructions": None
        },
        "mem0": {
            "llm": {
                "provider": "ollama",
                "config": {
                    "model": os.environ.get("LLM_MODEL", "qwen2.5:14b-instruct"),
                    "temperature": 0.1,
                    "max_tokens": 2000,
                    "ollama_base_url": os.environ.get("OLLAMA_BASE_URL", "http://host.docker.internal:11434")
                }
            },
            "embedder": {
                "provider": "ollama",
                "config": {
                    "model": os.environ.get("EMBED_MODEL", "nomic-embed-text"),
                    "ollama_base_url": os.environ.get("OLLAMA_BASE_URL", "http://host.docker.internal:11434")
                }
            }
        }
    }

def get_config_from_db(db: Session, key: str = "main"):
    """Get configuration from database."""
    config = db.query(ConfigModel).filter(ConfigModel.key == key).first()

    if not config:
        # Create default config with proper provider configurations
        default_config = get_default_configuration()
        db_config = ConfigModel(key=key, value=default_config)
        db.add(db_config)
        db.commit()
        db.refresh(db_config)
        return default_config

    # Ensure the config has all required sections with defaults
    config_value = config.value
    default_config = get_default_configuration()

    # Merge with defaults to ensure all required fields exist
    if "openmemory" not in config_value:
        config_value["openmemory"] = default_config["openmemory"]

    if "mem0" not in config_value:
        config_value["mem0"] = default_config["mem0"]
    else:
        # Ensure LLM config exists with defaults
        if "llm" not in config_value["mem0"] or config_value["mem0"]["llm"] is None:
            config_value["mem0"]["llm"] = default_config["mem0"]["llm"]

        # Ensure embedder config exists with defaults
        if "embedder" not in config_value["mem0"] or config_value["mem0"]["embedder"] is None:
            config_value["mem0"]["embedder"] = default_config["mem0"]["embedder"]

    # Save the updated config back to database if it was modified
    if config_value != config.value:
        config.value = config_value
        db.commit()
        db.refresh(config)

    return config_value

def save_config_to_db(db: Session, config: Dict[str, Any], key: str = "main"):
    """Save configuration to database."""
    db_config = db.query(ConfigModel).filter(ConfigModel.key == key).first()

    if db_config:
        db_config.value = config
        db_config.updated_at = None  # Will trigger the onupdate to set current time
    else:
        db_config = ConfigModel(key=key, value=config)
        db.add(db_config)

    db.commit()
    db.refresh(db_config)
    return db_config.value

@router.get("/", response_model=ConfigSchema)
async def get_configuration(db: Session = Depends(get_db)):
    """Get the current configuration."""
    config = get_config_from_db(db)
    return config

@router.put("/", response_model=ConfigSchema)
async def update_configuration(config: ConfigSchema, db: Session = Depends(get_db)):
    """Update the configuration."""
    current_config = get_config_from_db(db)

    # Convert to dict for processing
    updated_config = current_config.copy()

    # Update openmemory settings if provided
    if config.openmemory is not None:
        if "openmemory" not in updated_config:
            updated_config["openmemory"] = {}
        updated_config["openmemory"].update(config.openmemory.dict(exclude_none=True))

    # Update mem0 settings
    updated_config["mem0"] = config.mem0.dict(exclude_none=True)

    # Save the configuration to database
    save_config_to_db(db, updated_config)
    reset_memory_client()
    return updated_config

@router.post("/reset", response_model=ConfigSchema)
async def reset_configuration(db: Session = Depends(get_db)):
    """Reset the configuration to default values."""
    try:
        # Get the default configuration with proper provider setups
        default_config = get_default_configuration()

        # Save it as the current configuration in the database
        save_config_to_db(db, default_config)
        reset_memory_client()
        return default_config
    except Exception as e:
        raise HTTPException(
            status_code=500,
            detail=f"Failed to reset configuration: {str(e)}"
        )

@router.get("/mem0/llm", response_model=LLMProvider)
async def get_llm_configuration(db: Session = Depends(get_db)):
    """Get only the LLM configuration."""
    config = get_config_from_db(db)
    llm_config = config.get("mem0", {}).get("llm", {})
    return llm_config

@router.put("/mem0/llm", response_model=LLMProvider)
async def update_llm_configuration(llm_config: LLMProvider, db: Session = Depends(get_db)):
    """Update only the LLM configuration."""
    current_config = get_config_from_db(db)

    # Ensure mem0 key exists
    if "mem0" not in current_config:
        current_config["mem0"] = {}

    # Update the LLM configuration
    current_config["mem0"]["llm"] = llm_config.dict(exclude_none=True)

    # Save the configuration to database
    save_config_to_db(db, current_config)
    reset_memory_client()
    return current_config["mem0"]["llm"]

@router.get("/mem0/embedder", response_model=EmbedderProvider)
async def get_embedder_configuration(db: Session = Depends(get_db)):
    """Get only the Embedder configuration."""
    config = get_config_from_db(db)
    embedder_config = config.get("mem0", {}).get("embedder", {})
    return embedder_config

@router.put("/mem0/embedder", response_model=EmbedderProvider)
async def update_embedder_configuration(embedder_config: EmbedderProvider, db: Session = Depends(get_db)):
    """Update only the Embedder configuration."""
    current_config = get_config_from_db(db)

    # Ensure mem0 key exists
    if "mem0" not in current_config:
        current_config["mem0"] = {}

    # Update the Embedder configuration
    current_config["mem0"]["embedder"] = embedder_config.dict(exclude_none=True)

    # Save the configuration to database
    save_config_to_db(db, current_config)
    reset_memory_client()
    return current_config["mem0"]["embedder"]

@router.get("/openmemory", response_model=OpenMemoryConfig)
async def get_openmemory_configuration(db: Session = Depends(get_db)):
    """Get only the OpenMemory configuration."""
    config = get_config_from_db(db)
    openmemory_config = config.get("openmemory", {})
    return openmemory_config

@router.put("/openmemory", response_model=OpenMemoryConfig)
async def update_openmemory_configuration(openmemory_config: OpenMemoryConfig, db: Session = Depends(get_db)):
    """Update only the OpenMemory configuration."""
    current_config = get_config_from_db(db)

    # Ensure openmemory key exists
    if "openmemory" not in current_config:
        current_config["openmemory"] = {}

    # Update the OpenMemory configuration
    current_config["openmemory"].update(openmemory_config.dict(exclude_none=True))

    # Save the configuration to database
    save_config_to_db(db, current_config)
    reset_memory_client()
    return current_config["openmemory"]
```

- [ ] **Step 3: Validate — build + config API reflects new defaults on a fresh (unconfigured) DB**

Covered together with Task 3's rebuild (all three patched files land in the same image build). See Task 3 Step 3 for the combined validation command.

- [ ] **Step 4: Commit** (bundled with Task 3)

---

### Task 3: Pin `Dockerfile.mem0` base digest + add 3rd `COPY`, rebuild, validate

**Files:**
- Modify (full-file replace): `Dockerfile.mem0`

**Depends on:** Task 1 (`categorization.py.patched` must exist), Task 2 (`memory.py.patched`/`config.py.patched` already updated).

- [ ] **Step 1: Rewrite `Dockerfile.mem0`**

```dockerfile
# ~/ai-stack/Dockerfile.mem0
# Base pinned to the current mem0/openmemory-mcp:latest digest (resolved 2026-07-01):
#   mem0/openmemory-mcp@sha256:b665d382a94fdc18c7bb84a647d4bebdc98d9e7fc1146fc5e559ca7f5f7f9211
# Re-resolve and bump deliberately — never track :latest in a shipped Kit.
FROM mem0/openmemory-mcp@sha256:b665d382a94fdc18c7bb84a647d4bebdc98d9e7fc1146fc5e559ca7f5f7f9211

# Patch 1: vector-store dims + local-ollama mem0-client defaults, all env-overridable
# via QDRANT_HOST/QDRANT_PORT/QDRANT_COLLECTION/EMBED_DIMS/LLM_MODEL/EMBED_MODEL/OLLAMA_BASE_URL.
COPY memory.py.patched /usr/src/openmemory/app/utils/memory.py

# Patch 2: config-API defaults (the /config API DB-seed path) — same env vars as Patch 1,
# so first-boot DB seeding matches the mem0-client defaults exactly.
COPY config.py.patched /usr/src/openmemory/app/routers/config.py

# Patch 3: categorization pass repointed off hardcoded gpt-4o-mini to the local Ollama
# chat model (LLM_MODEL) via Ollama's OpenAI-compatible endpoint. Fixes the
# 'Completions'/AttributeError noise logged on every inferred write.
COPY categorization.py.patched /usr/src/openmemory/app/utils/categorization.py
```

- [ ] **Step 2: Rebuild with `--no-cache`** (patched Python files are baked into the image; cached layers would keep the old bug)

```bash
cd ~/ai-stack
docker compose build --no-cache mem0
docker compose up -d mem0
```

- [ ] **Step 3: Validate — zero categorization errors on an inferred write**

```bash
docker logs -f mem0 &
LOGPID=$!
curl -sS --max-time 90 -X POST http://localhost:8765/api/v1/memories/ \
  -H "Content-Type: application/json" \
  -d '{"user_id":"yorgos","text":"Testing categorization patch: user prefers dark roast coffee.","infer":true}'
sleep 5
kill $LOGPID
docker logs mem0 --since 2m | grep -iE "categoriz|Completions|gpt-4o|AttributeError|Traceback"
```
Expected: no matches from the grep (empty output = pass). `response_format: json_object` is already confirmed working against this Ollama install (Task 1 Step 2) — if this still errors, the cause is something else (e.g. `LLM_MODEL` not pulled, base_url typo) rather than the JSON-mode approach itself; debug from the actual error rather than assuming the known unknowns.

- [ ] **Step 4: Commit**

```bash
cd ~/ai-stack
git add Dockerfile.mem0 memory.py.patched config.py.patched categorization.py.patched
git commit -m "fix(mem0): pin base image digest, externalize model/dims to env, fix categorization gpt-4o-mini hardcode

Categorization was hardcoded to OpenAI's gpt-4o-mini via a bare OpenAI()
client — always errored against OPENAI_API_KEY=ollama-dummy (non-fatal, but
noisy on every inferred write). Repointed at Ollama's OpenAI-compat endpoint,
model driven by LLM_MODEL. Also pulled LLM_MODEL/EMBED_MODEL/EMBED_DIMS out
of memory.py/config.py so a Kit user never edits Python to change models."
```

---

### Task 4: Pin `web-extractor`'s base image

**Files:**
- Modify (full-file replace): `web-extractor/Dockerfile`

**Problem:** `FROM python:3.12-slim` is a floating tag (rebuilds monthly under Debian security patches) — violates the "pin every image" rule even though it's not `:latest`.

- [ ] **Step 1: Digest already resolved live (2026-07-01)** — `sha256:423ed6ab25b1921a477529254bfeeabf5855151dc2c3141699a1bfc852199fbf`, baked into Step 2's Dockerfile below. Re-verify only if this task is executed more than a few days after resolution (Debian security rebuilds move the tag):

```bash
docker pull python:3.12-slim
docker inspect python:3.12-slim --format '{{index .RepoDigests 0}}'
```

- [ ] **Step 2: Rewrite `web-extractor/Dockerfile`** using the resolved digest:

```dockerfile
FROM python:3.12-slim@sha256:423ed6ab25b1921a477529254bfeeabf5855151dc2c3141699a1bfc852199fbf

WORKDIR /app

# trafilatura needs libxml2/libxslt at runtime
RUN apt-get update && apt-get install -y --no-install-recommends \
    libxml2 libxslt1.1 \
    && rm -rf /var/lib/apt/lists/*

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .

EXPOSE 8000

# Single worker — Playwright connection is per-process and we have light load
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]
```

- [ ] **Step 3: Validate**

```bash
cd ~/ai-stack
docker compose build web-extractor
docker compose up -d web-extractor
docker compose ps web-extractor   # expect: Up
```

- [ ] **Step 4: Commit**

```bash
git add web-extractor/Dockerfile
git commit -m "fix(web-extractor): pin base image to digest instead of floating python:3.12-slim tag"
```

---

### Task 5: Rewrite `docker-compose.yml` — wire new env vars, externalize ports, document non-obvious bits

**Files:**
- Modify (full-file replace): `docker-compose.yml`

**Depends on:** Task 2 (new env var names `LLM_MODEL`/`EMBED_MODEL`/`EMBED_DIMS` must exist before wiring them here).

**Changes from current file:**
- `mem0` service gains `LLM_MODEL`, `EMBED_MODEL`, `EMBED_DIMS` env vars (previously baked as Python defaults, now Kit-configurable).
- Ports parameterized via `${VAR:-default}` so `.env` controls them without touching YAML (Kit acceptance criterion).
- `open-webui` gains `WEBUI_SECRET_KEY=${WEBUI_SECRET_KEY:-}` — documented in `.env.example` (Task 6) as optional but recommended; Open WebUI persists a generated key to disk already if left unset, so this doesn't fix a live bug, it just makes the behavior explicit and Kit-configurable per the §4 checklist item ("Open WebUI secret").
- Everything else (named volumes, `extra_hosts`, 4-slash `DATABASE_URL`, searxng disabled block, Ollama-stays-native) is unchanged in substance, just re-commented for a stranger reading it cold.

- [ ] **Step 1: Rewrite `docker-compose.yml`**

```yaml
# ~/ai-stack/docker-compose.yml
#
# Local AI stack: Open WebUI + Mem0/OpenMemory + Qdrant + n8n + web extraction,
# all talking to a native (non-containerized) Ollama on the host.
#
# Ollama is intentionally NOT a service here — install/run it natively on the
# host (see README.md prerequisites) and point OLLAMA_BASE_URL at it via .env.
#
# Quick start: cp .env.example .env  →  edit values  →  docker compose up -d

services:

  n8n:
    image: n8nio/n8n:1.74.0
    container_name: n8n
    restart: unless-stopped
    ports:
      - "${N8N_PORT:-5678}:5678"
    environment:
      - N8N_HOST=127.0.0.1
      - N8N_PORT=5678
      - N8N_PROTOCOL=http
      - GENERIC_TIMEZONE=${TZ:-Europe/Prague}
      - TZ=${TZ:-Europe/Prague}
      - N8N_LOG_LEVEL=info
      - N8N_DIAGNOSTICS_ENABLED=false
      - N8N_ENCRYPTION_KEY=${N8N_ENCRYPTION_KEY}
      - N8N_RUNNERS_ENABLED=true
      - N8N_GIT_NODE_DISABLE_BARE_REPOS=true
    volumes:
      - n8n_data:/home/node/.n8n
    extra_hosts:
      - "host.docker.internal:host-gateway"

  # ─────────────────────────────────────────────────────────────
  # Keeps the default chat model warm in Ollama's VRAM cache so the
  # first request of the day isn't a cold-load. Harmless if Ollama
  # is unreachable — it just logs a WARN and retries in 20 min.
  # ─────────────────────────────────────────────────────────────
  ollama-keepalive:
    image: curlimages/curl:8.10.1
    container_name: ollama-keepalive
    restart: unless-stopped
    extra_hosts:
      - "host.docker.internal:host-gateway"
    entrypoint:
      - /bin/sh
      - -c
      - |
        while true; do
          curl -sS -X POST ${OLLAMA_BASE_URL:-http://host.docker.internal:11434}/api/generate \
            -H "Content-Type: application/json" \
            -d '{"model":"${LLM_MODEL:-qwen2.5:14b-instruct}","prompt":"ok","keep_alive":"24h","stream":false}' \
            > /dev/null \
            && echo "$$(date -Iseconds)] warmed ${LLM_MODEL:-qwen2.5:14b-instruct}" \
            || echo "$$(date -Iseconds)] WARN: keepalive failed";
          sleep 1200;
        done

  # ─────────────────────────────────────────────────────────────
  # SearXNG is DISABLED — broken WSL2 bind-mount at the runc level
  # (see README troubleshooting). Do not re-attempt the mount without
  # first reading that section. DDGS is the active web-search engine
  # for Open WebUI's built-in RAG web search instead.
  # ─────────────────────────────────────────────────────────────
  # searxng-redis:
  #   image: redis:7-alpine
  #   container_name: searxng-redis
  #   restart: unless-stopped
  #   command: redis-server --save "" --appendonly no
  #
  # searxng:
  #   image: searxng/searxng:latest
  #   container_name: searxng
  #   restart: unless-stopped
  #   ports:
  #     - "127.0.0.1:8888:8080"
  #   volumes:
  #     - ./searxng_config:/etc/searxng
  #   environment:
  #     - SEARXNG_BASE_URL=http://localhost:8888/
  #     - TZ=${TZ:-Europe/Prague}
  #   depends_on:
  #     - searxng-redis
  #   cap_drop:
  #     - ALL
  #   cap_add:
  #     - CHOWN
  #     - SETGID
  #     - SETUID

  # ─────────────────────────────────────────────────────────────
  # Playwright version MUST match the playwright pin in Open WebUI's
  # own requirements.txt (currently 1.58.0). Never bump this alone —
  # a mismatch produces "428 Precondition Required" from Open WebUI's
  # web-loader. Check both images' pins together before bumping either.
  # ─────────────────────────────────────────────────────────────
  playwright:
    image: mcr.microsoft.com/playwright:v1.58.0-noble
    container_name: playwright
    restart: unless-stopped
    command: /bin/sh -c "npx -y playwright@1.58.0 run-server --port 3000 --host 0.0.0.0"
    environment:
      - TZ=${TZ:-Europe/Prague}

  web-extractor:
    build:
      context: ./web-extractor
      dockerfile: Dockerfile
    container_name: web-extractor
    restart: unless-stopped
    environment:
      - PLAYWRIGHT_WS=ws://playwright:3000/
      - PAGE_TIMEOUT_MS=30000
      - CONCURRENCY=3
      - TZ=${TZ:-Europe/Prague}
    depends_on:
      - playwright

  # ─────────────────────────────────────────────────────────────
  # Qdrant vector store — container named mem0_store to satisfy
  # OpenMemory's original hardcoded default; QDRANT_HOST below is
  # what memory.py.patched actually reads (the name match is now
  # coincidental, not load-bearing — safe to rename if you also
  # update QDRANT_HOST).
  # ─────────────────────────────────────────────────────────────
  mem0_store:
    image: qdrant/qdrant:v1.12.4
    container_name: mem0_store
    restart: unless-stopped
    ports:
      - "127.0.0.1:${QDRANT_HTTP_PORT:-6333}:6333"
      - "127.0.0.1:${QDRANT_GRPC_PORT:-6334}:6334"
    volumes:
      - qdrant_data:/qdrant/storage
    environment:
      - TZ=${TZ:-Europe/Prague}

  # ─────────────────────────────────────────────────────────────
  # Mem0 / OpenMemory — three patched files baked into the image
  # (see Dockerfile.mem0). All model/dims/vector-store values below
  # are env-driven; change behavior via .env, never by editing the
  # patched Python.
  # ─────────────────────────────────────────────────────────────
  mem0:
    build:
      context: .
      dockerfile: Dockerfile.mem0
    image: mem0-patched:local
    container_name: mem0
    restart: unless-stopped
    ports:
      - "127.0.0.1:${MEM0_PORT:-8765}:8765"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    environment:
      - OPENAI_API_KEY=${OPENAI_API_KEY:-ollama-dummy}   # insurance for the OpenAI SDK client init; unused for actual auth, Ollama needs no key
      - OLLAMA_BASE_URL=${OLLAMA_BASE_URL:-http://host.docker.internal:11434}
      - LLM_MODEL=${LLM_MODEL:-qwen2.5:14b-instruct}
      - EMBED_MODEL=${EMBED_MODEL:-nomic-embed-text}
      - EMBED_DIMS=${EMBED_DIMS:-768}
      - QDRANT_HOST=mem0_store
      - QDRANT_PORT=6333
      - QDRANT_COLLECTION=${QDRANT_COLLECTION:-openmemory_yorgos}
      # 4 slashes = absolute /data path. A 3-slash relative path or a direct
      # file bind-mount both break under WSL2/Docker-Desktop at the runc
      # level — this must stay a named volume on a directory, never a
      # single-file bind mount.
      - DATABASE_URL=sqlite:////data/openmemory.db
      - USER=${MEM0_USER_ID:-yorgos}
      - TZ=${TZ:-Europe/Prague}
    volumes:
      - mem0_data:/data
    depends_on:
      - mem0_store
      - ollama-keepalive

  open-webui:
    image: ghcr.io/open-webui/open-webui:v0.9.6
    container_name: open-webui
    restart: unless-stopped
    ports:
      - "${OPEN_WEBUI_PORT:-3000}:8080"
    environment:
      - OLLAMA_BASE_URL=${OLLAMA_BASE_URL:-http://host.docker.internal:11434}
      - WEBUI_AUTH=true
      - ENABLE_SIGNUP=${ENABLE_SIGNUP:-false}
      # If unset, Open WebUI generates and persists its own key under
      # /app/backend/data on first boot — sessions still survive restarts.
      # Set this explicitly if you want a portable, reproducible secret
      # (e.g. shared across a redeploy that wipes open-webui_data).
      - WEBUI_SECRET_KEY=${WEBUI_SECRET_KEY:-}
      - DEFAULT_LOCALE=${DEFAULT_LOCALE:-en}
      - TZ=${TZ:-Europe/Prague}
      - ENABLE_RAG_WEB_SEARCH=true
      - RAG_WEB_SEARCH_ENGINE=${RAG_WEB_SEARCH_ENGINE:-duckduckgo}
      - RAG_WEB_SEARCH_RESULT_COUNT=5
      - RAG_WEB_SEARCH_CONCURRENT_REQUESTS=3
      - MEM0_BASE_URL=http://mem0:8765
      - MEM0_USER_ID=${MEM0_USER_ID:-yorgos}
    volumes:
      - open-webui_data:/app/backend/data
    extra_hosts:
      - "host.docker.internal:host-gateway"
    depends_on:
      - ollama-keepalive
      - playwright
      - web-extractor
      - mem0

volumes:
  n8n_data:
  open-webui_data:
  qdrant_data:
  mem0_data:
```

**Note on `RAG_WEB_SEARCH_ENGINE`:** live compose currently sets `searxng` even though the searxng service is fully disabled (gotcha #10 says DDGS is the active engine). Changed the default to `duckduckgo` here for a Kit user who has no reason to run a broken searxng block; kept it overridable via `.env` in case you want to re-point it. **Resolved live (2026-07-01):** queried `webui.db`'s `config` table directly — `data['rag']['web']['search']['engine'] == "duckduckgo"` is already the DB-authoritative value (gotcha #11). The env default change matches live reality; it does not fight a stale DB value. Safe to proceed as written.

- [ ] **Step 2: Validate**

```bash
cd ~/ai-stack
docker compose config --quiet && echo "compose config OK"
docker compose up -d
docker compose ps   # expect all 7 services Up (open-webui healthy)
```

- [ ] **Step 3: Commit**

```bash
git add docker-compose.yml
git commit -m "refactor(compose): externalize ports/model/dims to env, document searxng-disabled and playwright-pin rationale inline"
```

---

### Task 6: Write `.env.example`

**Files:**
- Create: `.env.example`

**Depends on:** Task 5 (must document exactly the env vars Task 5's compose file reads).

- [ ] **Step 1: Write `.env.example`**

```bash
# ~/ai-stack/.env.example
# Copy to .env and adjust. Every var has a safe default in docker-compose.yml
# EXCEPT the ones marked REQUIRED below — compose will fail or misbehave
# without those set.

# ── Ollama (native host install, not a container) ──────────────────────────
# WSL2 / Docker Desktop (Mac/Windows): host.docker.internal works out of the box.
# Linux-native Docker (no Docker Desktop): use http://172.17.0.1:11434, or
# whatever `docker network inspect bridge` reports as the gateway IP.
OLLAMA_BASE_URL=http://host.docker.internal:11434

# Chat model used by: mem0's fact-extraction + categorization, and the
# ollama-keepalive warmer. Must already be pulled: `ollama pull qwen2.5:14b-instruct`
LLM_MODEL=qwen2.5:14b-instruct

# Embedding model used by mem0's vector store writes/reads.
# Must already be pulled: `ollama pull nomic-embed-text`
EMBED_MODEL=nomic-embed-text

# MUST match the output dimensionality of EMBED_MODEL (nomic-embed-text = 768).
# Changing this after the Qdrant collection already exists does NOT
# re-dimension it — delete the (empty) collection and let mem0 recreate it.
EMBED_DIMS=768

# ── Mem0 / OpenMemory ────────────────────────────────────────────────────
# Namespace for memories written via the Open WebUI Mem0 filter. Single-user
# setups: leave as-is. Multi-user: OpenMemory does NOT auto-create users on
# REST write (404s "User not found") — seed each user explicitly, see README
# "first-run checklist".
MEM0_USER_ID=yorgos

# Qdrant collection name. Renaming this creates a fresh (empty) collection —
# it does not migrate existing vectors.
QDRANT_COLLECTION=openmemory_yorgos

# Dummy value satisfies the OpenAI SDK client's required-field check inside
# mem0's categorization module; Ollama needs no real key. Do not put a real
# OpenAI key here unless you intentionally want to fall back to OpenAI.
OPENAI_API_KEY=ollama-dummy

# ── Open WebUI ───────────────────────────────────────────────────────────
# Leave false unless you want additional users to self-register. The first
# account created is always the admin regardless of this setting.
ENABLE_SIGNUP=false

# Optional. If unset, Open WebUI generates and persists its own secret to
# /app/backend/data on first boot (sessions still survive container
# restarts). Set this explicitly for a reproducible secret across environments.
WEBUI_SECRET_KEY=

DEFAULT_LOCALE=en

# duckduckgo requires no extra service. searxng is available but its
# container is disabled in this Kit (broken WSL2 bind-mount at the runc
# level) — only switch this if you've fixed/re-enabled searxng yourself.
RAG_WEB_SEARCH_ENGINE=duckduckgo

# ── n8n ──────────────────────────────────────────────────────────────────
# REQUIRED. Generate with: openssl rand -hex 32
# Losing/rotating this makes existing encrypted n8n credentials unreadable.
N8N_ENCRYPTION_KEY=

# ── Ports (change only if you have a conflict on the host) ─────────────────
OPEN_WEBUI_PORT=3000
N8N_PORT=5678
MEM0_PORT=8765
QDRANT_HTTP_PORT=6333
QDRANT_GRPC_PORT=6334

# ── Misc ─────────────────────────────────────────────────────────────────
TZ=Europe/Prague
```

- [ ] **Step 2: Validate**

```bash
cd ~/ai-stack
cp .env.example .env.test
# fill required vars for a syntax check only
sed -i 's/^N8N_ENCRYPTION_KEY=$/N8N_ENCRYPTION_KEY=test/' .env.test
docker compose --env-file .env.test config --quiet && echo "env-file resolves cleanly"
rm .env.test
```

- [ ] **Step 3: Commit**

```bash
git add .env.example
git commit -m "docs(kit): add .env.example documenting every compose-consumed env var"
```

---

### Task 7: Write `README.md`

**Files:**
- Create: `README.md`

**Depends on:** Tasks 1–6 (documents the final, patched state).

- [ ] **Step 1: Write `README.md`**

```markdown
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
   confirms the Qdrant collection exists. Expect no errors in any step.

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
```

- [ ] **Step 2: Validate** — have a second person (or a fresh clone in a scratch dir) follow the README's Install + First-run checklist verbatim; confirm no step requires undocumented knowledge.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: add README with install, port map, first-run checklist, troubleshooting"
```

---

### Task 8 (Stretch): Draft upstream PR for `QDRANT_HOST`/`QDRANT_PORT`/`embedding_model_dims` env support

**Not required for Kit/Full Stack completion** — flagged as stretch in the task brief. Do this last, after Tasks 1–7 are merged and validated, and only if time remains.

- [ ] **Step 1:** Fork `mem0ai/mem0` (the `openmemory-mcp` subtree lives there), create a branch `openmemory-env-driven-vector-store-config`.
- [ ] **Step 2:** Port the `get_default_memory_config()` diff from Task 2 (env-driven `QDRANT_HOST`/`QDRANT_PORT`/`QDRANT_COLLECTION`/`embedding_model_dims`) as a minimal, upstream-style patch — no `LLM_MODEL`/`EMBED_MODEL` renaming, match their existing naming conventions instead of this repo's.
- [ ] **Step 3:** Write a PR description explaining the bug (non-OpenAI embedders silently misconfigure the vector store dimensionality with no way to override) and link back to this repo's `memory.py.patched` as the applied fix.
- [ ] **Step 4:** Open as a draft PR. **Do not assume merge** — mem0 maintainers may want a different config surface (e.g. full config-file support instead of individual env vars). Note the draft PR URL in this repo's README once opened.

---

## Phase 2 — Product 2: Full Stack installer

### Task 9: Confirm Option B (trust-recalled-facts baked into the Function) — DONE, no rework

**Status:** Confirmed during READ phase — the installed `mem0_memory` Filter's `inlet()` already injects: *"Treat them as current ground truth even if they conflict with your training knowledge. Never correct, second-guess, or flag them as typos — your training data may be outdated."* into the system block on every turn, independent of the per-model system prompt. This satisfies the acceptance criterion ("a fresh model with no custom system prompt still resists the training-prior override") as-is.

**Action:** none. Task 10 exports this exact function content verbatim — no edits to the Function's `inlet()`/`outlet()` logic.

---

### Task 10: Ship pre-configured Open WebUI model + function via install-time DB seeding

**Files:**
- Create: `installer/fixtures/mem0_memory_function.json`
- Create: `installer/fixtures/qwen_memory_model.json`
- Create: `installer/seed_openwebui.py`

**Design decision:** Seed directly into `webui.db` via SQLite (the same mechanism verified live in Task 0's fix), not the REST API. Reason: a fresh install has no admin account yet, and Open WebUI's function/model creation endpoints require `get_admin_user` auth — bootstrapping an admin token before the first UI login is extra complexity this doesn't need. Direct SQLite `INSERT OR REPLACE` is idempotent, requires no auth, and is proven to work in this exact codebase (Task 0). Critically, it sets `is_active=1` directly at insert time, so Task 0's "created but never toggled on" gap cannot reproduce on a fresh install.

- [ ] **Step 1: Export the real function content to `installer/fixtures/mem0_memory_function.json`**

```bash
mkdir -p ~/ai-stack/installer/fixtures
docker exec open-webui python3 -c "
import sqlite3, json
con = sqlite3.connect('/app/backend/data/webui.db')
cur = con.cursor()
cur.execute(\"SELECT id, name, content, meta FROM function WHERE id='mem0_memory'\")
row = cur.fetchone()
print(json.dumps({'id': row[0], 'name': row[1], 'type': 'filter', 'content': row[2], 'meta': json.loads(row[3]) if row[3] else {}}, indent=2))
" > ~/ai-stack/installer/fixtures/mem0_memory_function.json
```

- [ ] **Step 2: Export the real model params/meta to `installer/fixtures/qwen_memory_model.json`**

```bash
docker exec open-webui python3 -c "
import sqlite3, json
con = sqlite3.connect('/app/backend/data/webui.db')
cur = con.cursor()
cur.execute(\"SELECT id, name, base_model_id, params, meta FROM model WHERE id='qwen-25-memory'\")
row = cur.fetchone()
print(json.dumps({
    'id': row[0], 'name': row[1], 'base_model_id': row[2],
    'params': json.loads(row[3]) if row[3] else {},
    'meta': json.loads(row[4]) if row[4] else {}
}, indent=2))
" > ~/ai-stack/installer/fixtures/qwen_memory_model.json
```

Note: `base_model_id` in the fixture will be `qwen2.5:14b-instruct` — the seeding script (Step 3) must template this against the installer's `LLM_MODEL` choice rather than hardcoding, in case a user picks a different base chat model during the `setup.sh` wizard (Task 13).

- [ ] **Step 3: Write `installer/seed_openwebui.py`**

```python
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
```

**Verify against real schema before relying on this in setup.sh:** the `INSERT ... ON CONFLICT` column list must match the actual `function`/`model` table schemas in the target Open WebUI version (`v0.9.6` here) — confirm column names via `docker exec open-webui python3 -c "import sqlite3; print(sqlite3.connect('/app/backend/data/webui.db').execute('PRAGMA table_info(function)').fetchall())"` (and same for `model`) before wiring this into Task 13, since schemas do change across Open WebUI releases and a Kit/Installer must not silently corrupt the DB on version drift.

- [ ] **Step 4: Validate** — run against a scratch copy of `webui.db`, not the live one:

```bash
docker cp open-webui:/app/backend/data/webui.db /tmp/webui-test.db
python3 ~/ai-stack/installer/seed_openwebui.py --db /tmp/webui-test.db --llm-model qwen2.5:14b-instruct
python3 -c "
import sqlite3
con = sqlite3.connect('/tmp/webui-test.db')
print(con.execute(\"SELECT id, is_active FROM function WHERE id='mem0_memory'\").fetchone())
print(con.execute(\"SELECT id, base_model_id, is_active FROM model WHERE id='qwen-25-memory'\").fetchone())
"
rm /tmp/webui-test.db
```
Expect both rows present with `is_active=1`.

- [ ] **Step 5: Commit**

```bash
git add installer/fixtures/ installer/seed_openwebui.py
git commit -m "feat(installer): seed Mem0 filter function + memory-enabled model directly into webui.db, sidestepping the admin-auth bootstrap problem on a fresh install"
```

---

### Task 11: OS-detection script for `OLLAMA_BASE_URL`

**Files:**
- Create: `installer/detect_ollama_host.sh`

- [ ] **Step 1: Write `installer/detect_ollama_host.sh`**

```bash
#!/usr/bin/env bash
# Detects the correct OLLAMA_BASE_URL for this host's Docker setup.
# Prints the resolved URL to stdout; nothing else. Source or capture it:
#   OLLAMA_BASE_URL=$(bash installer/detect_ollama_host.sh)
set -euo pipefail

OLLAMA_PORT="${OLLAMA_PORT:-11434}"

is_wsl2() {
    grep -qi microsoft /proc/version 2>/dev/null
}

is_macos() {
    [[ "$(uname -s)" == "Darwin" ]]
}

docker_supports_host_gateway() {
    # host-gateway special value requires Docker Engine >= 20.10
    local ver
    ver=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "0.0.0")
    local major minor
    major=$(echo "$ver" | cut -d. -f1)
    minor=$(echo "$ver" | cut -d. -f2)
    [[ "$major" -gt 20 || ("$major" -eq 20 && "$minor" -ge 10) ]]
}

if is_wsl2 || is_macos; then
    # Docker Desktop (WSL2 backend) and Docker Desktop for Mac both provide
    # host.docker.internal out of the box.
    echo "http://host.docker.internal:${OLLAMA_PORT}"
    exit 0
fi

# Linux-native Docker Engine (no Docker Desktop).
if docker_supports_host_gateway; then
    # extra_hosts: host.docker.internal:host-gateway in docker-compose.yml
    # makes this resolve even on native Linux with Engine >= 20.10.
    echo "http://host.docker.internal:${OLLAMA_PORT}"
    exit 0
fi

# Fallback for old Docker Engine without host-gateway support: use the
# bridge network's gateway IP directly.
GATEWAY_IP=$(docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}' 2>/dev/null || echo "172.17.0.1")
echo "http://${GATEWAY_IP}:${OLLAMA_PORT}"
```

- [ ] **Step 2: Validate**

```bash
chmod +x ~/ai-stack/installer/detect_ollama_host.sh
bash ~/ai-stack/installer/detect_ollama_host.sh
# On this WSL2 box, expect: http://host.docker.internal:11434
```

Then verify actual reachability from inside a container (not just the URL logic):

```bash
URL=$(bash ~/ai-stack/installer/detect_ollama_host.sh)
docker run --rm --add-host host.docker.internal:host-gateway curlimages/curl:8.10.1 \
  curl -sS --max-time 5 "${URL}/api/tags" | python3 -m json.tool | head -5
```
Expect a JSON list of installed Ollama models — confirms the detected URL is actually reachable, not just syntactically plausible.

- [ ] **Step 3: Commit**

```bash
git add installer/detect_ollama_host.sh
git commit -m "feat(installer): add OS-detection for OLLAMA_BASE_URL (WSL2/macOS vs Linux-native Docker)"
```

---

### Task 12: Model-pull automation

**Files:**
- Create: `installer/pull_models.sh`

- [ ] **Step 1: Write `installer/pull_models.sh`**

```bash
#!/usr/bin/env bash
# Idempotent Ollama model pull. Required models block install completion;
# optional models are offered but skippable.
set -euo pipefail

REQUIRED_MODELS=("qwen2.5:14b-instruct" "nomic-embed-text")
OPTIONAL_MODELS=("qwen2.5-coder:14b" "deepseek-r1:14b")

model_present() {
    ollama list 2>/dev/null | awk '{print $1}' | grep -qx "$1"
}

pull_if_missing() {
    local model="$1"
    if model_present "$model"; then
        echo "✓ ${model} already present, skipping"
    else
        echo "→ pulling ${model} ..."
        ollama pull "$model"
    fi
}

echo "=== Required models ==="
for m in "${REQUIRED_MODELS[@]}"; do
    pull_if_missing "$m"
done

if [[ "${PULL_OPTIONAL:-ask}" == "ask" ]] && [[ -t 0 ]]; then
    echo ""
    echo "=== Optional models ==="
    for m in "${OPTIONAL_MODELS[@]}"; do
        read -r -p "Pull optional model ${m}? [y/N] " reply
        if [[ "$reply" =~ ^[Yy]$ ]]; then
            pull_if_missing "$m"
        fi
    done
elif [[ "${PULL_OPTIONAL:-ask}" == "all" ]]; then
    echo ""
    echo "=== Optional models (PULL_OPTIONAL=all) ==="
    for m in "${OPTIONAL_MODELS[@]}"; do
        pull_if_missing "$m"
    done
fi

echo ""
echo "=== Verifying required models present ==="
missing=0
for m in "${REQUIRED_MODELS[@]}"; do
    if ! model_present "$m"; then
        echo "✗ MISSING: ${m}"
        missing=1
    fi
done
if [[ "$missing" -eq 1 ]]; then
    echo "ERROR: required models missing after pull attempt." >&2
    exit 1
fi
echo "✓ all required models present"
```

- [ ] **Step 2: Validate**

```bash
chmod +x ~/ai-stack/installer/pull_models.sh
PULL_OPTIONAL=ask bash ~/ai-stack/installer/pull_models.sh
# expect: both required models report "already present" on this box (already pulled)
```

- [ ] **Step 3: Commit**

```bash
git add installer/pull_models.sh
git commit -m "feat(installer): idempotent required+optional Ollama model pull"
```

---

### Task 13: `setup.sh` wizard

**Files:**
- Create: `setup.sh`

**Depends on:** Task 6 (`.env.example`), Task 10 (`seed_openwebui.py`), Task 11 (`detect_ollama_host.sh`), Task 12 (`pull_models.sh`).

- [ ] **Step 1: Write `setup.sh`**

```bash
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

# ── Question 1/3: user id ───────────────────────────────────────────────
read -r -p "Memory namespace / username [yorgos]: " MEM0_USER_ID
MEM0_USER_ID="${MEM0_USER_ID:-yorgos}"

# ── Question 2/3: timezone ──────────────────────────────────────────────
DEFAULT_TZ=$(cat /etc/timezone 2>/dev/null || echo "Europe/Prague")
read -r -p "Timezone [${DEFAULT_TZ}]: " TZ_INPUT
TZ_VALUE="${TZ_INPUT:-$DEFAULT_TZ}"

# ── Question 3/3: optional models ───────────────────────────────────────
read -r -p "Pull optional models (coder, reasoning)? [y/N] " PULL_OPT_REPLY
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
sed -i \
    -e "s#^OLLAMA_BASE_URL=.*#OLLAMA_BASE_URL=${OLLAMA_BASE_URL}#" \
    -e "s#^MEM0_USER_ID=.*#MEM0_USER_ID=${MEM0_USER_ID}#" \
    -e "s#^TZ=.*#TZ=${TZ_VALUE}#" \
    -e "s#^N8N_ENCRYPTION_KEY=.*#N8N_ENCRYPTION_KEY=${N8N_KEY}#" \
    .env
ok ".env written"

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
# seed OpenMemory user via one inferred write (also primes the smoke test data)
SEED_TEXT="Setup smoke-test fact: this user's memory namespace is ${MEM0_USER_ID}."
if curl -sS --max-time 90 -X POST "http://localhost:${MEM0_PORT:-8765}/api/v1/memories/" \
    -H "Content-Type: application/json" \
    -d "{\"user_id\":\"${MEM0_USER_ID}\",\"text\":\"${SEED_TEXT}\",\"infer\":true}" > /tmp/seed_write.json 2>&1; then
    ok "OpenMemory user seeded via inferred write"
else
    fail "OpenMemory seed write failed — see /tmp/seed_write.json"
    STATUS_OK=0
fi

if python3 installer/seed_openwebui.py \
    --db "$(docker inspect open-webui --format '{{range .Mounts}}{{if eq .Destination "/app/backend/data"}}{{.Source}}{{end}}{{end}}')/webui.db" \
    --llm-model "${LLM_MODEL:-qwen2.5:14b-instruct}"; then
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
RECALL=$(curl -s "http://localhost:${MEM0_PORT:-8765}/api/v1/memories/?user_id=${MEM0_USER_ID}&page=1&size=5")
if echo "$RECALL" | grep -q "${MEM0_USER_ID}"; then
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
```

- [ ] **Step 2: Validate** — run on a scratch clone (not this live repo) to confirm it's actually idempotent/fresh-clean, since this repo already has state from months of manual setup that could mask bugs:

```bash
cd /tmp && rm -rf ai-stack-setup-test
git clone ~/ai-stack ai-stack-setup-test
cd ai-stack-setup-test
bash setup.sh
```
Expect the final `✅ Setup complete.` line, and manually confirm in a browser that the seeded model recalls the seed fact (see Task 14).

- [ ] **Step 3: Commit**

```bash
git add setup.sh
git commit -m "feat(installer): setup.sh wizard — 3 questions -> .env -> models -> stack up -> seed -> e2e verify"
```

---

### Task 14: Playwright UI smoke test (ask-mode)

**Files:**
- Create: `installer/smoke_test_notes.md` (documents the manual/ask-mode flow; no unattended script — every browser action requires per-step confirmation per the task brief's ask-mode requirement)

**This task is executed interactively, not scripted end-to-end.** At implementation time:

- [ ] **Step 1:** Ask before each Playwright MCP browser action (navigate, click, type, screenshot). Do not batch multiple actions into one unconfirmed sequence.
- [ ] **Step 2:** Drive: navigate to `http://localhost:${OPEN_WEBUI_PORT:-3000}` → log in as the admin account created during Task 13's smoke test → select the seeded memory model → send a message asking about the seed fact written in Task 13 Step 5 (e.g. "what's my memory namespace?") → assert the response references `${MEM0_USER_ID}`.
- [ ] **Step 3:** On failure at any step, take a screenshot and stop — do not retry blindly.
- [ ] **Step 4:** Record pass/fail and, on failure, the screenshot path in `installer/smoke_test_notes.md`.

No code to write ahead of time beyond the notes file — this is inherently a live, ask-mode-gated session activity per §1 of the task brief ("playwright (ask-mode) — ask before each browser action").

---

## Phase 3 — Review

### Task 15: Self-review diff + update `CLAUDE.md`

**Files:**
- Modify: `/home/gmath/ai-stack/CLAUDE.md`

- [ ] **Step 1: Self-review the full diff** against this checklist (from the task brief §6.4):
  - [ ] No unpinned images (`grep -n "image:.*latest" docker-compose.yml Dockerfile.mem0 web-extractor/Dockerfile` → expect no matches; also confirm no floating tags like `python:3.12-slim` without a digest)
  - [ ] No hardcoded secrets/models left in Python (`grep -n "gpt-4o-mini\|qwen2.5:14b-instruct\|nomic-embed-text" memory.py.patched config.py.patched categorization.py.patched` → expect matches only inside `os.environ.get(..., "default")` fallback values, never as the sole value)
  - [ ] No partial diffs on YAML/JSON/Dockerfile/.env/Python — confirm every commit in this plan replaced full files
  - [ ] Every acceptance criterion in §4/§5 of the task brief has a corresponding checked task above
  - [ ] No §3 gotcha reintroduced — re-read gotchas #1–#11 against the final diff one more time
  - [ ] Task 0's fix is durable: confirm Task 10's `seed_openwebui.py` sets `is_active=1` at insert time (already verified in Step 3's design decision above)

- [ ] **Step 2: Update `CLAUDE.md`** — invoke `claude-md-management:claude-md-improver` (or update by hand) to reflect: patched-image contents (3 COPYs now, not 2), new env vars (`LLM_MODEL`/`EMBED_MODEL`/`EMBED_DIMS`), the `installer/` directory and its purpose, the Mem0 filter `is_active` gotcha (add as gotcha #12), and mark the "Current goal" section as superseded by this plan's completion.

- [ ] **Step 3: Produce a definition-of-done report** mapping each §4/§5 acceptance criterion to pass/fail with evidence (command output or screenshot reference), per the task brief's Definition of Done (§7).

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md with final Kit + Full Stack architecture"
```

---

## Open questions — all resolved live (2026-07-01), before dispatching any implementation subagent

1. **Task 5 — `RAG_WEB_SEARCH_ENGINE` default `searxng`→`duckduckgo`:** RESOLVED. Queried `webui.db`'s `config` table directly: `data['rag']['web']['search']['engine'] == "duckduckgo"` already. The env default change matches the DB-authoritative live value (gotcha #11) — no conflict. Proceed as written.
2. **Task 4 — `python:3.12-slim` digest:** RESOLVED. `sha256:423ed6ab25b1921a477529254bfeeabf5855151dc2c3141699a1bfc852199fbf`, already baked into Task 4 Step 2's Dockerfile above.
3. **Task 1 — `response_format: json_object` support:** RESOLVED. Confirmed live against the installed `qwen2.5:14b-instruct` via Ollama's OpenAI-compat endpoint — returns valid, parseable JSON. No fallback branch needed; implement Task 1 exactly as written.
4. **Task 10 — `function`/`model` table schema:** RESOLVED. `PRAGMA table_info` run live against `open-webui`'s `webui.db` (v0.9.6): `function(id, user_id, name, type, content, meta, created_at, updated_at, valves, is_active, is_global)`, `model(id, user_id, base_model_id, name, meta, params, created_at, updated_at, is_active)`. Both exactly match the column lists already used in `seed_openwebui.py`'s INSERT statements — no changes needed.

All four gates are clear. Phase 1 and Phase 2 tasks can proceed without further live verification of these specific unknowns.
