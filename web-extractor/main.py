"""
Web extractor sidecar for Open WebUI.

Receives a batch of URLs, fetches each via the existing Playwright container
(so JavaScript is executed and pages render fully), runs Trafilatura to strip
nav/footer/ads/cookie-banners, returns clean main-article text.

Contract: matches Open WebUI's ExternalWebLoader expectations.
  POST /load
  body: { "urls": ["...", ...] }   (max 20)
  returns: [ { "page_content": "...", "metadata": {...} }, ... ] in request order
"""

import asyncio
import logging
import os
from contextlib import asynccontextmanager
from typing import List, Optional

import trafilatura
from fastapi import FastAPI, HTTPException
from playwright.async_api import async_playwright, Browser
from pydantic import BaseModel, Field

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

PLAYWRIGHT_WS = os.environ.get("PLAYWRIGHT_WS", "ws://playwright:3000/")
PAGE_TIMEOUT_MS = int(os.environ.get("PAGE_TIMEOUT_MS", "30000"))      # 30s per page
MAX_URLS_PER_BATCH = int(os.environ.get("MAX_URLS_PER_BATCH", "20"))
MAX_CONTENT_CHARS = int(os.environ.get("MAX_CONTENT_CHARS", "6000"))   # cap per-source content; prevents one mega-page from drowning out the signal
CONCURRENCY = int(os.environ.get("CONCURRENCY", "3"))                  # parallel fetches

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("web-extractor")

# ---------------------------------------------------------------------------
# Models
# ---------------------------------------------------------------------------

class LoadRequest(BaseModel):
    urls: List[str] = Field(..., max_length=MAX_URLS_PER_BATCH)

class Document(BaseModel):
    page_content: str
    metadata: dict

# ---------------------------------------------------------------------------
# Playwright lifecycle — connect once at startup, reuse
# ---------------------------------------------------------------------------

_playwright_ctx = None
_browser: Optional[Browser] = None

@asynccontextmanager
async def lifespan(app: FastAPI):
    global _playwright_ctx, _browser
    log.info(f"Connecting to Playwright server at {PLAYWRIGHT_WS}")
    _playwright_ctx = await async_playwright().start()
    _browser = await _playwright_ctx.chromium.connect(PLAYWRIGHT_WS)
    log.info("Playwright connected, ready")
    yield
    log.info("Shutting down")
    if _browser:
        await _browser.close()
    if _playwright_ctx:
        await _playwright_ctx.stop()

app = FastAPI(title="web-extractor", lifespan=lifespan)

# ---------------------------------------------------------------------------
# Core: fetch one URL, extract clean text
# ---------------------------------------------------------------------------

async def fetch_and_extract(url: str) -> Document:
    """Fetch one URL via Playwright, extract main content with Trafilatura."""
    page = await _browser.new_page()
    try:
        await page.goto(url, timeout=PAGE_TIMEOUT_MS, wait_until="domcontentloaded")
        html = await page.content()
        title = await page.title()
    except Exception as e:
        log.warning(f"Fetch failed for {url}: {e}")
        return Document(
            page_content="",
            metadata={"source": url, "title": "", "error": str(e)},
        )
    finally:
        await page.close()

    # Trafilatura does structure-aware main-content extraction.
    # Strips nav/footer/sidebar/comments/ads. Returns plain text.
    clean = trafilatura.extract(
        html,
        include_comments=False,
        include_tables=True,        # tables often hold key facts (specs, scores)
        no_fallback=False,           # if heuristics fail, fall back to basic extraction
        favor_recall=True,           # prefer keeping more content over aggressive stripping
        output_format="markdown",   # preserve table structure for infoboxes / spec tables
    )

    if not clean:
        # Trafilatura found nothing usable. Don't pass nav garbage to the LLM —
        # return empty so the RAG template's "insufficient context" rule fires.
        log.info(f"Trafilatura returned no content for {url} (page may be SPA/empty)")
        return Document(
            page_content="",
            metadata={"source": url, "title": title, "error": "no_main_content"},
        )

    if len(clean) > MAX_CONTENT_CHARS:
        clean = clean[:MAX_CONTENT_CHARS] + "\n\n[... truncated]"
        log.info(f"Truncated to {MAX_CONTENT_CHARS} chars from {url}")
    else:
        log.info(f"Extracted {len(clean)} chars from {url}")
    return Document(
        page_content=clean,
        metadata={"source": url, "title": title},
    )

# ---------------------------------------------------------------------------
# Endpoint
# ---------------------------------------------------------------------------

@app.post("/load", response_model=List[Document])
async def load_urls(req: LoadRequest):
    if not _browser:
        raise HTTPException(status_code=503, detail="Playwright not connected")

    # Bounded concurrency — don't slam Playwright server with 20 parallel pages
    sem = asyncio.Semaphore(CONCURRENCY)

    async def bounded(url: str) -> Document:
        async with sem:
            return await fetch_and_extract(url)

    # Preserve request order — Open WebUI expects results[i] to match urls[i]
    results = await asyncio.gather(
        *(bounded(u) for u in req.urls),
        return_exceptions=False,
    )
    return results

@app.get("/health")
async def health():
    return {"status": "ok", "browser_connected": _browser is not None}
