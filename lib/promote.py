#!/usr/bin/env python3
"""Promote a healthy resolved.lock into the repo: versions.lock + the ${VAR:-default}s in docker-compose.yml.

usage: promote.py RESOLVED_LOCK VERSIONS_LOCK COMPOSE_FILE [--check]

After this, a bare `docker compose up` (no --env-file) resolves exactly what is installed, so it can
never start an older image than the migrated DBs expect. Only the keys in PROMOTE_KEYS are touched;
comments, ordering and every other line stay as they are. Writes are atomic (temp file + rename).
--check changes nothing: exit 1 and list the drift if the three files disagree (used by the tests).
"""
import os
import re
import sys

# The tested set. IMG_*/MODEL_*/OLLAMA_VERSION in resolved.lock are state, not pins: never promoted.
PROMOTE_KEYS = [
    "OPENWEBUI_VERSION", "N8N_VERSION", "QDRANT_VERSION", "CURL_VERSION",
    "PLAYWRIGHT_VERSION", "PY_BASE_DIGEST", "MEM0_BASE_DIGEST", "STT_BASE_DIGEST",
]
VALUE = re.compile(r"^(?:\d+\.\d+\.\d+|sha256:[0-9a-f]{64})$")  # refuse anything that is not plain X.Y.Z / a digest


def read_kv(path):
    out = {}
    for line in open(path):
        m = re.match(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line.rstrip("\n"))
        if m:
            out[m.group(1)] = m.group(2)
    return out


def atomic_write(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.chmod(tmp, os.stat(path).st_mode & 0o777)
    os.replace(tmp, path)


def compose_defaults(text, key):
    return re.findall(r"\$\{" + key + r":-([^}]*)\}", text)


def main():
    args = [a for a in sys.argv[1:] if a != "--check"]
    check = "--check" in sys.argv[1:]
    if len(args) != 3:
        sys.exit(__doc__)
    resolved, vlock, compose = args
    want = read_kv(resolved)
    drift = []
    vtext, ctext = open(vlock).read(), open(compose).read()
    for k in PROMOTE_KEYS:
        v = want.get(k)
        if not v:
            continue  # an older resolved.lock may lack a key: keep the committed value
        if not VALUE.match(v):
            sys.exit(f"refusing to promote {k}={v!r}: not a plain X.Y.Z version or sha256 digest")
        have_lock = read_kv(vlock).get(k)
        if have_lock != v:
            drift.append(f"versions.lock {k}: {have_lock} -> {v}")
        vtext = re.sub(rf"^{k}=.*$", f"{k}={v}", vtext, flags=re.M)
        for d in set(compose_defaults(ctext, k)):
            if d != v:
                drift.append(f"docker-compose.yml {k}: {d} -> {v}")
        ctext = re.sub(r"(\$\{" + k + r":-)[^}]*(\})", lambda m: m.group(1) + v + m.group(2), ctext)
    for line in drift:
        print(("DRIFT " if check else "  ") + line)
    if check:
        sys.exit(1 if drift else 0)
    if drift:
        atomic_write(vlock, vtext)
        atomic_write(compose, ctext)
    print(f"promoted {len(drift)} change(s)" if drift else "nothing to promote: defaults already match")


main()
