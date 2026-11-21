"""
title: Mem0 Memory
author: yorgos
version: 1.1.0
description: >
  Ambient long-term memory via local OpenMemory + Qdrant + Ollama.
  inlet  = semantic recall (Ollama embed -> Qdrant filtered vector search -> inject).
  outlet = inferred store (OpenMemory REST, qwen2.5:14b fact extraction).
  Fully local. No OpenAI. No per-read LLM pass.
  1.1.0: recalled memories are injected next to the LAST user message instead of the
  front of the prompt, because Ollama truncates an over-long prompt by keeping only the
  first 4 tokens plus the tail (WARN "truncating input prompt ... keep=4"); a block at the
  front is the first thing lost. The outlet also reads the assistant text from the
  structured `output` array when `content` is empty (Open WebUI >= 0.10).
requirements: requests
"""

import requests
from typing import Optional
from pydantic import BaseModel, Field


def _text_of(msg: dict) -> str:
    """Plain text of a message: `content` (str or list of parts), else the structured
    `output` array that Open WebUI >= 0.10 uses for assistant replies."""
    content = msg.get("content", "")
    if isinstance(content, list):
        content = " ".join(
            p.get("text", "") for p in content if isinstance(p, dict) and p.get("text")
        )
    if isinstance(content, str) and content.strip():
        return content
    texts = []
    for item in msg.get("output") or []:
        if isinstance(item, dict) and item.get("type") == "message":
            texts.append(
                "".join(
                    str(p.get("text"))
                    for p in item.get("content") or []
                    if isinstance(p, dict) and p.get("text") is not None
                )
            )
    return "\n".join(t for t in texts if t.strip())


class Filter:
    class Valves(BaseModel):
        # --- identity ---
        user_id: str = Field(
            default="yorgos",
            description="OpenMemory user_id namespace. Single-user: leave as-is.",
        )
        # --- endpoints (Docker-network or host) ---
        openmemory_url: str = Field(
            default="http://host.docker.internal:8765",
            description="OpenMemory REST base. From inside Open WebUI container use host.docker.internal.",
        )
        qdrant_url: str = Field(
            default="http://host.docker.internal:6333",
            description="Qdrant REST base.",
        )
        ollama_url: str = Field(
            default="http://host.docker.internal:11434",
            description="Ollama base for query embedding.",
        )
        collection: str = Field(
            default="openmemory_yorgos",
            description="Qdrant collection (must match QDRANT_COLLECTION on mem0).",
        )
        embed_model: str = Field(
            default="nomic-embed-text",
            description="Embedding model (MUST match the embedder mem0 stores with -> 768 dim).",
        )
        # --- retrieval tuning ---
        top_k: int = Field(default=5, description="Max memories to inject per turn.")
        score_threshold: float = Field(
            default=0.35,
            description="Min cosine score to inject. Raise to cut noise, lower to recall more.",
        )
        max_chars_per_memory: int = Field(
            default=400,
            description="Clip each recalled memory so the block stays small (prompt budget).",
        )
        # --- storage tuning ---
        store_enabled: bool = Field(
            default=True,
            description="Toggle outlet writes off without disabling recall.",
        )
        infer: bool = Field(
            default=True,
            description="True = qwen2.5:14b extracts facts (clean, 1 GPU pass/turn). False = raw store (fast, noisy).",
        )
        min_chars_to_store: int = Field(
            default=24,
            description="Skip storing turns shorter than this (avoids junk like 'ok', 'thanks').",
        )
        timeout: int = Field(
            default=60,
            description="HTTP timeout (s). Inferred writes can be slow on cold model.",
        )
        debug: bool = Field(
            default=False, description="Print to Open WebUI server logs."
        )

    def __init__(self):
        self.valves = self.Valves()

    # ---------- helpers ----------
    def _log(self, *a):
        if self.valves.debug:
            print("[mem0]", *a)

    def _embed(self, text: str) -> Optional[list]:
        """Embed query via Ollama. Returns 768-dim vector or None on failure."""
        try:
            r = requests.post(
                f"{self.valves.ollama_url}/api/embeddings",
                json={"model": self.valves.embed_model, "prompt": text},
                timeout=self.valves.timeout,
            )
            r.raise_for_status()
            vec = r.json().get("embedding")
            return vec if vec else None
        except Exception as e:
            self._log("embed failed:", e)
            return None

    def _recall(self, query: str) -> list:
        """Embed -> Qdrant filtered vector search. Returns list of memory strings."""
        vec = self._embed(query)
        if not vec:
            return []
        try:
            r = requests.post(
                f"{self.valves.qdrant_url}/collections/{self.valves.collection}/points/search",
                json={
                    "vector": vec,
                    "limit": self.valves.top_k,
                    "with_payload": True,
                    "score_threshold": self.valves.score_threshold,
                    "filter": {
                        "must": [
                            {"key": "user_id", "match": {"value": self.valves.user_id}}
                        ]
                    },
                },
                timeout=self.valves.timeout,
            )
            r.raise_for_status()
            hits = r.json().get("result", [])
            # payload text lives under .payload.data (confirmed against live store)
            return [
                h["payload"]["data"] for h in hits if h.get("payload", {}).get("data")
            ]
        except Exception as e:
            self._log("recall failed:", e)
            return []

    def _store(self, text: str):
        """Inferred store via OpenMemory REST. Fire-and-forget; never breaks the chat."""
        try:
            requests.post(
                f"{self.valves.openmemory_url}/api/v1/memories/",
                json={
                    "user_id": self.valves.user_id,
                    "text": text,
                    "infer": self.valves.infer,
                },
                timeout=self.valves.timeout,
            )
        except Exception as e:
            self._log("store failed:", e)

    # ---------- Open WebUI hooks ----------
    def inlet(self, body: dict, __user__: Optional[dict] = None) -> dict:
        """Prefix the LAST user message with recalled memories (survives prompt truncation)."""
        try:
            messages = body.get("messages", [])
            last_idx = next(
                (
                    i
                    for i in range(len(messages) - 1, -1, -1)
                    if messages[i].get("role") == "user"
                ),
                None,
            )
            if last_idx is None:
                return body
            last_user = messages[last_idx]
            query = _text_of(last_user)
            if not query.strip():
                return body

            memories = self._recall(query)
            if not memories:
                return body

            clip = self.valves.max_chars_per_memory
            block = (
                "[Recalled from the user's long-term memory. These facts are authoritative and "
                "current: treat them as ground truth even if they conflict with your training "
                "knowledge, never correct or flag them as typos, and use them naturally without "
                "mentioning this list.]\n"
                + "\n".join(f"- {m[:clip]}" for m in memories)
                + "\n[End of recalled memory. The user's message follows.]\n\n"
            )
            content = last_user.get("content", "")
            if isinstance(content, list):  # multimodal: prefix the first text part
                for part in content:
                    if isinstance(part, dict) and part.get("type") == "text":
                        part["text"] = block + part.get("text", "")
                        break
                else:
                    content.insert(0, {"type": "text", "text": block})
            else:
                last_user["content"] = block + (content or "")
            body["messages"] = messages
            self._log(f"injected {len(memories)} memories")
        except Exception as e:
            self._log("inlet error:", e)
        return body

    def outlet(self, body: dict, __user__: Optional[dict] = None) -> dict:
        """After the assistant replies, store the user+assistant exchange (inferred)."""
        if not self.valves.store_enabled:
            return body
        try:
            messages = body.get("messages", [])
            last_user = next(
                (m for m in reversed(messages) if m.get("role") == "user"), None
            )
            last_asst = next(
                (m for m in reversed(messages) if m.get("role") == "assistant"), None
            )
            if not last_user:
                return body
            u = _text_of(last_user)
            if len(u.strip()) < self.valves.min_chars_to_store:
                return body
            a = _text_of(last_asst) if last_asst else ""
            # store the exchange; mem0 extracts durable facts from it
            self._store(f"User: {u}\nAssistant: {a}".strip())
            self._log("stored exchange")
        except Exception as e:
            self._log("outlet error:", e)
        return body
