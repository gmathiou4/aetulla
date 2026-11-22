#!/usr/bin/env bash
# Shared logic for bin/aetulla (update / rollback / status / up). Sourced, never run.
#
# Rules this file enforces:
#   * The image tags in docker-compose.yml ARE the tested version set. Nothing floats.
#   * User state = .env + named volumes. Nothing here overwrites either without a backup.
#   * Never a bare `docker compose up`: services are always named (CORE_SERVICES).
#   * Health checks are READ-ONLY (no memory writes, no chat/LLM calls).
#   * Ollama is never upgraded or restarted; we only report if it is old.
#   * No API keys. Network is optional: offline => say so and exit 0.
#   * bash 3.2 compatible (macOS): no associative arrays, no mapfile.

# --- helpers (never eval, never print env values) ----------------------------
env_get() { # env_get FILE KEY [DEFAULT]
    local v
    v=$(grep -m1 -E "^$2=" "$1" 2>/dev/null | cut -d= -f2-)
    v="${v%\"}"; v="${v#\"}"
    echo "${v:-${3:-}}"
}

# --- constants ---------------------------------------------------------------
AET_ROOT="${AET_ROOT:?AET_ROOT must be set by bin/aetulla}"
AET_COMPOSE="$AET_ROOT/docker-compose.yml"
AET_OVERRIDES=()         # compose override files, set during rollback (pins the previous images)
AET_PROJECT="${COMPOSE_PROJECT_NAME:-$(basename "$AET_ROOT" | tr '[:upper:]' '[:lower:]')}"
# Settings: process env wins, then .env, then the default.
AET_BACKUP_ROOT="${AETULLA_BACKUP_DIR:-$(env_get "$AET_ROOT/.env" AETULLA_BACKUP_DIR "$HOME/.aetulla/backups")}"
AET_BACKUP_ROOT="${AET_BACKUP_ROOT/#\~/$HOME}"
AET_BACKUP_KEEP="${AETULLA_BACKUP_KEEP:-$(env_get "$AET_ROOT/.env" AETULLA_BACKUP_KEEP 3)}"
AET_MIN_FREE_KB=$((6 * 1024 * 1024))     # images (~4 GB) + a copy of the DBs
# Everything `up` and `update` touch. voice-profile services (stt, tts) are not here on purpose.
CORE_SERVICES=(mem0_store ollama-keepalive playwright web-extractor mem0 open-webui n8n)
VERSIONED_SERVICES=(open-webui n8n mem0_store ollama-keepalive)   # image comes from a registry
LOCAL_BUILDS=(mem0 web-extractor playwright)                      # image built here from this repo

if [[ -t 1 ]]; then C_R=$'\033[0;31m'; C_G=$'\033[0;32m'; C_Y=$'\033[1;33m'; C_0=$'\033[0m'; else C_R=; C_G=; C_Y=; C_0=; fi
ok()   { echo "${C_G}✓${C_0} $*"; }
bad()  { echo "${C_R}✗${C_0} $*"; }
warn() { echo "${C_Y}!${C_0} $*"; }
info() { echo "  $*"; }
die()  { bad "$*"; exit 1; }

# --- helpers (never eval, never print env values) ----------------------------
dc() {
    local f args=(-f "$AET_COMPOSE")
    for f in "${AET_OVERRIDES[@]}"; do args+=(-f "$f"); done
    # channel latest: the working lockfile is an extra env file (later wins, so it overrides the
    # ${VAR:-default}s in compose). .env must then be listed explicitly: --env-file turns off auto-load.
    local envf=(); [[ -n "${AET_LOCKFILE:-}" ]] && envf=(--env-file "$AET_ROOT/.env" --env-file "$AET_LOCKFILE")
    docker compose --project-directory "$AET_ROOT" "${envf[@]}" "${args[@]}" "$@"
}
vol() { echo "${AET_PROJECT}_$1"; }
# URL for host-side calls to Ollama (containers use host.docker.internal; the host cannot resolve it).
ollama_url() { env_get "$AET_ROOT/.env" OLLAMA_BASE_URL "http://127.0.0.1:11434" | sed 's/host\.docker\.internal/127.0.0.1/'; }
net_ok() { curl -fsS -m 5 -o /dev/null "${AETULLA_CHECK_URL:-https://github.com}" 2>/dev/null; }
is_running() { [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]; }
fmt_size() { du -sh "$1" 2>/dev/null | cut -f1; }
latest_backup() { find "$AET_BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '2*' 2>/dev/null | sort | tail -1; }

# --- version bookkeeping: the compose file is the source of truth --------------
# Resolved compose model as JSON. Only ever piped into extractors; it contains secrets.
cfg_json() { dc --profile voice config --format json 2>/dev/null; }   # --profile voice: list stt/tts too (never starts them)
compose_image() { # compose_image SERVICE -> image reference the tree wants
    cfg_json | S="$1" python3 -I -c 'import json,os,sys;print(json.load(sys.stdin)["services"][os.environ["S"]].get("image",""))'
}
ctr_image() { docker inspect -f '{{.Config.Image}}' "$1" 2>/dev/null; }
tag_of() { echo "${1##*:}" | sed -e 's/^v//' -e 's/-noble$//'; }
# Name of the locally built image of a service (explicit `image:`, else compose's <project>-<service>).
local_image_name() { local i; i=$(compose_image "$1"); echo "${i:-${AET_PROJECT}-$1}"; }
# PLAYWRIGHT_VERSION baked into a container's image (Dockerfile ENV); empty if unknown.
ctr_pw_version() { docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$1" 2>/dev/null | sed -n 's/^PLAYWRIGHT_VERSION=//p'; }

# Playwright server and web-extractor client are built from the same build arg (reads compose JSON
# on stdin). Prints: server-arg client-arg. Fails if either is missing or the server still uses npx.
pins_from_json() {
    python3 -I -c '
import json, sys
s = json.load(sys.stdin)["services"]
cmd = s["playwright"].get("command") or ""
cmd = " ".join(cmd) if isinstance(cmd, list) else cmd
if "npx" in cmd: sys.exit("playwright command must not use npx (version would live outside the image)")
print(s["playwright"]["build"]["args"]["PLAYWRIGHT_VERSION"], s["web-extractor"]["build"]["args"]["PLAYWRIGHT_VERSION"])'
}

# Write what is installed right now: an override file that pins the old images (rollback target).
snapshot_images() { # snapshot_images OUT.yml
    local out=$1 s img
    { echo "services:"
      for s in "${VERSIONED_SERVICES[@]}"; do
          img=$(ctr_image "$s"); [[ -n "$img" ]] && printf '  %s:\n    image: %s\n' "$s" "$img"
      done
      # Legacy install (before playwright was a local build): registry image + npx command.
      # restore_local_images does not cover it; do_rollback adds the matching command.
      img=$(ctr_image playwright)
      [[ "$img" == mcr.microsoft.com/playwright:* ]] && printf '  playwright:\n    image: %s\n' "$img"; } > "$out"
}
versions_match_running() { # 0 if every core container runs the images/versions the tree pins
    local c want
    for c in "${CORE_SERVICES[@]}"; do is_running "$c" || return 1; done
    for c in "${VERSIONED_SERVICES[@]}"; do
        [[ "$(ctr_image "$c")" == "$(compose_image "$c")" ]] || return 1
    done
    want=$(cfg_json | pins_from_json | cut -d' ' -f1)
    for c in playwright web-extractor; do [[ "$(ctr_pw_version "$c")" == "$want" ]] || return 1; done
}

# --- git guard (dev checkouts never move) ----------------------------------
# Sets GIT_MODE=release|dev and GIT_REASON.
git_mode() {
    local tag
    if ! git -C "$AET_ROOT" rev-parse --git-dir >/dev/null 2>&1; then GIT_MODE=dev; GIT_REASON="not a git checkout"; return; fi
    if ! tag=$(git -C "$AET_ROOT" describe --exact-match --tags HEAD 2>/dev/null); then
        GIT_MODE=dev; GIT_REASON="not on a release tag (HEAD $(git -C "$AET_ROOT" rev-parse --short HEAD))"; return
    fi
    if [[ -n "$(git -C "$AET_ROOT" status --porcelain --untracked-files=no)" ]]; then
        GIT_MODE=dev; GIT_REASON="uncommitted changes on $tag"; return
    fi
    GIT_MODE=release; GIT_REASON="on release tag $tag"
}

# --- preflight ------------------------------------------------------------
check_ollama() { curl -fsS -m 5 "$(ollama_url)/api/version" >/dev/null 2>&1; }

check_playwright_pin() {
    local server client img have
    read -r server client < <(cfg_json | pins_from_json) || { bad "cannot read Playwright pins from docker-compose.yml"; return 1; }
    [[ -n "$server" && "$server" == "$client" ]] || { bad "Playwright build args disagree: server=$server web-extractor=$client"; return 1; }
    img=$(compose_image open-webui)
    docker image inspect "$img" >/dev/null 2>&1 || docker pull -q "$img" >/dev/null 2>&1 \
        || { bad "cannot get $img to verify its Playwright version"; return 1; }
    have=$(docker run --rm --network none --entrypoint python3 "$img" \
        -c 'import importlib.metadata as m;print(m.version("playwright"))' 2>/dev/null)
    if [[ "$have" != "$server" ]]; then
        bad "Playwright mismatch: compose builds $server, $img bundles ${have:-?}"; return 1
    fi
    ok "Playwright $server: server image, web-extractor client and Open WebUI's bundled client agree"
}

preflight_light() {
    docker info >/dev/null 2>&1 || die "Docker daemon is not reachable (start Docker / Docker Desktop)"
    [[ -f "$AET_ROOT/.env" ]] || die ".env missing — run setup.sh first"
}
preflight() {
    preflight_light
    check_ollama || die "Ollama not reachable at $(ollama_url) (start it: sudo systemctl start ollama)"
    mkdir -p "$AET_BACKUP_ROOT" && chmod 700 "$AET_BACKUP_ROOT" 2>/dev/null
    local free; free=$(df -Pk "$AET_BACKUP_ROOT" | awk 'NR==2{print $4}')
    (( free >= AET_MIN_FREE_KB )) || die "need >= 6 GB free in $AET_BACKUP_ROOT (have $((free/1024/1024)) GB)"
    ok "preflight: docker up, Ollama reachable, $((free/1024/1024)) GB free"
}

# --- .env merge: add keys new in .env.example, never touch existing ones --
env_merge() {
    [[ -f "$AET_ROOT/.env.example" ]] || { echo "no .env.example"; return 0; }
    ENV="$AET_ROOT/.env" EX="$AET_ROOT/.env.example" python3 -I - <<'PY'
import os, re, datetime
key = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)=')
have = {m.group(1) for l in open(os.environ["ENV"]) if (m := key.match(l))}
add = [l for l in open(os.environ["EX"]) if (m := key.match(l)) and m.group(1) not in have]
if add:
    with open(os.environ["ENV"], "a") as f:
        f.write(f"\n# added by aetulla update {datetime.date.today()}\n")
        f.writelines(l if l.endswith("\n") else l + "\n" for l in add)
    print("added keys: " + ", ".join(key.match(l).group(1) for l in add))
else:
    print("no new keys")
PY
}

# --- backup ---------------------------------------------------------------
helper_image() { ctr_image open-webui || compose_image open-webui; }
vol_exists() { docker volume inspect "$(vol "$1")" >/dev/null 2>&1; }

backup_create() { # sets BK; writes meta.env, manifest.json, DB copies, files tgz, qdrant, images.prev.yml
    BK="$AET_BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BK" && chmod 700 "$BK"
    local helper cold=() mounts=() n
    helper=$(helper_image)
    for n in open-webui:webui mem0:mem0 n8n:n8n; do
        is_running "${n%%:*}" || cold+=("${n##*:}")
    done
    vol_exists open-webui_data && mounts+=(-v "$(vol open-webui_data):/v/webui")
    vol_exists mem0_data       && mounts+=(-v "$(vol mem0_data):/v/mem0")
    vol_exists n8n_data        && mounts+=(-v "$(vol n8n_data):/v/n8n")
    # Always the sqlite3 backup API (lib/dbfp.py): one self-contained file per DB, no WAL.
    # Running service => backed up through its live file; stopped => from a private copy.
    docker run --rm -i --network none --user 0 --entrypoint python3 "${mounts[@]}" -v "$BK:/out" \
        -v "$AET_ROOT/lib/dbfp.py:/lib/dbfp.py:ro" -e PYTHONPATH=/lib \
        -e COLD="$(IFS=,; echo "${cold[*]}")" -e OWNER="$(id -u):$(id -g)" "$helper" - <<'PY' || return 1
import os, json, tarfile
import dbfp
cold = set(filter(None, os.environ["COLD"].split(",")))
jobs = [("webui", "/v/webui/webui.db"), ("mem0", "/v/mem0/openmemory.db"), ("n8n", "/v/n8n/database.sqlite")]
man = {}
for name, src in jobs:
    if not os.path.exists(src):
        continue
    dst = f"/out/{name}.db"
    dbfp.backup_db(src, dst, live=name not in cold)
    fp = dbfp.fingerprint(dst)
    fp["bytes"] = os.path.getsize(dst)
    man[name] = fp
files = {}
if os.path.isdir("/v/webui"):
    with tarfile.open("/out/webui-files.tgz", "w:gz") as t:
        for d in ("uploads", "vector_db"):
            p = f"/v/webui/{d}"
            if os.path.isdir(p):
                t.add(p, arcname=d)
                files[d] = sum(os.path.getsize(os.path.join(r, f)) for r, _, fs in os.walk(p) for f in fs)
man["_files_bytes"] = files
# n8n: everything in its volume except the DB, notably `config` (the encryptionKey). Mode 600, names/sizes only.
man["_n8n_files"] = dbfp.backup_files_except("/v/n8n", "/out/n8n-files.tgz") if os.path.isdir("/v/n8n") else {}
json.dump(man, open("/out/manifest.json", "w"), indent=1)
for r, ds, fs in os.walk("/out"):
    for x in ds + fs: os.chown(os.path.join(r, x), *map(int, os.environ["OWNER"].split(":")))
bad = [n for n, v in man.items() if not n.startswith("_") and v["integrity"] != "ok"]
raise SystemExit(f"integrity_check failed: {bad}" if bad else 0)
PY
    # Qdrant is part of EVERY backup: while running, one API snapshot per collection (consistent, no
    # downtime) plus qdrant.state (collection / exact point count / vector config) so a restore can be
    # verified; a stopped store is tarred instead. The server-side snapshot is deleted once downloaded.
    local coll q snap cl
    coll=$(env_get "$AET_ROOT/.env" QDRANT_COLLECTION openmemory_default)
    q="http://127.0.0.1:$(env_get "$AET_ROOT/.env" QDRANT_HTTP_PORT 6333)"
    if is_running mem0_store && curl -fsS -m 5 "$q/readyz" >/dev/null 2>&1; then
        mkdir -p "$BK/qdrant"
        for cl in $(curl -fsS -m 10 "$q/collections" | python3 -I -c 'import sys,json;print(" ".join(c["name"] for c in json.load(sys.stdin)["result"]["collections"]))'); do
            if snap=$(curl -fsS -m 300 -X POST "$q/collections/$cl/snapshots" | python3 -I -c 'import sys,json;print(json.load(sys.stdin)["result"]["name"])') &&
               curl -fsS -m 600 -o "$BK/qdrant/$cl.snapshot" "$q/collections/$cl/snapshots/$snap"; then
                curl -fsS -m 30 -X DELETE "$q/collections/$cl/snapshots/$snap" >/dev/null 2>&1
            else
                bad "qdrant snapshot of collection '$cl' failed"; return 1
            fi
        done
        qd_state > "$BK/qdrant.state" 2>/dev/null
        echo "snapshot" > "$BK/qdrant.mode"
    elif vol_exists qdrant_data; then
        if docker run --rm --network none --user 0 --entrypoint sh -v "$(vol qdrant_data):/v:ro" -v "$BK:/out" "$helper" \
            -c "tar czf /out/qdrant_data.tgz -C /v . && chown $(id -u):$(id -g) /out/qdrant_data.tgz"; then
            echo "tar" > "$BK/qdrant.mode"
        else
            bad "qdrant volume tar failed"; return 1
        fi
    fi
    { echo "TS=$(basename "$BK")"; echo "GIT_MODE=$GIT_MODE"; echo "PREV_GIT_REF=$(git -C "$AET_ROOT" rev-parse HEAD 2>/dev/null)"
      echo "QDRANT_COLLECTION=$coll"; echo "PREV_QDRANT_IMAGE=$(ctr_image mem0_store)"; echo "PREV_PLAYWRIGHT=$(ctr_pw_version playwright)"; } > "$BK/meta.env"
    cp -p "$AET_ROOT/.env" "$BK/.env.bak"; chmod 600 "$BK/.env.bak"   # never in the repo root
    snapshot_images "$BK/images.prev.yml"
    # keep the images local builds were running, so rollback needs no rebuild/network
    local s id
    for s in "${LOCAL_BUILDS[@]}"; do
        [[ "$(ctr_image "$s")" == "$(local_image_name "$s")" ]] || continue   # legacy registry image: handled by the override
        id=$(docker inspect -f '{{.Image}}' "$s" 2>/dev/null) || continue
        docker tag "$id" "aetulla-rollback/$s:$(basename "$BK")" && echo "$s=$id" >> "$BK/local-images.env"
    done
    # retention: newest N survive (portable: no GNU head -n -N)
    find "$AET_BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '2*' | sort -r | tail -n +$((AET_BACKUP_KEEP + 1)) | while read -r old; do rm -rf "$old"; done
    ok "backup $BK ($(fmt_size "$BK"))"
    python3 -I - "$BK/manifest.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
for k, v in m.items():
    if k == "_files_bytes":
        print("    open-webui files: " + (", ".join(f"{d}={b/1e6:.1f} MB" for d, b in v.items()) or "none"))
    elif k == "_n8n_files":
        print("    n8n files (excl. DB, mode 600): " + (", ".join(f"{n} {b/1e3:.1f} kB" for n, b in v.items()) or "none"))
        if v and "config" not in v:
            print("    ! n8n volume has no 'config' file: the key then only exists in N8N_ENCRYPTION_KEY (.env)")
    else:
        print(f"    {k}.db  {v['bytes']/1e6:6.1f} MB  logical {v['logical'][:12]}  integrity {v['integrity']}  schema {v['version']}  tables {len(v['tables'])}")
PY
    # Qdrant: what is in this backup, with sizes and the counts a restore must reproduce
    local f c
    if [[ -d "$BK/qdrant" ]]; then
        for f in "$BK"/qdrant/*.snapshot; do
            [[ -e "$f" ]] || continue
            c=$(basename "$f" .snapshot)
            printf '    qdrant/%s  %s  %s\n' "$c" "$(fmt_size "$f")" "$(grep "^$c " "$BK/qdrant.state" 2>/dev/null | cut -d' ' -f2- | cut -c1-90)"
        done
        [[ -s "$BK/qdrant.state" ]] || warn "qdrant.state is empty (no collections yet?)"
    elif [[ -f "$BK/qdrant_data.tgz" ]]; then
        printf '    qdrant volume tar  %s\n' "$(fmt_size "$BK/qdrant_data.tgz")"
    else
        warn "NO Qdrant data in this backup (store not running and no qdrant_data volume)"
    fi
}

# --- restore (used by rollback) --------------------------------------------
# Put the locally built images (mem0, web-extractor, playwright) back under their compose names.
restore_local_images() { # restore_local_images BK
    local s id img
    [[ -f "$1/local-images.env" ]] || return 0
    while IFS='=' read -r s id; do
        [[ -n "$s" ]] || continue
        img=$(local_image_name "$s")
        [[ -n "$img" ]] && docker tag "$id" "$img"
    done < "$1/local-images.env"
}
restore_data() { # restore_data BK  (stack must be stopped). Hard gate: logical hash == manifest BEFORE start.
    local bk=$1 helper mounts=()
    helper=$(helper_image)
    vol_exists open-webui_data && mounts+=(-v "$(vol open-webui_data):/v/webui")
    vol_exists mem0_data       && mounts+=(-v "$(vol mem0_data):/v/mem0")
    vol_exists n8n_data        && mounts+=(-v "$(vol n8n_data):/v/n8n")
    docker run --rm -i --network none --user 0 --entrypoint python3 "${mounts[@]}" -v "$bk:/bk:ro" \
        -v "$AET_ROOT/lib/dbfp.py:/lib/dbfp.py:ro" -e PYTHONPATH=/lib -e ONLY="${RESTORE_ONLY:-}" "$helper" - <<'PY'
import os, json, shutil, tarfile
import dbfp
man = json.load(open("/bk/manifest.json"))
dest = {"webui": "/v/webui/webui.db", "mem0": "/v/mem0/openmemory.db", "n8n": "/v/n8n/database.sqlite"}
only = set(filter(None, os.environ.get("ONLY", "").split(",")))   # RESTORE_ONLY=webui: touch that service's data only
rc = 0
for name, v in man.items():
    if name not in dest or (only and name not in only): continue
    d = dest[name]
    def drop_journals():
        for sfx in ("-wal", "-shm"):                  # stale journals from the failed run
            if os.path.exists(d + sfx): os.remove(d + sfx)
    drop_journals()
    shutil.copyfile(f"/bk/{name}.db", d)
    drop_journals()
    ok, fp = dbfp.check_restored(d, v)
    rc |= (not ok)
    print(f"    {name}.db restored: logical {fp['logical'][:12]} {'== manifest' if ok else '!= MANIFEST ' + v['logical'][:12]}  integrity {fp['integrity']}")
if os.path.exists("/bk/webui-files.tgz") and (not only or "webui" in only):
    for sub in ("uploads", "vector_db"):             # move aside, extract, drop aside only on success
        p = f"/v/webui/{sub}"
        if os.path.exists(p): os.rename(p, p + ".aside")
    with tarfile.open("/bk/webui-files.tgz") as t: t.extractall("/v/webui")
    for sub in ("uploads", "vector_db"):
        if os.path.exists(f"/v/webui/{sub}.aside"): shutil.rmtree(f"/v/webui/{sub}.aside")
if os.path.exists("/bk/n8n-files.tgz") and (not only or "n8n" in only):
    print("    n8n files restored: " + ", ".join(dbfp.restore_files("/bk/n8n-files.tgz", "/v/n8n")))
raise SystemExit(rc)
PY
}

# Hard gate once services are healthy (read-only mounts, temp copies): integrity ok, same schema
# version, no table with fewer rows than the backup. The logical hash is informational: any
# service may write on boot, so "changed since restore" is reported, never a failure.
verify_after_health() { # verify_after_health BK
    local bk=$1 helper mounts=() i rc=1
    helper=$(helper_image)
    vol_exists open-webui_data && mounts+=(-v "$(vol open-webui_data):/v/webui:ro")
    vol_exists mem0_data       && mounts+=(-v "$(vol mem0_data):/v/mem0:ro")
    vol_exists n8n_data        && mounts+=(-v "$(vol n8n_data):/v/n8n:ro")
    for i in 1 2 3; do      # a copy taken while a service writes can be torn: retry before failing
        docker run --rm -i --network none --user 0 --entrypoint python3 "${mounts[@]}" -v "$bk:/bk:ro" \
            -v "$AET_ROOT/lib/dbfp.py:/lib/dbfp.py:ro" -e PYTHONPATH=/lib "$helper" - <<'PY'
import json
import dbfp
man = json.load(open("/bk/manifest.json"))
live = {"webui": "/v/webui/webui.db", "mem0": "/v/mem0/openmemory.db", "n8n": "/v/n8n/database.sqlite"}
rc = 0
for name, v in man.items():
    if name not in live: continue
    problems, changed, fp = dbfp.check_after_healthy(live[name], v)
    rc |= bool(problems)
    print(f"    {name}.db: integrity {fp['integrity']}, schema {fp['version']} (backup {v['version']}), "
          f"{'FAIL: ' + '; '.join(problems) if problems else 'no table lost rows'}; changed since restore: {'yes' if changed else 'no'}")
raise SystemExit(rc)
PY
        rc=$?; [[ $rc -eq 0 ]] && break; sleep 2
    done
    return $rc
}

restore_qdrant() { # restore_qdrant BK  — only needed when the Qdrant image changed
    local bk=$1 mode helper coll
    mode=$(cat "$bk/qdrant.mode" 2>/dev/null) || return 0
    helper=$(helper_image)
    if [[ "$mode" == tar ]]; then
        docker run --rm --network none --user 0 --entrypoint sh -v "$(vol qdrant_data):/v" -v "$bk:/bk:ro" "$helper" \
            -c 'find /v -mindepth 1 -delete && tar xzf /bk/qdrant_data.tgz -C /v'
    elif [[ -d "$bk/qdrant" ]]; then          # one snapshot per collection
        local f
        for f in "$bk"/qdrant/*.snapshot; do
            [[ -e "$f" ]] || continue
            curl -fsS -m 600 -X POST -F "snapshot=@$f" \
                "http://127.0.0.1:$(env_get "$AET_ROOT/.env" QDRANT_HTTP_PORT 6333)/collections/$(basename "$f" .snapshot)/snapshots/upload?priority=snapshot" >/dev/null || return 1
        done
    else                                      # older backups: the single QDRANT_COLLECTION snapshot
        coll=$(env_get "$bk/meta.env" QDRANT_COLLECTION)
        curl -fsS -m 300 -X POST -F "snapshot=@$bk/qdrant.snapshot" \
            "http://127.0.0.1:$(env_get "$AET_ROOT/.env" QDRANT_HTTP_PORT 6333)/collections/$coll/snapshots/upload?priority=snapshot" >/dev/null
    fi
}

# --- health checks (READ-ONLY) -------------------------------------------
FAILED=()
forced() { [[ ",${HEALTH_FORCE_FAIL:-}," == *",$1,"* ]]; }

wait_for() { # wait_for NAME TIMEOUT_S CMD...   -> prints one result line, records failures
    local name=$1 t=$2 start=$SECONDS out; shift 2
    if forced "$name"; then bad "$name: forced failure (HEALTH_FORCE_FAIL)"; FAILED+=("$name"); return 1; fi
    # keep the check's own output: when it fails, WHY it failed is the only useful evidence
    # (checks print counts/names/verdicts only, never row data or secrets)
    until out=$("$@" 2>&1); do
        if (( SECONDS - start >= t )); then
            bad "$name: not healthy after ${t}s"
            if [[ -n "$out" ]]; then
                info "last output of the check: $(printf '%s' "$out" | tail -n 4 | cut -c1-220 | tr '\n' '|')"
                printf '%s: last output of the check:\n%s\n' "$name" "$out" >> "${AET_LOG:-/dev/null}"
            fi
            FAILED+=("$name"); return 1
        fi
        sleep 3
    done
    ok "$name healthy ($((SECONDS - start))s)"
}
http200() { curl -fsS -m 5 -o /dev/null "$1"; }
hc_openwebui() { curl -fsS -m 5 "http://127.0.0.1:$(env_get "$AET_ROOT/.env" OPEN_WEBUI_PORT 3000)/health" | grep -q '"status":true'; }
hc_extractor() { docker exec web-extractor python3 -c 'import json,urllib.request,sys;sys.exit(0 if json.load(urllib.request.urlopen("http://localhost:8000/health",timeout=3)).get("browser_connected") else 1)'; }
hc_playwright() { # server version == client version AND a real browser connect from web-extractor
    local client server
    client=$(docker exec web-extractor python3 -c 'import importlib.metadata as m;print(m.version("playwright"))' 2>/dev/null)
    server=$(docker exec playwright playwright --version 2>&1 | sed -n 's/^Version \([0-9][0-9.]*\)$/\1/p')   # `Version 1.60.0`; error text must not match
    # Legacy image (pre local build) has no global CLI: its version is in the `npx playwright@X` process.
    [[ -n "$server" ]] || server=$(docker exec playwright sh -c 'cat /proc/[0-9]*/cmdline 2>/dev/null | tr "\0" " "' 2>/dev/null \
        | grep -o 'playwright@[0-9][0-9.]*' | head -1 | cut -d@ -f2)
    [[ -n "$client" && "$client" == "$server" ]] || return 1
    docker exec web-extractor python3 -c '
import asyncio
from playwright.async_api import async_playwright
async def main():
    async with async_playwright() as p:
        b = await p.chromium.connect("ws://playwright:3000/", timeout=10000)
        await b.close()
asyncio.run(main())'
}
hc_filter() { # Mem0 Filter row still active in webui.db (read-only open)
    docker exec open-webui python3 -c 'import sqlite3,sys;r=sqlite3.connect("file:/app/backend/data/webui.db?mode=ro",uri=True).execute("select is_active from function where id=?",("mem0_memory",)).fetchone();sys.exit(0 if r and r[0]==1 else 1)'
}
hc_recall() { # embed fixed string -> Qdrant points/search -> HTTP 200 and 768-dim vector
    local o coll q
    o=$(ollama_url); coll=$(env_get "$AET_ROOT/.env" QDRANT_COLLECTION openmemory_default)
    q="http://127.0.0.1:$(env_get "$AET_ROOT/.env" QDRANT_HTTP_PORT 6333)"
    O="$o" C="$coll" Q="$q" M="$(env_get "$AET_ROOT/.env" EMBED_MODEL nomic-embed-text)" D="$(env_get "$AET_ROOT/.env" EMBED_DIMS 768)" python3 -I - <<'PY'
import json, os, urllib.request
def post(url, body):
    r = urllib.request.urlopen(urllib.request.Request(url, json.dumps(body).encode(), {"Content-Type": "application/json"}), timeout=60)
    return r.status, json.load(r)
_, e = post(os.environ["O"] + "/api/embed", {"model": os.environ["M"], "input": "aetulla health check"})
vec = e["embeddings"][0]
assert len(vec) == int(os.environ["D"]), f"embedding dim {len(vec)}"
st, _ = post(f'{os.environ["Q"]}/collections/{os.environ["C"]}/points/search', {"vector": vec, "limit": 1})
assert st == 200, st
PY
}

health_all() { # sets FAILED
    FAILED=()
    wait_for mem0_store       60  http200 "http://127.0.0.1:$(env_get "$AET_ROOT/.env" QDRANT_HTTP_PORT 6333)/readyz"
    wait_for mem0             90  http200 "http://127.0.0.1:$(env_get "$AET_ROOT/.env" MEM0_PORT 8765)/docs"
    wait_for playwright       60  hc_playwright
    wait_for web-extractor    60  hc_extractor
    wait_for ollama-keepalive 20  is_running ollama-keepalive
    wait_for open-webui      240  hc_openwebui
    wait_for n8n             120  http200 "http://127.0.0.1:$(env_get "$AET_ROOT/.env" N8N_PORT 5678)/healthz"
    wait_for mem0-filter      30  hc_filter
    wait_for memory-recall    90  hc_recall
    [[ ${#FAILED[@]} -eq 0 ]]
}

# n8n: a failed migration is not worth a full rollback if a fresh volume works.
n8n_recover() {
    local old ts helper; ts=$(date +%Y%m%d-%H%M%S); old="$(vol n8n_data)_old_$ts"; helper=$(helper_image)
    warn "n8n unhealthy after upgrade — trying a fresh n8n_data (old data kept in volume $old)"
    docker stop n8n >/dev/null 2>&1
    docker volume create "$old" >/dev/null &&
    docker run --rm --network none --user 0 --entrypoint sh -v "$(vol n8n_data):/from:ro" -v "$old:/to" "$helper" -c 'cp -a /from/. /to/' &&
    docker run --rm --network none --user 0 --entrypoint sh -v "$(vol n8n_data):/v" "$helper" -c 'find /v -mindepth 1 -delete' || return 1
    dc up -d n8n >/dev/null 2>&1
    FAILED=()
    if wait_for n8n 120 http200 "http://127.0.0.1:$(env_get "$AET_ROOT/.env" N8N_PORT 5678)/healthz"; then
        N8N_RESET="old data kept in docker volume $old"; return 0
    fi
    return 1
}

# --- rollback ---------------------------------------------------------------
do_rollback() { # do_rollback BK [full]
    local bk=$1 full=${2:-} pw legacy
    local HEALTH_FORCE_FAIL=          # a forced failure must not poison the rollback's own checks
    echo; warn "ROLLBACK from $bk"
    docker stop "${CORE_SERVICES[@]}" >/dev/null 2>&1
    restore_data "$bk" || { bad "data restore FAILED — stack left stopped. Backup: $bk"; return 1; }
    if [[ -n "$full" || "$(env_get "$bk/meta.env" PREV_QDRANT_IMAGE)" != "$(compose_image mem0_store)" ]]; then
        restore_qdrant "$bk" && info "qdrant restored"
    fi
    restore_local_images "$bk"
    if [[ "$(env_get "$bk/meta.env" GIT_MODE)" == release ]]; then
        git -C "$AET_ROOT" checkout --quiet "$(env_get "$bk/meta.env" PREV_GIT_REF)" && info "git: back to previous release"
    fi
    AET_OVERRIDES=("$bk/images.prev.yml")      # pins the exact images that were running before
    # Backups of a legacy install carry the registry Playwright image, whose version lived in an
    # `npx -y playwright@X` run command: restore that command too (one-time migration shim).
    pw=$(sed -n 's|^    image: mcr.microsoft.com/playwright:v\([0-9.]*\)-noble$|\1|p' "$bk/images.prev.yml")
    if [[ -n "$pw" ]]; then
        legacy=$(mktemp)
        printf 'services:\n  playwright:\n    command: ["/bin/sh","-c","npx -y playwright@%s run-server --port 3000 --host 0.0.0.0"]\n' "$pw" > "$legacy"
        AET_OVERRIDES+=("$legacy")
    fi
    dc up -d --no-build "${CORE_SERVICES[@]}" >/dev/null 2>&1 || { bad "could not start previous versions"; AET_OVERRIDES=(); return 1; }
    health_all
    local rc=$?
    echo "  data check after healthy (integrity, schema version, no lost rows):"
    verify_after_health "$bk" || { bad "data check after healthy FAILED"; rc=1; }
    AET_OVERRIDES=()
    [[ -n "${legacy:-}" ]] && rm -f "$legacy"
    return $rc
}

# --- Ollama advisory: report only, never upgrade ---------------------------
ollama_advice() {
    local cur latest
    cur=$(curl -fsS -m 5 "$(ollama_url)/api/version" 2>/dev/null | python3 -I -c 'import sys,json;print(json.load(sys.stdin)["version"])' 2>/dev/null)
    [[ -n "$cur" ]] || { info "Ollama: version unknown"; return; }
    latest=$(curl -fsS -m 5 https://api.github.com/repos/ollama/ollama/releases/latest 2>/dev/null | python3 -I -c 'import sys,json;print(json.load(sys.stdin)["tag_name"].lstrip("v"))' 2>/dev/null)
    if [[ -z "$latest" ]]; then info "Ollama $cur (latest unknown)"
    elif [[ "$cur" != "$latest" && "$(printf '%s\n%s\n' "$cur" "$latest" | sort -V | head -1)" == "$cur" ]]; then
        warn "Ollama $cur is older than $latest — upgrade yourself: curl -fsSL https://ollama.com/install.sh | sh"
    else ok "Ollama $cur is current"; fi
}

# version resolution + the --dry-run report (read-only)
# shellcheck disable=SC1091  # path is computed from AET_ROOT
source "$AET_ROOT/lib/resolve.sh"
# shellcheck disable=SC1091
source "$AET_ROOT/lib/apply.sh"

# --- commands -----------------------------------------------------------
# --- effective lock: every start path must resolve what is INSTALLED, not the compose defaults --------
# dc() only passes a lock when AET_LOCKFILE is set. Commands that do not go through apply_init (up, status,
# rollback, --dry-run) used to leave it empty, so compose fell back to its ${VAR:-default}s (older than the
# migrated DBs after an update). They all call this first. resolved.lock if present, else versions.lock.
use_effective_lock() { AET_LOCKFILE="$(eff_lock)"; }

# High-water mark of versions whose DB migrations/storage format have run (open-webui, n8n, qdrant can not
# be downgraded in place). Written whenever a lock is established; cmd_up refuses to start anything older.
# Lives next to resolved.lock (never in the repo). A deliberate rollback restores the DBs too and resets it.
HW_KEYS=(OPENWEBUI_VERSION N8N_VERSION QDRANT_VERSION)
hw_file() { echo "$AET_STATE/highwater.lock"; }
ver_lt() { [[ "$1" != "$2" && "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$1" ]]; }   # 1 < 2 ?
hw_bump() { # hw_bump LOCKFILE [reset]  raise (or, with reset, set) the marks to the versions in LOCKFILE
    local hw k v old; hw=$(hw_file); mkdir -p "$AET_STATE"; touch "$hw"; chmod 600 "$hw"
    for k in "${HW_KEYS[@]}"; do
        v=$(env_get "$1" "$k"); [[ -n "$v" ]] || continue
        old=$(env_get "$hw" "$k")
        if [[ "${2:-}" == reset || -z "$old" ]] || ver_lt "$old" "$v"; then
            { grep -v "^$k=" "$hw"; echo "$k=$v"; } > "$hw.tmp" && chmod 600 "$hw.tmp" && mv "$hw.tmp" "$hw"
        fi
    done
}
hw_check() { # die if the effective lock is older than a version that already migrated the data
    local hw k eff old; hw=$(hw_file)
    [[ -f "$hw" ]] || { [[ -f "$AET_LOCK_RESOLVED" ]] && hw_bump "$AET_LOCK_RESOLVED"; return 0; }   # first run: trust resolved.lock
    for k in "${HW_KEYS[@]}"; do
        eff=$(lock_val_eff "$k"); old=$(env_get "$hw" "$k")
        if [[ -n "$eff" && -n "$old" ]] && ver_lt "$eff" "$old"; then
            die "refusing to start: $k would be $eff but the data was already migrated by $old (lock: $(eff_lock)). Fix the lock, or 'aetulla rollback' to restore the DBs."
        fi
    done
}

# Start the core services with the effective lock (named services only, never a bare `compose up`).
cmd_up() {
    preflight_light
    use_effective_lock
    hw_check
    dc up -d "${CORE_SERVICES[@]}" && dc ps
}

# update on a stopped stack (reboot, `docker system prune`): bring it up on the locked versions first and require it
# healthy, instead of failing later with "pre-state unreadable". No-op when everything already runs.
ensure_stack_up() {
    local c down=()
    for c in "${CORE_SERVICES[@]}"; do is_running "$c" || down+=("$c"); done
    (( ${#down[@]} )) || return 0
    warn "stack not fully running (${down[*]}) — starting it on the locked versions first"
    local keep=${AET_LOCKFILE:-}     # update's working lock must survive: cmd_up points AET_LOCKFILE at the effective lock
    cmd_up >/dev/null || die "could not start the stack with $(eff_lock)"
    AET_LOCKFILE=$keep
    health_all || die "stack started but is not healthy (${FAILED[*]}) — fix that before updating"
    ok "stack is up and healthy"
}

# aetulla lock --promote: after a fully healthy run, make the repo's pins equal what is installed
# (versions.lock + the compose ${VAR:-default}s), so a bare `docker compose up` can never start older versions.
lock_promote() {
    preflight_light
    [[ -f "$AET_LOCK_RESOLVED" ]] || die "no $AET_LOCK_RESOLVED — nothing to promote"
    use_effective_lock
    local c k key tag
    for c in "${CORE_SERVICES[@]}"; do is_running "$c" || die "$c is not running — promote only after a healthy run"; done
    health_all || die "health check failed (${FAILED[*]}) — not promoting"
    hc_filter_recall >/dev/null 2>&1; k=$?; [[ $k == 0 || $k == 3 ]] || die "filter-recall failed — not promoting"
    # what runs must be what the lock says (else we would pin a version nobody tested)
    for c in "open-webui:OPENWEBUI_VERSION" "n8n:N8N_VERSION" "mem0_store:QDRANT_VERSION" "ollama-keepalive:CURL_VERSION"; do
        key=${c#*:}; tag=$(tag_of "$(ctr_image "${c%%:*}")")
        [[ "$tag" == "$(lock_val "$AET_LOCK_RESOLVED" "$key")" ]] || die "${c%%:*} runs $tag but resolved.lock has $key=$(lock_val "$AET_LOCK_RESOLVED" "$key")"
    done
    python3 -I "$AET_ROOT/lib/promote.py" "$AET_LOCK_RESOLVED" "$AET_LOCK_COMMITTED" "$AET_COMPOSE" || die "promote failed"
    hw_bump "$AET_LOCK_RESOLVED"
    # proof: plain compose (no lock, no env file magic) now resolves the installed images
    bash "$AET_ROOT/tests/lock_defaults_test.sh" >/dev/null 2>&1 && ok "compose defaults == versions.lock" || warn "tests/lock_defaults_test.sh reports drift"
    info "review with: git diff versions.lock docker-compose.yml   (commit by name, never git add -A)"
}

cmd_lock() {
    case "${1:-}" in
        --promote) lock_promote ;;
        *) die "usage: aetulla lock --promote" ;;
    esac
}

cmd_status() {
    preflight_light
    use_effective_lock
    local c want have shown
    echo "Aetulla status  (pins from $(eff_lock | sed "s|^$HOME|~|"))"
    for c in "${CORE_SERVICES[@]}"; do
        local run="stopped"; is_running "$c" && run="running"
        have=$(ctr_image "$c"); want=$(compose_image "$c")
        shown=$(tag_of "${have:-none}")
        case "$c" in playwright|web-extractor) shown="playwright $(ctr_pw_version "$c")"; [[ "$shown" != "playwright " ]] || shown="$(tag_of "${have:-none}") (legacy image)";; esac   # local builds: baked version
        printf '  %-18s %-8s %s\n' "$c" "$run" "$shown$([[ -n "$want" && "$have" != "$want" && "$c" != playwright ]] && echo "  (pinned $(tag_of "$want"))")"
    done
    for c in "${CORE_SERVICES[@]}"; do
        is_running "$c" || { warn "stack is not fully running — health checks skipped"; ollama_advice; echo "  last backup: $(latest_backup)"; return 0; }
    done
    health_all
    local rc=$?
    ollama_advice
    echo "  last backup: $(latest_backup)"
    return $rc
}

cmd_rollback() {
    preflight_light
    use_effective_lock
    local bk=${1:-$(latest_backup)}
    [[ -d "$bk" ]] || die "no backup found (looked in $AET_BACKUP_ROOT)"
    # the lockfile that matches those images: compose must resolve the SAME versions as the pinned images
    if [[ -f "$bk/versions.prev.lock" ]]; then AET_LOCKFILE="$bk/versions.prev.lock"; fi
    if do_rollback "$bk" full; then
        if [[ -f "$bk/versions.prev.lock" ]]; then
            if [[ "$(basename "$(cat "$bk/versions.prev.lock.src" 2>/dev/null)")" == resolved.lock ]]; then cp "$bk/versions.prev.lock" "$AET_LOCK_RESOLVED"; else rm -f "$AET_LOCK_RESOLVED"; fi
        fi
        hw_bump "$(eff_lock)" reset      # the DBs were restored too: the high-water mark follows the restored lock
        ok "rolled back to $(basename "$bk")"
    else die "rollback did not finish cleanly"; fi
}

cmd_update() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --channel)      AET_CHANNEL=${2:-}; shift 2 ;;
            --channel=*)    AET_CHANNEL=${1#*=}; shift ;;
            --dry-run)      AET_DRYRUN=1; shift ;;
            --with-ollama)  AET_WITH_OLLAMA=1; shift ;;
            --no-models)    AET_MODELS=0; shift ;;
            --yes)          AET_YES=1; shift ;;
            --yes-big)      AET_YES_BIG=1; shift ;;
            --qdrant-to)    AET_QDRANT_TO=${2:-}; shift 2 ;;
            --qdrant-to=*)  AET_QDRANT_TO=${1#*=}; shift ;;
            --only)         AET_ONLY=${2:-}; shift 2 ;;
            --only=*)       AET_ONLY=${1#*=}; shift ;;
            *) die "unknown option for update: $1" ;;
        esac
    done
    [[ $AET_CHANNEL == latest || $AET_CHANNEL == locked ]] || die "--channel must be 'latest' or 'locked'"
    use_effective_lock     # --dry-run and the pins path must compare against what is installed, not compose defaults
    if (( AET_DRYRUN )); then update_dry_run; return; fi
    if [[ $AET_CHANNEL == latest ]]; then update_apply_latest; else update_apply_pins; fi
}

# Legacy apply path = channel locked: install exactly what docker-compose.yml / versions.lock pin.
update_apply_pins() {
    echo "Aetulla update (channel: locked)"
    preflight_light
    if ! net_ok; then ok "offline — update check skipped. Nothing was changed."; return 0; fi
    preflight
    git_mode
    local target_ref="" cur_tag="" latest
    if [[ "$GIT_MODE" == release ]]; then
        git -C "$AET_ROOT" fetch --tags -q 2>/dev/null
        cur_tag=$(git -C "$AET_ROOT" describe --exact-match --tags HEAD)
        latest=$(git -C "$AET_ROOT" tag -l 'v[0-9]*' --sort=-v:refname | head -1)
        [[ -n "$latest" && "$latest" != "$cur_tag" ]] && target_ref=$latest
    else
        info "dev checkout ($GIT_REASON): git step skipped, applying docker-compose.yml pins only"
    fi
    if [[ -z "$target_ref" ]] && versions_match_running; then
        ok "up to date — all services run the pinned versions"
        ollama_advice
        return 0
    fi
    check_playwright_pin || return 1
    backup_create || die "backup failed — nothing was changed"
    local bk=$BK
    if [[ -n "$target_ref" ]]; then
        git -C "$AET_ROOT" checkout --quiet "$target_ref" || { bad "git checkout $target_ref failed"; return 1; }
        info "git: $cur_tag -> $target_ref"
        if ! check_playwright_pin; then git -C "$AET_ROOT" checkout --quiet "$(env_get "$bk/meta.env" PREV_GIT_REF)"; return 1; fi
    fi
    info ".env: $(env_merge)"
    if ! dc pull -q --ignore-buildable "${CORE_SERVICES[@]}" >/dev/null 2>&1; then
        bad "image pull failed — nothing was started"
        [[ -n "$target_ref" ]] && git -C "$AET_ROOT" checkout --quiet "$(env_get "$bk/meta.env" PREV_GIT_REF)"
        return 1
    fi
    dc build -q mem0 web-extractor playwright >/dev/null 2>&1 || { bad "image build failed"; do_rollback "$bk"; return 1; }
    dc up -d "${CORE_SERVICES[@]}" >/dev/null 2>&1 || { bad "compose up failed"; do_rollback "$bk"; return 1; }
    N8N_RESET=""
    health_all
    # n8n alone failing is recoverable (fresh volume); anything else means rollback
    if [[ ${#FAILED[@]} -eq 1 && "${FAILED[0]}" == n8n ]]; then n8n_recover && FAILED=(); fi
    if [[ ${#FAILED[@]} -gt 0 ]]; then
        bad "failed: ${FAILED[*]}"
        if do_rollback "$bk"; then
            echo; bad "UPDATE FAILED and was rolled back. Previous versions are running again."
        else
            echo; bad "UPDATE FAILED and rollback needs attention. Backup: $bk"
        fi
        return 1
    fi
    echo; echo "━━━ Aetulla update: OK ━━━"
    local name prev
    for name in "${VERSIONED_SERVICES[@]}"; do
        prev=$(grep -A1 "^  $name:" "$bk/images.prev.yml" | sed -n 's/^    image: //p')
        printf '  %-18s %s -> %s\n' "$name" "$(tag_of "${prev:-none}")" "$(tag_of "$(ctr_image "$name")")"
    done
    prev=$(sed -n 's|^    image: mcr.microsoft.com/playwright:v\([0-9.]*\)-noble$|\1|p' "$bk/images.prev.yml")
    printf '  %-18s %s -> %s\n' playwright "${prev:-$(env_get "$bk/meta.env" PREV_PLAYWRIGHT unknown)}" "$(ctr_pw_version playwright)"
    if [[ "$GIT_MODE" == dev ]]; then echo "  git: skipped ($GIT_REASON)"; fi
    if [[ -n "${N8N_RESET:-}" ]]; then warn "n8n was reset (migration failed): $N8N_RESET"; fi
    echo "  backup: $bk"
    ollama_advice
}
