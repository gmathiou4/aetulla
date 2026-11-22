#!/usr/bin/env python3
"""Resolve "latest stable" versions from official sources. Read-only; prints one answer per call.

Run with `python3 -I lib/resolve.py <command> ...` (isolated mode). stdlib only.
Exit 0 = answer on stdout; exit 1 = could not resolve (reason on stderr). Callers treat that
as "skipped (unresolved)", never as a reason to guess.

Stable means: an official release marked neither pre-release nor draft, whose version is
strictly MAJOR.MINOR.PATCH (so no -rc/-beta/-nightly), or a registry tag of that same shape.
The floating `latest` tag is only ever used to find a digest, and the digest is what we pin.

Tests set AET_RESOLVE_FIXTURES=<dir>: every URL is then read from <dir>/<sanitised url> instead
of the network (tests/resolve_test.sh).
"""
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request

UA = "aetulla-update"  # generic client name on purpose: nothing about the user goes in a request
FIX = os.environ.get("AET_RESOLVE_FIXTURES")
SEMVER = re.compile(r"^\d+\.\d+\.\d+$")


_TOKEN = [False, None]   # [resolved?, token]


def github_token():
    """GITHUB_TOKEN / GH_TOKEN, else `gh auth token`. Cached, never printed, never logged, and only
    ever attached to requests for https://api.github.com/ (see fetch)."""
    if not _TOKEN[0]:
        tok = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
        src = "env" if tok else None
        if not tok:
            try:
                r = subprocess.run(["gh", "auth", "token"], capture_output=True, text=True, timeout=10)
                tok = r.stdout.strip() if r.returncode == 0 and r.stdout.strip() else None
                src = "gh" if tok else None
            except (OSError, subprocess.SubprocessError):
                tok = None
        _TOKEN[0], _TOKEN[1] = True, (tok, src)
    return _TOKEN[1] or (None, None)


def fail(msg):
    print(msg, file=sys.stderr)
    sys.exit(1)


def vkey(v):
    return tuple(int(x) for x in v.split("."))


def fetch(url, accept=None, headers=False):
    """Return body text (and response headers when headers=True)."""
    if FIX:
        p = os.path.join(FIX, re.sub(r"[^A-Za-z0-9._-]", "_", url))
        try:
            body = open(p).read()
        except OSError:
            fail(f"fixture missing: {p}")
        return (body, {}) if headers else body
    hdrs = {"User-Agent": UA, **({"Accept": accept} if accept else {})}
    if url.startswith("https://api.github.com/"):          # the token goes to GitHub's API and nowhere else
        tok = github_token()[0]
        if tok:
            hdrs["Authorization"] = f"Bearer {tok}"
    req = urllib.request.Request(url, headers=hdrs)
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            body = r.read().decode()
            return (body, dict(r.headers)) if headers else body
    except urllib.error.HTTPError as e:
        if e.code in (403, 429) and e.headers.get("X-RateLimit-Remaining") == "0":
            fail("GitHub API rate limit exceeded (anonymous = 60/h): set GITHUB_TOKEN or run `gh auth login`")
        fail(f"GET {url}: HTTP {e.code}")
    except (urllib.error.URLError, TimeoutError) as e:
        fail(f"GET {url}: {e}")


def cmd_github_rate():
    """Remaining GitHub API calls (this endpoint is free). Never prints the token."""
    d = json.loads(fetch("https://api.github.com/rate_limit"))["resources"]["core"]
    src = github_token()[1]
    print(f"{d['remaining']}/{d['limit']} remaining, {'authenticated via ' + src if src else 'ANONYMOUS (60/h)'}")


def cmd_github_latest(repo):
    """The release the maintainers promote as Latest (GitHub excludes pre-releases and drafts)."""
    d = json.loads(fetch(f"https://api.github.com/repos/{repo}/releases/latest"))
    if d.get("prerelease") or d.get("draft"):
        fail(f"{repo}: 'latest' release is a pre-release/draft")
    v = d["tag_name"].split("@")[-1].lstrip("v")  # n8n tags look like n8n@2.45.5
    if not SEMVER.match(v):
        fail(f"{repo}: latest tag {d['tag_name']!r} is not MAJOR.MINOR.PATCH")
    print(v)


N8N_API = os.environ.get("N8N_VERSIONS_API", "https://api.n8n.io/api/versions/")  # n8n's own default


def n8n_newer(cur):
    """Versions n8n's own update notifier lists as newer than `cur` (what its UI banner counts).
    Only the version number goes in the URL; no instance id or other data is sent."""
    d = json.loads(fetch(N8N_API.rstrip("/") + "/" + cur))
    if not isinstance(d, list):
        fail(f"n8n versions API: expected a list, got {type(d).__name__}")
    # the endpoint also echoes `cur` itself: keep strictly newer, plain MAJOR.MINOR.PATCH only
    return [e for e in d if isinstance(e, dict) and SEMVER.match(str(e.get("name", "")))
            and vkey(e["name"]) > vkey(cur)]


def cmd_n8n_versions(cur):
    """Debug/preview: one line per newer stable version n8n announces."""
    for e in sorted(n8n_newer(cur), key=lambda e: vkey(e["name"])):
        flags = [k for k in ("hasBreakingChange", "hasSecurityFix", "hasSecurityIssue") if e.get(k)]
        print(e["name"], str(e.get("createdAt", "?"))[:10], ",".join(flags) or "-")


def cmd_n8n_latest(cur):
    """Newest version n8n itself calls stable; if nothing is newer, `cur` is already latest."""
    new = n8n_newer(cur)
    print(max((e["name"] for e in new), key=vkey) if new else cur)


def hub_tags(repo, prefix):
    """All tags of a Docker Hub repo shaped <prefix>MAJOR.MINOR.PATCH (follows pagination)."""
    url = f"https://hub.docker.com/v2/repositories/{repo}/tags?page_size=100&name={prefix}"
    out, pages = set(), 0
    while url and pages < 30:
        d = json.loads(fetch(url))
        for t in d.get("results", []):
            n = t["name"]
            if n.startswith(prefix) and SEMVER.match(n[len(prefix):]):
                out.add(n[len(prefix):])
        url, pages = d.get("next"), pages + 1
    if not out:
        fail(f"{repo}: no {prefix}X.Y.Z tags found")
    return sorted(out, key=vkey)


def cmd_hub_latest(repo, prefix=""):
    print(hub_tags(repo, prefix)[-1])


def cmd_hub_tags(repo, prefix=""):
    print("\n".join(hub_tags(repo, prefix)))


def cmd_hub_digest(repo, tag):
    """Manifest(-list) digest of a tag: what `docker pull repo@digest` accepts."""
    d = json.loads(fetch(f"https://hub.docker.com/v2/repositories/{repo}/tags/{tag}"))
    dig = d.get("digest")
    if not dig or not dig.startswith("sha256:"):
        fail(f"{repo}:{tag}: no digest in registry answer")
    print(dig)


def qdrant_steps(cur, target, versions):
    """Upgrade path: for every minor from cur's minor up to target's, the newest patch of that
    minor; the last step is exactly target. Qdrant supports upgrading one minor at a time."""
    cur, target = vkey(cur), vkey(target)
    if cur >= target:
        return []
    steps = []
    for minor in sorted({v[:2] for v in map(vkey, versions) if cur[:2] <= v[:2] <= target[:2]}):
        in_minor = [v for v in map(vkey, versions) if v[:2] == minor and v <= target]
        if in_minor:
            steps.append(max(in_minor))
    steps = [s for s in steps if s > cur]
    if not steps or steps[-1] != target:
        steps.append(target)
    return [".".join(map(str, s)) for s in steps]


def cmd_qdrant_path(cur, target):
    versions = [l.strip() for l in sys.stdin if l.strip()]
    print(" ".join(qdrant_steps(cur, target, versions)))


def cmd_owui_playwright(version):
    """Playwright version Open WebUI vX bundles (its requirements.txt at that tag)."""
    txt = fetch(f"https://raw.githubusercontent.com/open-webui/open-webui/v{version}/backend/requirements.txt")
    m = re.search(r"^playwright==([0-9][0-9.]*)", txt, re.M)
    if not m:
        fail(f"open-webui v{version}: no playwright pin in requirements.txt")
    print(m.group(1))


def ollama_manifest_url(name):
    """ollama model name -> registry manifest URL (library/, namespaced and host-prefixed forms)."""
    base, _, tag = name.rpartition(":") if ":" in name.rsplit("/", 1)[-1] else (name, "", "latest")
    host, path = split_model(base)
    return f"https://{host}/v2/{path}/manifests/{tag}"


def split_model(base):
    """'qwen2.5' -> registry.ollama.ai, library/qwen2.5 ; 'hf.co/ns/m' -> hf.co, ns/m.
    A first segment is a host only if more path follows it (so 'qwen2.5:7b' is NOT a host)."""
    parts = base.split("/")
    if len(parts) > 1 and ("." in parts[0] or ":" in parts[0]):
        return parts[0], "/".join(parts[1:])
    if len(parts) == 1:
        parts = ["library"] + parts
    return "registry.ollama.ai", "/".join(parts)


def local_manifest(name):
    """Path of the locally stored manifest of an Ollama model, or None if unreadable.
    Candidates: $OLLAMA_MODELS, the systemd-service default, the per-user default."""
    base, _, tag = name.rpartition(":") if ":" in name.rsplit("/", 1)[-1] else (name, "", "latest")
    host, path = split_model(base)
    # Ollama >= 0.3x keeps new/re-created models under manifests-v2/<host> (registry.ollama.ai is called
    # ollama.com there); older pulls stay under manifests/<host>. If a model exists in both, the NEWER
    # file is the current one.
    host_v2 = {"registry.ollama.ai": "ollama.com"}.get(host, host)
    found = []
    for d in (os.environ.get("OLLAMA_MODELS"), "/usr/share/ollama/.ollama/models",
              os.path.expanduser("~/.ollama/models")):
        if not d:
            continue
        for p in (os.path.join(d, "manifests", host, path, tag),
                  os.path.join(d, "manifests-v2", host_v2, path, tag)):
            if os.access(p, os.R_OK):
                found.append(p)
    return max(found, key=os.path.getmtime) if found else None


def cmd_local_config(name):
    """12-hex config digest of the LOCAL model. NOT the ID `ollama list` shows: that ID is derived
    differently across Ollama versions/models (manifest hash for old pulls, a layer for new ones),
    whereas the config digest is what the registry manifest carries too, so the two are comparable."""
    p = local_manifest(name)
    if not p:
        fail(f"{name}: local manifest not readable")
    print(json.load(open(p))["config"]["digest"].split(":")[-1][:12])


def cmd_ollama_model(name):
    """Prints '<config-digest first 12 hex> <total layer bytes>' of the remote model."""
    body = fetch(ollama_manifest_url(name),
                 accept="application/vnd.docker.distribution.manifest.v2+json")
    m = json.loads(body)
    cfg = m["config"]["digest"].split(":")[-1][:12]
    size = m["config"].get("size", 0) + sum(l.get("size", 0) for l in m.get("layers", []))
    print(cfg, size)


COMMANDS = {
    "github-latest": (cmd_github_latest, 1),
    "github-rate": (cmd_github_rate, 0),
    "n8n-versions": (cmd_n8n_versions, 1),
    "n8n-latest": (cmd_n8n_latest, 1),
    "hub-latest": (cmd_hub_latest, (1, 2)),
    "hub-tags": (cmd_hub_tags, (1, 2)),
    "hub-digest": (cmd_hub_digest, 2),
    "qdrant-path": (cmd_qdrant_path, 2),
    "owui-playwright": (cmd_owui_playwright, 1),
    "ollama-model": (cmd_ollama_model, 1),
    "local-config": (cmd_local_config, 1),
}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        fail("usage: resolve.py {" + "|".join(COMMANDS) + "} ARGS...")
    fn, n = COMMANDS[sys.argv[1]]
    args = sys.argv[2:]
    if len(args) not in (n if isinstance(n, tuple) else (n,)):
        fail(f"{sys.argv[1]}: wrong number of arguments")
    try:
        fn(*args)
    except (KeyError, ValueError, json.JSONDecodeError) as e:
        fail(f"{sys.argv[1]} {' '.join(args)}: unexpected answer ({type(e).__name__}: {e})")
