#!/usr/bin/env bash
# The `aetulla update --channel latest` APPLY path. Sourced by lib/aetulla.sh, never run.
#
# Flow: resolve -> print plan -> confirm -> backup -> components lowest-risk first (each: pre-check,
# change, health check, automatic per-component rollback) -> Qdrant LAST, one minor at a time ->
# write ~/.aetulla/resolved.lock (what is ACTUALLY installed) -> summary table.
#
# Rules: never a bare `compose up` (always `--no-deps <svc>`); Ollama stays native; the data of a
# service is only restored for THAT service (RESTORE_ONLY); every prompt below defaults to "no";
# nothing here touches networking/DNS or prints .env values.
# bash 3.2 compatible.
# shellcheck disable=SC2034  # AET_LOCKFILE etc. are globals read by dc() in aetulla.sh

AET_YES=0          # --yes: skip the general confirmation (NOT the per-model >10 GB ones)
AET_YES_BIG=0      # --yes-big: also pre-approve >10 GB model pulls
AET_QDRANT_TO=""   # --qdrant-to X.Y.Z: stop the Qdrant chain at that published version (e.g. 1.12.6 = first step only)
AET_ONLY=""        # --only a,b : keepalive,build,playwright,n8n,open-webui,mem0,ollama,models,qdrant
AET_WORK_LOCK=""
AET_RESULTS=""
AET_APPLY_FAILED=0

want() { [[ -z "$AET_ONLY" || ",$AET_ONLY," == *",$1,"* ]]; }
confirm() { # confirm MSG [big]   default NO; needs a TTY unless pre-approved
    local msg=$1 kind=${2:-} a
    if [[ $kind == big ]]; then [[ $AET_YES_BIG == 1 ]] && return 0
    elif [[ $kind == always ]]; then :                       # never pre-approvable
    else [[ $AET_YES == 1 ]] && return 0; fi
    # always the terminal, never stdin: callers run inside `while read` loops
    # prompt and answer both go through the terminal itself (never stdout/stdin: those are piped/tee'd)
    if ! { printf '\n  ? %s [y/N] ' "$msg" >/dev/tty && read -r a </dev/tty; } 2>/dev/null; then
        bad "confirmation needed but no terminal: $msg"; return 1
    fi
    [[ $a == y || $a == Y ]]
}
res_add() { printf '%s|%s|%s|%s|%s\n' "$1" "${2:-?}" "${3:-?}" "$4" "${5:-}" >> "$AET_RESULTS"; }
lock_get() { env_get "$AET_WORK_LOCK" "$1"; }
lock_set() { # lock_set KEY VALUE  (in the working lock, atomically)
    local t="$AET_WORK_LOCK.tmp"
    { grep -v "^$1=" "$AET_WORK_LOCK"; echo "$1=$2"; } > "$t" && mv "$t" "$AET_WORK_LOCK"
}
revert_lock() { local p; for p in $1; do lock_set "${p%%=*}" "${p#*=}"; done; }   # "K=old K2=old2"

# `docker pull` IS the existence check. One retry on transient errors; LAST_ERR = last line docker printed.
LAST_ERR=
is_transient() { # 429 / 5xx / timeouts / resets
    case $1 in
        *429*|*toomanyrequests*|*"rate limit"*|*" 500"*|*" 502"*|*" 503"*|*" 504"*|*imeout*|*"deadline exceeded"*|*EOF*|*"connection reset"*|*emporar*|*"TLS handshake"*) return 0 ;;
    esac
    return 1
}
run_retry() { # run_retry CMD... : output goes to the run log, never to the terminal
    local out rc
    out=$("$@" 2>&1); rc=$?
    if [[ $rc -ne 0 ]] && is_transient "$out"; then
        warn "transient registry/network error, retrying once"; sleep "${AET_RETRY_SLEEP:-3}"
        out=$("$@" 2>&1); rc=$?
    fi
    printf '%s\n' "$out" >> "${AET_LOG:-/dev/null}"
    LAST_ERR=$(printf '%s' "$out" | grep -v '^[[:space:]]*$' | tail -n 1 | cut -c1-140)
    return $rc
}

apply_init() {
    mkdir -p "$AET_STATE/logs" && chmod 700 "$AET_STATE" 2>/dev/null
    AET_LOG="$AET_STATE/logs/update-$(date +%Y%m%d-%H%M%S).log"; : > "$AET_LOG"
    AET_WORK_LOCK="$AET_STATE/resolved.lock.work"
    cp "$(eff_lock)" "$AET_WORK_LOCK"
    # keys the committed set knows but an older resolved.lock may lack
    local k v; for k in OPENWEBUI_VERSION N8N_VERSION QDRANT_VERSION CURL_VERSION PLAYWRIGHT_VERSION PY_BASE_DIGEST MEM0_BASE_DIGEST STT_BASE_DIGEST; do
        [[ -n "$(lock_get $k)" ]] || lock_set "$k" "$(lock_val "$AET_LOCK_COMMITTED" "$k")"
    done
    AET_LOCKFILE="$AET_WORK_LOCK"            # dc() now passes it to compose as an extra --env-file
    AET_RESULTS=$(mktemp)
}

# --- health checks specific to the apply path --------------------------------
# REQUIRED after an Open WebUI upgrade (0.13.1 changed how context reaches the model): run the REAL
# Mem0 Filter inside the (new) open-webui container, with its saved valves, on a stored memory used as
# the query, and require that inlet() actually injected that memory. Read-only: one embed + one Qdrant
# search; outlet() (the write path) is never called. rc 3 = nothing stored yet (cannot verify) = pass.
hc_filter_recall() {
    docker exec -i open-webui python3 - <<'PY'
import json, sqlite3, requests
db = sqlite3.connect("file:/app/backend/data/webui.db?mode=ro", uri=True)
content, valves = db.execute("select content, valves from function where id='mem0_memory'").fetchone()
ns = {}
exec(compile(content, "mem0_memory", "exec"), ns)          # the function exactly as Open WebUI loads it
f = ns["Filter"]()
if valves:
    f.valves = f.Valves(**json.loads(valves))
v = f.valves
r = requests.post(f"{v.qdrant_url}/collections/{v.collection}/points/scroll", timeout=30,
                  json={"limit": 1, "with_payload": True,
                        "filter": {"must": [{"key": "user_id", "match": {"value": v.user_id}}]}})
r.raise_for_status()
pts = r.json()["result"]["points"]
if not pts:
    print("no memories stored: recall cannot be verified")
    raise SystemExit(3)
probe = pts[0]["payload"]["data"]
body = {"messages": [{"role": "user", "content": probe}]}
out = f.inlet(body, {"id": "aetulla-healthcheck"})
# Version-agnostic (v1.0 injects a system message, v1.1 prefixes the last user message): the query IS a
# stored memory, so a working recall puts its text into the prompt a SECOND time, wherever it goes.
def text(m):
    c = m.get("content", "")
    return c if isinstance(c, str) else json.dumps(c)
seen = sum(text(m).count(probe[:40]) for m in out["messages"])
ok = seen >= 2
print(f"filter inlet injected the recalled memory ({seen} occurrences in the prompt)" if ok
      else "filter inlet did NOT inject the memory")
raise SystemExit(0 if ok else 1)
PY
    local rc=$?; [[ $rc -eq 0 || $rc -eq 3 ]]
}

# n8n only has /healthz, which answers as soon as the server listens. This second, read-only check proves the
# migrated DB is sound: integrity ok and no USER-DATA table (dbfp.N8N_USER_TABLES: workflows, credentials,
# users, projects, ...) lost rows compared with the pre-run backup. Other tables are only reported: n8n
# migrations drop/rename/add internal tables (an earlier version of this check failed an upgrade because 4
# EMPTY tables disappeared), and execution history is pruned on purpose. The migration NAME is not compared.
# AET_N8N_VOLUME overrides the volume (used to prove the check against a scratch copy).
hc_n8n_data() {
    local out rc
    out=$(docker run --rm -i --network none --user 0 --entrypoint python3 -v "${AET_N8N_VOLUME:-$(vol n8n_data)}:/v:ro" -v "$BK:/bk:ro" \
        -v "$AET_ROOT/lib/dbfp.py:/lib/dbfp.py:ro" -e PYTHONPATH=/lib "$(helper_image)" - <<'PY'
import json, dbfp
before = (json.load(open("/bk/manifest.json")).get("n8n") or {}).get("tables", {})
fp = dbfp.fingerprint("/v/database.sqlite")
bad, notes = dbfp.check_user_tables(before, fp["tables"])
if fp["integrity"] != "ok":
    bad.insert(0, "integrity " + fp["integrity"])
user = ", ".join(f"{t} {before[t]}->{fp['tables'].get(t)}" for t in dbfp.N8N_USER_TABLES if t in before and before[t])
print("n8n data check: " + ("FAIL " + "; ".join(bad) if bad else "user-data tables intact (" + user + ")"))
if notes:
    print("  informational (not failures): " + "; ".join(notes))
raise SystemExit(1 if bad else 0)
PY
    ); rc=$?
    printf '%s\n' "$out"; printf '%s\n' "$out" >> "${AET_LOG:-/dev/null}"; return $rc
}

apply_health() { # apply_health COMPONENT -> 0 healthy; failures are listed in FAILED
    FAILED=()
    local env="$AET_ROOT/.env"
    case $1 in
        keepalive)   wait_for ollama-keepalive 20 is_running ollama-keepalive ;;
        playwright)  wait_for playwright 60 hc_playwright; wait_for web-extractor 60 hc_extractor ;;
        n8n)         wait_for n8n 180 http200 "http://127.0.0.1:$(env_get "$env" N8N_PORT 5678)/healthz"
                     wait_for n8n-data 60 hc_n8n_data ;;
        open-webui)  wait_for open-webui 300 hc_openwebui; wait_for mem0-filter 30 hc_filter
                     wait_for filter-recall 120 hc_filter_recall ;;
        mem0)        wait_for mem0 120 http200 "http://127.0.0.1:$(env_get "$env" MEM0_PORT 8765)/docs"
                     wait_for memory-recall 90 hc_recall ;;
    esac
    [[ ${#FAILED[@]} -eq 0 ]]
}

# --- pre-checks (run after the new image is available, BEFORE anything is restarted) ----------
# Open WebUI: Playwright pin must match, and the RAG embedding model must already be in the cache
# (the container runs with HF_HUB_OFFLINE=1 once cached). If it is not, download it in a one-off
# container with the network allowed — the real container's environment is never changed.
pre_open_webui() {
    check_playwright_pin >>"$AET_LOG" 2>&1 || { bad "open-webui: Playwright pin mismatch (see log)"; return 1; }
    ok "open-webui: Playwright pin agrees"
    local img model
    img=$(compose_image open-webui)
    model=$(docker exec open-webui python3 -c 'import sqlite3,json;c=sqlite3.connect("file:/app/backend/data/webui.db?mode=ro",uri=True);r=c.execute("select value from config where key=?",("rag.embedding_model",)).fetchone();print(json.loads(r[0]) if r else "")' 2>/dev/null)
    [[ -n "$model" ]] || model=sentence-transformers/all-MiniLM-L6-v2     # Open WebUI's built-in default
    local probe='import sys;from sentence_transformers import SentenceTransformer as S;S(sys.argv[1],device="cpu")'
    if docker run --rm --user 0 -e HF_HUB_OFFLINE=1 -v "$(vol open-webui_data):/app/backend/data" "$img" python3 -c "$probe" "$model" >>"$AET_LOG" 2>&1; then
        ok "open-webui: embedding model '$model' loads offline with the new image"
    else
        warn "open-webui: '$model' is not loadable offline — downloading it ONCE with the network allowed (one-off container; the service keeps HF_HUB_OFFLINE as configured)"
        if docker run --rm --user 0 -e HF_HUB_OFFLINE=0 -v "$(vol open-webui_data):/app/backend/data" "$img" python3 -c "$probe" "$model" >>"$AET_LOG" 2>&1; then
            ok "open-webui: embedding model downloaded into the data volume cache"
        else
            bad "open-webui: could not fetch embedding model '$model' — not upgrading"; return 1
        fi
    fi
}
# mem0: our 3 files REPLACE upstream files wholesale. If upstream changed any of them, our copy would
# silently drop their change -> stop for this component and keep the current image.
pre_mem0() {
    local new old f a b diffs=0 paths="/usr/src/openmemory/app/utils/memory.py /usr/src/openmemory/app/routers/config.py /usr/src/openmemory/app/utils/categorization.py"
    new="mem0/openmemory-mcp@$(lock_get MEM0_BASE_DIGEST)"; old="mem0/openmemory-mcp@$(lock_val "$(eff_lock)" MEM0_BASE_DIGEST)"
    docker pull -q "$new" >>"$AET_LOG" 2>&1 || { bad "mem0: cannot pull new base"; return 1; }
    docker image inspect "$old" >/dev/null 2>&1 || docker pull -q "$old" >>"$AET_LOG" 2>&1 || { bad "mem0: old base not available to compare"; return 1; }
    for f in $paths; do
        a=$(docker run --rm --entrypoint sha256sum "$old" "$f" 2>/dev/null | cut -d' ' -f1)
        b=$(docker run --rm --entrypoint sha256sum "$new" "$f" 2>/dev/null | cut -d' ' -f1)
        if [[ -z "$a" || "$a" != "$b" ]]; then bad "mem0: upstream changed ${f##*/} (or unreadable) — our patched copy would no longer apply"; diffs=1; fi
    done
    [[ $diffs -eq 0 ]] && ok "mem0: all 3 patched files are identical upstream (patches still apply)"
    return $diffs
}

# --- one component: pre-check -> change -> health -> (automatic rollback) ----------------------
# Keep a container's own log BEFORE it is stopped/replaced: after a rollback the failed container is gone,
# and with it the only proof of what it did (e.g. Alembic "Running upgrade" lines). Stored next to the run log.
save_ctr_logs() { # save_ctr_logs SVC...
    local s f
    for s in "$@"; do
        f="${AET_LOG%.log}.$s.container.log"
        if docker logs "$s" > "$f" 2>&1; then
            chmod 600 "$f"; echo "saved container log of $s: $f" >> "$AET_LOG"
            info "$s: container log saved ($(wc -l < "$f" | tr -d ' ') lines): $f"
        fi
    done
}
rollback_component() { # rollback_component NAME "svc ..." "K=old ..."
    local name=$1 svcs=$2 oldkv=$3 s id only=""
    warn "$name: health failed (${FAILED[*]}) — rolling this component back"
    revert_lock "$oldkv"
    # shellcheck disable=SC2086  # $svcs is a deliberate space-separated list of service names
    save_ctr_logs $svcs
    # shellcheck disable=SC2086
    docker stop $svcs >/dev/null 2>&1
    case $name in open-webui) only=webui;; n8n) only=n8n;; mem0) only=mem0;; esac
    if [[ -n "$only" ]]; then
        RESTORE_ONLY=$only restore_data "$BK" >>"$AET_LOG" 2>&1 || { bad "$name: data restore FAILED — left stopped, backup $BK"; return 1; }
    fi
    for s in $svcs; do   # locally built images come back from the tag backup_create made
        [[ -f "$BK/local-images.env" ]] && { id=$(sed -n "s/^$s=//p" "$BK/local-images.env"); [[ -n "$id" ]] && docker tag "$id" "$(local_image_name "$s")"; }
    done
    # shellcheck disable=SC2086
    for s in $AET_EXTRA_RESTORE; do docker tag "${s#*=}" "$(local_image_name "${s%%=*}")"; done   # e.g. the old tts image
    # shellcheck disable=SC2086
    dc up -d --no-deps --no-build $svcs >>"$AET_LOG" 2>&1 || { bad "$name: could not start previous version"; return 1; }
    local HEALTH_FORCE_FAIL=
    if apply_health "${AET_HK:-$name}"; then ok "$name: previous version healthy again"; else bad "$name: STILL unhealthy after rollback (${FAILED[*]}) — backup $BK"; return 1; fi
    [[ -z "$only" ]] || verify_after_health "$BK" >>"$AET_LOG" 2>&1 || { bad "$name: data check after rollback failed"; return 1; }
}
apply_component() { # apply_component NAME "svc ..." pull|build|build-only "K=new ..." OLD NEW [PRECHECK_FN] [EXTRA_BUILD_ONLY_SVCS] [HEALTH_KEY]
    local name=$1 svcs=$2 mode=$3 kv=$4 old=$5 new=$6 pre=${7:-} extra=${8:-} p k e id oldkv=""
    AET_HK=${9:-$1}; AET_EXTRA_RESTORE=""     # health-check key; images of build-only extras, to put back on rollback
    for e in $extra; do
        id=$(docker image inspect -f '{{.Id}}' "$(local_image_name "$e")" 2>/dev/null) && AET_EXTRA_RESTORE="$AET_EXTRA_RESTORE $e=$id"
    done
    for p in $kv; do k=${p%%=*}; oldkv="$oldkv $k=$(lock_get "$k")"; done
    for p in $kv; do lock_set "${p%%=*}" "${p#*=}"; done
    info "$name: $old -> $new"
    local rc
    # shellcheck disable=SC2086  # $svcs / $extra: space-separated service names, split on purpose
    case $mode in
        pull) run_retry dc pull -q $svcs ;;
        *)    run_retry dc --profile voice build -q $svcs $extra ;;
    esac; rc=$?
    if [[ $rc -ne 0 ]]; then
        revert_lock "$oldkv"
        if [[ $mode == pull ]]; then   # nothing was touched: skip this component, keep going
            bad "$name: skipped — pull failed ($LAST_ERR)"
            res_add "$name" "$old" "$new" skipped "pull failed ($LAST_ERR); nothing was changed"
        else
            bad "$name: build failed ($LAST_ERR) — unchanged"
            res_add "$name" "$old" "$new" failed "build failed ($LAST_ERR); nothing was restarted"; AET_APPLY_FAILED=1
        fi
        return 1
    fi
    if [[ -n "$pre" ]] && ! $pre; then
        revert_lock "$oldkv"; res_add "$name" "$old" "$new" skipped "pre-check failed; current version kept"; AET_APPLY_FAILED=1; return 1
    fi
    if [[ $mode == build-only ]]; then ok "$name: image built (not started: voice profile stays off)"; res_add "$name" "$old" "$new" updated "built only"; return 0; fi
    # shellcheck disable=SC2086
    dc up -d --no-deps $svcs >>"$AET_LOG" 2>&1 || { FAILED=(compose-up); rollback_component "$name" "$svcs" "$oldkv"; res_add "$name" "$old" "$new" "rolled back" "docker compose up failed (see log)"; AET_APPLY_FAILED=1; return 1; }
    if apply_health "$AET_HK"; then
        # stateful services: keep the log of a SUCCESSFUL start too (it shows the migrations that ran)
        # shellcheck disable=SC2086
        case $name in open-webui|n8n|mem0) save_ctr_logs $svcs ;; esac
        local s; for s in $svcs $extra; do lock_set "IMG_$(echo "$s" | tr 'a-z-' 'A-Z_')" "$(docker inspect -f '{{.Image}}' "$s" 2>/dev/null || docker image inspect -f '{{.Id}}' "$(local_image_name "$s")" 2>/dev/null)"; done
        res_add "$name" "$old" "$new" updated ""; return 0
    fi
    local why="health check failed: ${FAILED[*]}"        # captured BEFORE the rollback re-runs the checks
    if rollback_component "$name" "$svcs" "$oldkv"; then res_add "$name" "$old" "$new" "rolled back" "$why"
    else res_add "$name" "$old" "$new" "ROLLBACK FAILED" "$why; backup $BK"; fi
    AET_APPLY_FAILED=1; return 1
}

# --- Qdrant: one minor at a time, verify collections after each step --------------------------
qd_url() { echo "http://127.0.0.1:$(env_get "$AET_ROOT/.env" QDRANT_HTTP_PORT 6333)"; }
qd_state() { # one line per collection: name, exact point count, vector config. Read-only.
    python3 -I - "$(qd_url)" <<'PY'
import json, sys, urllib.request
base = sys.argv[1]
def call(path, body=None):
    req = urllib.request.Request(base + path, json.dumps(body).encode() if body is not None else None,
                                 {"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=30))["result"]
for c in sorted(x["name"] for x in call("/collections")["collections"]):
    n = call(f"/collections/{c}/points/count", {"exact": True})["count"]
    v = call(f"/collections/{c}")["config"]["params"]["vectors"]
    print(f"{c} points={n} vectors={json.dumps(v, sort_keys=True)}")
PY
}
qd_ready() { http200 "$(qd_url)/readyz"; }
qd_tar() { docker run --rm --network none --user 0 --entrypoint sh -v "$(vol qdrant_data):/v:ro" -v "$BK:/out" "$(helper_image)" \
    -c "tar czf /out/$1 -C /v . && chown $(id -u):$(id -g) /out/$1"; }
qd_untar() { docker run --rm --network none --user 0 --entrypoint sh -v "$(vol qdrant_data):/v" -v "$BK:/bk:ro" "$(helper_image)" \
    -c "find /v -mindepth 1 -delete && tar xzf /bk/$1 -C /v"; }

apply_qdrant() { # apply_qdrant "1.13.6 1.14.1 ..." OLD
    local steps=$1 prev=$2 step pre post tgz reason
    pre=$(qd_state) || { bad "qdrant: cannot read collections before upgrading — not touching it"; res_add qdrant "$prev" "?" failed "pre-state unreadable"; return 1; }
    info "qdrant pre-state: $(echo "$pre" | sed 's/ vectors=.*//' | tr '\n' ';')"
    docker stop mem0 >/dev/null 2>&1                      # no writes while the store is migrated
    for step in $steps; do
        pre=$(qd_state) || { bad "qdrant: state unreadable before step $step"; break; }
        tgz="qdrant_pre_${prev}.tgz"
        docker stop mem0_store >/dev/null 2>&1
        qd_tar "$tgz" || { bad "qdrant: volume backup failed — not upgrading"; dc up -d --no-deps --no-build mem0_store mem0 >>"$AET_LOG" 2>&1; res_add qdrant "$prev" "$step" failed "volume backup failed"; return 1; }
        lock_set QDRANT_VERSION "$step"
        info "qdrant: $prev -> $step"
        reason="step $step failed"
        if run_retry dc pull -q mem0_store && dc up -d --no-deps mem0_store >>"$AET_LOG" 2>&1; then
            local t=0; until qd_ready; do sleep 3; t=$((t+3)); [[ $t -ge 120 ]] && break; done
            post=$(qd_state 2>/dev/null)
            if qd_ready && [[ "$pre" == "$post" ]]; then
                if ! forced qdrant-step; then
                    ok "qdrant $step: ready, collections identical: $(echo "$post" | sed 's/ vectors=.*//' | tr '\n' ';')"; prev=$step; continue
                fi
                warn "qdrant $step: healthy and identical — FORCING a failure now (HEALTH_FORCE_FAIL=qdrant-step) to exercise the restore"
                reason="forced failure after a healthy step (HEALTH_FORCE_FAIL=qdrant-step)"
            else bad "qdrant $step: collections differ or not ready"; reason="step $step: collections differ or store not ready"; fi
        else bad "qdrant $step: pull/start failed (${LAST_ERR:-see log})"; reason="step $step: pull/start failed (${LAST_ERR:-see log})"; fi
        # failure: restore the pre-step volume + previous image, verify, stop the whole upgrade
        warn "qdrant: restoring pre-step volume and $prev"
        save_ctr_logs mem0_store
        docker stop mem0_store >/dev/null 2>&1; qd_untar "$tgz" >>"$AET_LOG" 2>&1
        lock_set QDRANT_VERSION "$prev"
        dc up -d --no-deps --no-build mem0_store >>"$AET_LOG" 2>&1
        local t=0; until qd_ready; do sleep 3; t=$((t+3)); [[ $t -ge 120 ]] && break; done
        post=$(qd_state 2>/dev/null)
        info "qdrant image now: $(ctr_image mem0_store)   counts: $(echo "$post" | sed 's/ vectors=.*//' | tr '\n' ';')"
        if [[ "$post" == "$pre" ]]; then ok "qdrant back on $prev (tar restored), collections identical to before"; res_add qdrant "$prev" "$step" "rolled back" "$reason"
        else bad "qdrant NOT verified after restore — backup $BK ($tgz)"; res_add qdrant "$prev" "$step" "ROLLBACK FAILED" "$reason; backup $BK/$tgz"; fi
        dc up -d --no-deps --no-build mem0 >>"$AET_LOG" 2>&1
        local HEALTH_FORCE_FAIL=
        if apply_health mem0; then ok "mem0 healthy again"; else bad "mem0 unhealthy after the qdrant restore (${FAILED[*]})"; fi
        AET_APPLY_FAILED=1; return 1
    done
    dc up -d --no-deps mem0 >>"$AET_LOG" 2>&1
    if apply_health mem0 && [[ "$prev" == "${steps##* }" ]]; then
        lock_set IMG_QDRANT "$(docker inspect -f '{{.Image}}' mem0_store 2>/dev/null)"
        res_add qdrant "$2" "$prev" updated "steps: ${steps// / → }"; return 0
    fi
    res_add qdrant "$2" "$prev" failed "mem0/recall unhealthy after qdrant steps (${FAILED[*]}); volume backups in $BK"; AET_APPLY_FAILED=1; return 1
}

# --- Ollama binary (opt-in, sudo) -------------------------------------------------------------
apply_ollama_binary() { # apply_ollama_binary OLD NEW
    confirm "Upgrade Ollama $1 -> $2 with the official installer (sudo). Restarting ollama unloads the resident model; ollama-keepalive reloads it within 20 min. Run the installer?" always || { res_add ollama-binary "$1" "$2" skipped "not confirmed"; return 1; }
    curl -fsSL https://ollama.com/install.sh | sh >>"$AET_LOG" 2>&1 || { bad "ollama installer failed (see log)"; res_add ollama-binary "$1" "$2" failed "installer"; return 1; }
    if ! { sudo systemctl daemon-reload && sudo systemctl restart ollama; }; then
        bad "could not restart ollama"; res_add ollama-binary "$1" "$2" failed "restart"; return 1
    fi
    local t=0; until check_ollama; do sleep 2; t=$((t+2)); [[ $t -ge 60 ]] && break; done
    local v; v=$(curl -fsS -m 5 "$(ollama_url)/api/version" | python3 -I -c 'import sys,json;print(json.load(sys.stdin)["version"])' 2>/dev/null)
    if systemctl cat ollama 2>/dev/null | grep -q 'override.conf' && [[ "$v" == "$2" ]]; then
        lock_set OLLAMA_VERSION "$v"; res_add ollama-binary "$1" "$v" updated "override.conf intact"; ok "ollama $v running, override.conf intact"
    else bad "ollama: version '$v' / override.conf check failed"; res_add ollama-binary "$1" "${v:-?}" failed "verify"; return 1; fi
}

# --- models -----------------------------------------------------------------------------------
# Tag refresh = blanket yes; > 10 GB asks per model; qwen3.5:35b-a3b goes last. Before pulling a model
# we `ollama cp` it to aetulla-prev/<name> (shares blobs, costs no disk until the new layers land) so a
# bad new tag can be undone by hand; those copies are pruned at the start of the NEXT run.
prev_name() { echo "aetulla-prev/$(echo "$1" | tr '/:' '__')"; }
apply_models() {
    local todo=$AET_MODELS_TODO name rsize st line last="qwen3.5:35b-a3b" old
    for old in $(ollama list | awk 'NR>1 && $1 ~ /^aetulla-prev\//{print $1}'); do ollama rm "$old" >/dev/null 2>&1; done
    while IFS='|' read -r name rsize _; do
        [[ -n "$name" ]] || continue
        if (( rsize > AET_BIG_MODEL_BYTES )) && ! confirm "pull $name (<= $(fmt_gb "$rsize"))?" big; then
            res_add "model $name" "-" "-" skipped "not confirmed (> 10 GB)"; continue; fi
        local before after
        before=$(res local-config "$name" </dev/null); ollama cp "$name" "$(prev_name "$name")" >>"$AET_LOG" 2>&1
        info "pulling $name (<= $(fmt_gb "$rsize"))"
        if ollama pull "$name" >>"$AET_LOG" 2>&1; then
            after=$(res local-config "$name" </dev/null)
            if [[ "$before" == "$after" ]]; then res_add "model $name" "$before" "$after" current "already up to date"
            else res_add "model $name" "$before" "$after" updated "previous kept as $(prev_name "$name") until next run"; lock_set "MODEL_$(echo "$name" | tr -c 'A-Za-z0-9\n' '_')" "$after"; fi
        else res_add "model $name" "$before" "?" failed "pull failed; previous version untouched"; fi
    done < <({ grep -v '^DERIVED|' "$todo" | grep -v "^$last|"; grep "^$last|" "$todo"; })
}
# Derived models: re-create from ~/.aetulla/modelfiles/<name>.Modelfile after their base changed, then
# PROVE the context window: load it and require `ollama ps` to show the Modelfile's num_ctx.
list_id() { ollama list 2>/dev/null | awk -v n="$1" '$1==n || $1==n":latest" {print $2}'; }   # the ID `ollama list` shows
apply_derived() {
    local n base mf want ctx llm old_id
    llm=$(env_get "$AET_ROOT/.env" LLM_MODEL qwen2.5:14b-instruct)
    while IFS='|' read -r _ n base; do
        mf="$AET_MODELFILES/$n.Modelfile"
        want=$(sed -n 's/^PARAMETER[[:space:]]\{1,\}num_ctx[[:space:]]\{1,\}\([0-9]\{1,\}\).*/\1/p' "$mf" | head -1)
        confirm "re-create $n from $base and load it once to verify CONTEXT ${want:-?}. Loading ~23 GB displaces the resident $llm (restored afterwards). Hermes must be idle. Proceed?" always \
            || { res_add "model $n" "-" "-" skipped "re-create not confirmed"; continue; }
        old_id=$(list_id "$n")
        if ! ollama create "$n" -f "$mf" >>"$AET_LOG" 2>&1; then res_add "model $n" "${old_id:-?}" "${old_id:-?}" failed "ollama create failed"; continue; fi
        curl -fsS -m 600 -X POST "$(ollama_url)/api/generate" -d "{\"model\":\"$n\",\"prompt\":\"\",\"keep_alive\":\"2m\"}" >/dev/null 2>&1
        ctx=$(ollama ps | grep "^$n" | head -1)
        if [[ -n "$want" ]] && echo "$ctx" | grep -qw "$want"; then ok "$n: ollama ps shows CONTEXT $want"; res_add "model $n" "${old_id:-?}" "$(list_id "$n")" updated "re-created; CONTEXT $want verified"
        else bad "$n: ollama ps does NOT show CONTEXT ${want:-?}: ${ctx:-not loaded}"; res_add "model $n" "${old_id:-?}" "$(list_id "$n")" failed "CONTEXT ${want:-?} not confirmed — fix before using Hermes"; fi
        curl -fsS -m 60 -X POST "$(ollama_url)/api/generate" -d "{\"model\":\"$n\",\"prompt\":\"\",\"keep_alive\":0}" >/dev/null 2>&1
        curl -fsS -m 600 -X POST "$(ollama_url)/api/generate" -d "{\"model\":\"$llm\",\"prompt\":\"ok\",\"stream\":false,\"keep_alive\":\"24h\"}" >/dev/null 2>&1
        echo "  ollama ps after restoring $llm:"; ollama ps | sed 's/^/    /'
    done < <(grep '^DERIVED|' "$AET_MODELS_TODO")
}

# --- main ---------------------------------------------------------------------------------------
update_apply_latest() {
    echo "Aetulla update (channel: latest)"
    preflight_light
    net_ok || { ok "offline — update check skipped. Nothing was changed."; return 0; }
    preflight; git_mode; apply_init
    ensure_stack_up          # stopped after a reboot/prune: start it on the locked versions first (not "pre-state unreadable")
    info "GitHub API: $(res github-rate || echo unknown)"
    PLAN_FILE=$(mktemp); AET_MODELS_TODO=$(mktemp)
    resolve_targets; build_rows
    echo; print_rows "$PLAN_FILE" 20 component current target status note | tee -a "$AET_LOG"
    if (( AET_MODELS )) && want models; then models_plan | tee -a "$AET_LOG"; fi
    local n_up; n_up=$(grep -c '|update|' "$PLAN_FILE"); [[ -s "$AET_MODELS_TODO" ]] && n_up=$((n_up + 1))
    if (( n_up == 0 )); then ok "up to date — nothing resolved newer"; rm -f "$AET_WORK_LOCK"; return 0; fi
    local what
    what=$(awk -F'|' '$4=="update"{ if ($2==$3) printf "%s%s (%s)", sep, $1, $5; else printf "%s%s %s -> %s", sep, $1, $2, $3; sep="; "}' "$PLAN_FILE" | sed -E 's/(sha256:[0-9a-f]{12})[0-9a-f]+/\1/g')
    if [[ -s "$AET_MODELS_TODO" ]]; then what="${what:+$what; }models: $(grep -vc '^DERIVED|' "$AET_MODELS_TODO") pull(s), $(grep -c '^DERIVED|' "$AET_MODELS_TODO") rebuild(s)"; fi
    echo; echo "  Backup first (DBs, open-webui files, every Qdrant collection, image tags); each component is rolled back on its own if its health check fails."
    confirm "Proceed with: $what ?" || { echo "  aborted, nothing changed"; rm -f "$AET_WORK_LOCK"; return 1; }
    backup_create || die "backup failed — nothing was changed"
    cp "$(eff_lock)" "$BK/versions.prev.lock"; eff_lock > "$BK/versions.prev.lock.src"
    info ".env: $(env_merge)"
    local c_owui c_n8n c_curl c_pw c_q
    c_owui=$(cur_or "$(tag_of "$(ctr_image open-webui)")" "$(lock_val_eff OPENWEBUI_VERSION)")
    c_n8n=$(cur_or "$(tag_of "$(ctr_image n8n)")" "$(lock_val_eff N8N_VERSION)")
    c_curl=$(cur_or "$(tag_of "$(ctr_image ollama-keepalive)")" "$(lock_val_eff CURL_VERSION)")
    c_pw=$(cur_or "$(ctr_pw_version playwright)" "$(lock_val_eff PLAYWRIGHT_VERSION)")
    c_q=$(cur_or "$(tag_of "$(ctr_image mem0_store)")" "$(lock_val_eff QDRANT_VERSION)")
    local old_py old_mem0 old_stt; old_py=$(lock_get PY_BASE_DIGEST); old_mem0=$(lock_get MEM0_BASE_DIGEST); old_stt=$(lock_get STT_BASE_DIGEST)

    # 1 lowest risk first: the curl sidecar
    want keepalive && [[ -n $T_CURL && $T_CURL != "$c_curl" ]] && apply_component keepalive ollama-keepalive pull "CURL_VERSION=$T_CURL" "$c_curl" "$T_CURL"
    # 2 web-extractor / tts / playwright. PY_BASE_DIGEST is ONE key shared by web-extractor and tts: a bump,
    # or a dependent still built on an older base (image label), rebuilds ALL of them in ONE component,
    # whichever --only selected it. Playwright server + web-extractor client always move together.
    if want playwright || want build; then
        local want_py stale_py pw_chg=0 py_chg=0 need_web=0 need_tts=0 svcs name olab nlab kv extra=""
        want_py=${T_PY:-$old_py}
        # shellcheck disable=SC2046,SC2086  # PY_DEPENDENTS is a space-separated list on purpose
        stale_py=" $(stale_dependents "$want_py" $PY_DEPENDENTS | tr '\n' ' ')"
        if [[ -n $T_PW && $T_PW != "$c_pw" ]]; then pw_chg=1; fi
        if [[ -n $T_PY && $T_PY != "$old_py" ]]; then py_chg=1; fi
        if (( pw_chg || py_chg )) || [[ $stale_py == *" web-extractor "* ]]; then need_web=1; fi
        if docker image inspect "$(local_image_name tts)" >/dev/null 2>&1 && { (( py_chg )) || [[ $stale_py == *" tts "* ]]; }; then need_tts=1; extra=tts; fi
        svcs="web-extractor"; (( pw_chg )) && svcs="playwright web-extractor"
        olab=""; nlab=""
        if (( pw_chg )); then olab="pw $c_pw"; nlab="pw $T_PW"; fi
        if (( py_chg )); then olab="${olab:+$olab, }py $(disp "$old_py")"; nlab="${nlab:+$nlab, }py $(disp "$T_PY")"; fi
        if [[ -z $olab ]]; then olab="older base"; nlab="py $(disp "$want_py")"; fi
        name="web-extractor"; (( pw_chg )) && name="playwright+web-extractor"; (( need_tts )) && name="$name+tts"
        kv="PLAYWRIGHT_VERSION=${T_PW:-$c_pw} PY_BASE_DIGEST=$want_py"
        if (( need_web )); then
            apply_component "$name" "$svcs" build "$kv" "$olab" "$nlab" "" "$extra" playwright
        elif (( need_tts )); then
            apply_component tts tts build-only "$kv" "$olab" "$nlab"
        fi
    fi
    # 3 stt: own base (CUDA), build only (the voice profile is never started here)
    if want build && [[ -n $T_STT && $T_STT != "$old_stt" ]]; then
        apply_component stt stt build-only "STT_BASE_DIGEST=$T_STT" "$(disp "$old_stt")" "$(disp "$T_STT")"
    fi
    # 4 n8n (direct jump; the backup above is the safety net)
    want n8n && [[ -n $T_N8N && $T_N8N != "$c_n8n" ]] && apply_component n8n n8n pull "N8N_VERSION=$T_N8N" "$c_n8n" "$T_N8N"
    # 5 Open WebUI: pre-check + REQUIRED filter-recall; failure restores its image AND its DB
    want open-webui && [[ -n $T_OWUI && $T_OWUI != "$c_owui" ]] && apply_component open-webui open-webui pull "OPENWEBUI_VERSION=$T_OWUI" "$c_owui" "$T_OWUI" pre_open_webui
    # 6 mem0 (rebuild from newest upstream base + patch-source check)
    want mem0 && [[ -n $T_MEM0 && $T_MEM0 != "$old_mem0" ]] && apply_component mem0 mem0 build "MEM0_BASE_DIGEST=$T_MEM0" "$(disp "$old_mem0")" "$(disp "$T_MEM0")" pre_mem0
    # 7 Ollama binary (opt-in)
    if want ollama && (( AET_WITH_OLLAMA )) && [[ -n $T_OLLAMA ]]; then
        local c_o; c_o=$(curl -fsS -m 5 "$(ollama_url)/api/version" | python3 -I -c 'import sys,json;print(json.load(sys.stdin)["version"])' 2>/dev/null)
        [[ "$c_o" != "$T_OLLAMA" ]] && apply_ollama_binary "$c_o" "$T_OLLAMA"
    fi
    # 8 models, then derived models
    if (( AET_MODELS )) && want models; then apply_models; apply_derived; fi
    # 9 Qdrant LAST, only when everything before it succeeded
    if want qdrant && [[ -n $T_QDRANT && $T_QDRANT != "$c_q" ]]; then
        if (( AET_APPLY_FAILED )); then res_add qdrant "$c_q" "$T_QDRANT" skipped "an earlier component failed; resolve that first"
        else apply_qdrant "$(res hub-tags qdrant/qdrant v | res qdrant-path "$c_q" "$T_QDRANT")" "$c_q"; fi
    fi

    # what is actually installed now -> resolved.lock (never in the repo)
    lock_set OLLAMA_VERSION "$(curl -fsS -m 5 "$(ollama_url)/api/version" | python3 -I -c 'import sys,json;print(json.load(sys.stdin)["version"])' 2>/dev/null)"
    mv "$AET_WORK_LOCK" "$AET_LOCK_RESOLVED" && chmod 600 "$AET_LOCK_RESOLVED"
    hw_bump "$AET_LOCK_RESOLVED"     # migrated data can not go back: remember the highest versions that ran
    echo; echo "━━━ Aetulla update: summary ━━━"
    print_rows "$AET_RESULTS" 40 component old new status detail | tee -a "$AET_LOG"
    echo "  backup: $BK    lock: $AET_LOCK_RESOLVED    log: $AET_LOG"
    rm -f "$AET_RESULTS" "$PLAN_FILE" "$AET_MODELS_TODO"
    (( AET_APPLY_FAILED == 0 ))
}
