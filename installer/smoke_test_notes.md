# Task 14 — Playwright UI smoke test notes

**Status: PASSED on macOS (M1, Docker Desktop).** Completed via a browser
automation tool (Chrome extension bridge) after the originally-planned
Playwright MCP tool hit a *different* blocker on this machine (its own
extension-bridge mode never connected — not the WSL2 chrome-binary/root
issue, since Chrome was already installed here). Steps: created the first
admin account via `POST /api/v1/auths/signup` (same "first account = admin"
flow a real user follows), logged in through the actual sign-in page,
selected "Qwen 2.5 (Memory)" from the model picker, and asked "What is my
memory namespace?" in a live chat turn. Response: **"Your memory namespace
is default_user."** — correct, matching the one memory seeded by `setup.sh`.
Screenshot saved locally at
`/var/folders/_c/qxw68kl56hb9p09_fhsr5c000000gn/T/claude-chrome-screenshots-j8ISeK/screenshot-1784406770700-0.jpg`
(not committed — machine-local temp path).

## Original WSL2 blocker (for history — did not reproduce here)

The Playwright MCP browser tool was hardcoded to the `chrome` channel (not
bundled Chromium) and required Google Chrome installed at
`/opt/google/chrome/chrome`. Installing it
(`npx playwright install chrome --with-deps`) required root
(`apt-get install google-chrome-stable`), and that environment had no
passwordless sudo — the install could not be completed non-interactively.
Installing plain Chromium (`npx playwright install chromium`, no root needed)
succeeded but the MCP tool did not fall back to it; it errored on the `chrome`
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
  /api/v1/memories/filter` for `user_id=default_user` returns the memories stored
  during this session's testing (e.g. synthetic facts like "Likes hiking",
  "Reads science fiction novels"), confirming the backend recall path
  returns real data a chat turn's `inlet()` would inject.
- **setup.sh's own end-to-end verification (Task 13):** ran the full wizard
  against a scratch clone, which includes an automated recall check
  functionally equivalent to what this task would confirm by hand in a
  browser (seed write → wait → recall → assert content present).

## What is now verified (previously the UI-level gap, closed on macOS)

- Open WebUI's frontend correctly renders the model picker with the seeded
  "Qwen 2.5 (Memory)" model selectable — confirmed visually.
- A live chat turn through the actual browser UI (not a direct API call)
  triggers the filter's `inlet()`/`outlet()` hooks and the model's response
  visibly reflects injected memory content — confirmed, response text
  quoted above.
- Login flow / admin session behavior in the browser — confirmed (signup →
  sign-in page → logged-in session persisted through the chat turn).

## Still open

- Not re-verified against the Playwright MCP tool specifically, only a
  Chrome-extension-based browser automation tool — if the Playwright MCP's
  extension-bridge mode gets connected later, worth a quick re-run to
  confirm parity, but not blocking since the underlying product behavior
  (not the test tooling) is what actually matters here.
