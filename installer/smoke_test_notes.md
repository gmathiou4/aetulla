# Task 14 — Playwright UI smoke test notes

**Status: BLOCKED, not executed.** The Playwright MCP browser tool is hardcoded
to the `chrome` channel (not bundled Chromium) and requires Google Chrome
installed at `/opt/google/chrome/chrome`. Installing it
(`npx playwright install chrome --with-deps`) requires root
(`apt-get install google-chrome-stable`), and this environment has no
passwordless sudo — the install cannot be completed non-interactively.
Installing plain Chromium (`npx playwright install chromium`, no root needed)
succeeded but the MCP tool does not fall back to it; it errors on the `chrome`
channel specifically regardless.

## What was independently verified instead (this session, via direct
## API/DB checks rather than the browser)

- **Memory recall path (the thing this smoke test exists to prove):**
  confirmed the installed Mem0 filter's `inlet()` hook goes straight to
  Qdrant `/points/search` for recall and `outlet()` is a `POST` for storage
  — neither goes through the broken `list_memories` endpoint. Read the
  filter's actual source from `webui.db` to confirm this (see Task 7 notes
  in `.superpowers/sdd/progress.md`).
- **Seeded function + model are active:** `docker exec open-webui python3 -c
  "..."` against the live `webui.db` confirms `function('mem0_memory', 1)`
  and `model('qwen-25-memory', ..., 1)` — both `is_active=1`.
- **End-to-end recall against real stored memories:** `POST
  /api/v1/memories/filter` for `user_id=yorgos` returns the memories stored
  during this session's testing (e.g. synthetic facts like "Likes hiking",
  "Reads science fiction novels"), confirming the backend recall path
  returns real data a chat turn's `inlet()` would inject.
- **setup.sh's own end-to-end verification (Task 13):** ran the full wizard
  against a scratch clone, which includes an automated recall check
  functionally equivalent to what this task would confirm by hand in a
  browser (seed write → wait → recall → assert content present).

## What is NOT verified by the above (the actual UI-level gap)

- That Open WebUI's frontend correctly renders the model picker with the
  seeded "Qwen 2.5 (Memory)" model selectable.
- That a live chat turn through the actual browser UI (not a direct API
  call) triggers the filter's `inlet()`/`outlet()` hooks and the model's
  response visibly reflects injected memory content.
- Login flow / admin session behavior in the browser.

## To complete this task later

1. Fix the Playwright MCP browser (either install Chrome as root, or
   reconfigure the MCP server to use the `chromium` channel instead of
   `chrome` — the browser binary itself downloads fine without root).
2. Navigate to `http://localhost:3000`, log in as admin, select "Qwen 2.5
   (Memory)", ask a question matching one of the memories already stored for
   `user_id=yorgos` (check `POST /api/v1/memories/filter` first to see
   what's currently there), and assert the response reflects it — using an
   existing stored memory rather than an artificial seed fact, since the
   live stack doesn't currently have the Task 13 scratch-test's "memory
   namespace" seed sentence — that was only ever written into the disposable
   scratch-clone stack, which was torn down after validation.
3. Record pass/fail and any screenshot path here.
