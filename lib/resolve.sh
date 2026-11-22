#!/usr/bin/env bash
# Version resolution + the `aetulla update --dry-run` report. Sourced by lib/aetulla.sh, never run.
#
# Everything here is READ-ONLY: no image pull, no build, no container/daemon restart, no sudo,
# no model download. Network use = HTTPS GETs to official sources, parsed by lib/resolve.py.
# bash 3.2 compatible (no associative arrays, no mapfile): rows live in a temp file, `|`-separated.

# shellcheck disable=SC2034  # globals shared with the other sourced lib files (aetulla.sh, apply.sh)
AET_STATE="${AETULLA_HOME:-$HOME/.aetulla}"
AET_LOCK_COMMITTED="$AET_ROOT/versions.lock"      # the tested set shipped in the repo
AET_LOCK_RESOLVED="$AET_STATE/resolved.lock"      # result of the last successful `latest` run (never in the repo)
AET_MODELFILES="$AET_STATE/modelfiles"            # <ollama-name>.Modelfile for models WE derive (personal, not in repo)
AET_CHANNEL=latest
AET_DRYRUN=0
AET_WITH_OLLAMA=0     # Ollama binary upgrade needs sudo + the official installer: opt-in
AET_MODELS=1
AET_BIG_MODEL_BYTES=$((10 * 1000 * 1000 * 1000))  # ask before pulling anything above this

res() { python3 -I "$AET_ROOT/lib/resolve.py" "$@" 2>>"${AET_LOG:-/dev/null}"; }
lock_val() { env_get "$1" "$2"; }                 # lock_val FILE KEY
eff_lock() { if [[ -f "$AET_LOCK_RESOLVED" ]]; then echo "$AET_LOCK_RESOLVED"; else echo "$AET_LOCK_COMMITTED"; fi; }
lock_val_eff() { # what is (believed to be) installed for a key: resolved.lock, else the committed set
    local v; v=$(lock_val "$(eff_lock)" "$1"); [[ -n "$v" ]] || v=$(lock_val "$AET_LOCK_COMMITTED" "$1"); echo "$v"
}
cur_or() { if [[ -n "$1" ]]; then echo "$1"; else echo "$2"; fi; }
disp() { case "$1" in sha256:*) echo "sha256:${1:7:12}";; *) echo "$1";; esac; }

# --- targets --------------------------------------------------------------
# Sets T_<comp> (empty = could not resolve) and N_<comp> (reason). `locked` reads versions.lock;
# `latest` asks the official sources and refuses anything that is not plain MAJOR.MINOR.PATCH.
resolve_targets() {
    local L=$AET_LOCK_COMMITTED
    N_OWUI=; N_N8N=; N_QDRANT=; N_CURL=; N_PW=; N_MEM0=; N_PY=; N_STT=; N_OLLAMA=
    if [[ $AET_CHANNEL == locked ]]; then
        T_OWUI=$(lock_val "$L" OPENWEBUI_VERSION); T_N8N=$(lock_val "$L" N8N_VERSION)
        T_QDRANT=$(lock_val "$L" QDRANT_VERSION);  T_CURL=$(lock_val "$L" CURL_VERSION)
        T_PW=$(lock_val "$L" PLAYWRIGHT_VERSION);  T_MEM0=$(lock_val "$L" MEM0_BASE_DIGEST)
        T_PY=$(lock_val "$L" PY_BASE_DIGEST);      T_STT=$(lock_val "$L" STT_BASE_DIGEST)
        T_OLLAMA=
        return
    fi
    # Open WebUI: the release GitHub marks Latest. Whether the image tag exists is decided by `docker pull` at apply time.
    T_OWUI=$(res github-latest open-webui/open-webui) || { T_OWUI=; N_OWUI="cannot resolve release"; }
    # Playwright is NOT independent: it must equal what that Open WebUI release bundles (else 428).
    if [[ -n $T_OWUI ]]; then
        T_PW=$(res owui-playwright "$T_OWUI") || { T_PW=; N_PW="cannot read Open WebUI's pin"; }
    else
        T_PW=; N_PW="needs a resolved Open WebUI target"
    fi
    # n8n: ask n8n's own update-notification API (what its UI banner uses), not GitHub, so "stable" means
    # exactly what n8n says. No fallback to another source: if it is unreachable the row is `unresolved`.
    T_N8N=$(res n8n-latest "$(cur_or "$(tag_of "$(ctr_image n8n)")" "$(lock_val_eff N8N_VERSION)")") || { T_N8N=; N_N8N="n8n versions API unreachable"; }
    T_QDRANT=$(res hub-latest qdrant/qdrant v) || { T_QDRANT=; N_QDRANT="cannot resolve tags"; }
    if [[ -n "${AET_QDRANT_TO:-}" && -n $T_QDRANT ]]; then   # stop the chain early (e.g. 1.12.6 = just the first step)
        if res hub-tags qdrant/qdrant v | grep -qxF "$AET_QDRANT_TO"; then T_QDRANT=$AET_QDRANT_TO
        else T_QDRANT=; N_QDRANT="--qdrant-to $AET_QDRANT_TO is not a published vX.Y.Z tag"; fi
    fi
    T_CURL=$(res hub-latest curlimages/curl) || { T_CURL=; N_CURL="cannot resolve tags"; }
    # Digests of floating tags: the tag is only used to find the digest; the digest is what gets pinned.
    T_MEM0=$(res hub-digest mem0/openmemory-mcp latest) || { T_MEM0=; N_MEM0="cannot resolve digest"; }
    T_PY=$(res hub-digest library/python 3.12-slim)     || { T_PY=;   N_PY="cannot resolve digest"; }
    T_STT=$(res hub-digest nvidia/cuda 12.8.0-base-ubuntu24.04) || { T_STT=; N_STT="cannot resolve digest"; }
    T_OLLAMA=$(res github-latest ollama/ollama) || { T_OLLAMA=; N_OLLAMA="cannot resolve release"; }
}

# --- report -----------------------------------------------------------------
# Services that share PY_BASE_DIGEST (web-extractor, tts): one base bump must rebuild ALL of them.
# Stale = image exists but its aetulla.base-digest label differs from the base we want (no label = stale).
PY_DEPENDENTS="web-extractor tts"
stale_dependents() { # stale_dependents WANTED_DIGEST SERVICE...  -> names of services to rebuild
    local want=$1 s img lab; shift
    for s in "$@"; do
        img=$(local_image_name "$s")
        docker image inspect "$img" >/dev/null 2>&1 || continue          # never built here: nothing to refresh
        lab=$(docker image inspect -f '{{index .Config.Labels "aetulla.base-digest"}}' "$img" 2>/dev/null)
        [[ "$lab" == "$want" ]] || echo "$s"
    done
}
row() { # row COMP CURRENT TARGET NOTE [force-update]   (empty TARGET = unresolved)
    local st tgt=$3
    if [[ -z $tgt ]]; then st=unresolved; tgt="?"; elif [[ "$2" == "$3" && -z "${5:-}" ]]; then st=current; else st=update; fi
    printf '%s|%s|%s|%s|%s\n' "$1" "${2:-?}" "$tgt" "$st" "$([[ $st == current ]] || echo "$4")" >> "$PLAN_FILE"
}
print_rows() { # print_rows FILE COL1_WIDTH HEADER...
    local f=$1 w=$2; shift 2
    printf "%-${w}s %-22s %-22s %-11s %s\n" "$@"
    while IFS='|' read -r c a b s n; do
        printf "%-${w}s %-22s %-22s %-11s %s\n" "$c" "$(disp "$a")" "$(disp "$b")" "$s" "$n"
    done < "$f"
}

build_rows() {
    local cur steps
    cur=$(cur_or "$(tag_of "$(ctr_image open-webui)")" "$(lock_val_eff OPENWEBUI_VERSION)")
    row open-webui "$cur" "$T_OWUI" "$N_OWUI"
    cur=$(cur_or "$(ctr_pw_version playwright)" "$(lock_val_eff PLAYWRIGHT_VERSION)")
    row playwright "$cur" "$T_PW" "${N_PW:-rebuild; = version bundled in Open WebUI}"
    cur=$(cur_or "$(ctr_pw_version web-extractor)" "$(lock_val_eff PLAYWRIGHT_VERSION)")
    row web-extractor "$cur" "$T_PW" "${N_PW:-rebuild with the Playwright client above}"
    cur=$(cur_or "$(tag_of "$(ctr_image n8n)")" "$(lock_val_eff N8N_VERSION)")
    row n8n "$cur" "$T_N8N" "$N_N8N"
    cur=$(cur_or "$(tag_of "$(ctr_image ollama-keepalive)")" "$(lock_val_eff CURL_VERSION)")
    row ollama-keepalive "$cur" "$T_CURL" "${N_CURL:-curl sidecar image}"
    row mem0-base "$(lock_val_eff MEM0_BASE_DIGEST)" "$T_MEM0" "${N_MEM0:-rebuild + patch-source check after pull}"
    local want_py stale; want_py=${T_PY:-$(lock_val_eff PY_BASE_DIGEST)}
    # shellcheck disable=SC2046,SC2086  # PY_DEPENDENTS is a space-separated list on purpose
    stale=$(stale_dependents "$want_py" $PY_DEPENDENTS | tr '\n' ' '); stale=${stale% }
    if [[ -n $stale && -n $T_PY ]]; then row python-base "$(lock_val_eff PY_BASE_DIGEST)" "$T_PY" "rebuild: $stale (built on an older base)" force
    else row python-base "$(lock_val_eff PY_BASE_DIGEST)" "$T_PY" "${N_PY:-rebuild: $PY_DEPENDENTS}"; fi
    row cuda-base "$(lock_val_eff STT_BASE_DIGEST)" "$T_STT" "${N_STT:-stt rebuild (build only; voice profile stays off)}"
    cur=$(cur_or "$(tag_of "$(ctr_image mem0_store)")" "$(lock_val_eff QDRANT_VERSION)")
    if [[ -n $T_QDRANT && "$cur" != "$T_QDRANT" ]]; then
        steps=$(res hub-tags qdrant/qdrant v | res qdrant-path "$cur" "$T_QDRANT") || steps=
        if [[ -n $steps ]]; then row qdrant "$cur" "$T_QDRANT" "steps: ${steps// / → }"
        else row qdrant "$cur" "$T_QDRANT" "cannot compute upgrade path"; fi
    else
        row qdrant "$cur" "$T_QDRANT" "$N_QDRANT"
    fi
    cur=$(curl -fsS -m 5 "$(ollama_url)/api/version" 2>/dev/null | python3 -I -c 'import sys,json;print(json.load(sys.stdin)["version"])' 2>/dev/null)
    row ollama-binary "$cur" "$T_OLLAMA" "${N_OLLAMA:-$([[ $AET_WITH_OLLAMA == 1 ]] || echo 'opt-in: --with-ollama (sudo + official installer)')}"
    if [[ -n "$AET_ONLY" ]]; then   # --only: rows of components that are not selected are marked, never "update"
        local tmp c a b s n; tmp=$(mktemp)
        while IFS='|' read -r c a b s n; do
            if only_selects "$c"; then printf '%s|%s|%s|%s|%s\n' "$c" "$a" "$b" "$s" "$n"
            else printf '%s|%s|%s|%s|%s\n' "$c" "$a" "$b" skipped "(--only)"; fi
        done < "$PLAN_FILE" > "$tmp" && mv "$tmp" "$PLAN_FILE"
    fi
}
only_selects() { # does --only select the component behind this plan row?
    case $1 in
        open-webui) want open-webui ;;
        playwright|web-extractor) want playwright ;;
        python-base) want playwright || want build ;;
        cuda-base) want build ;;
        n8n) want n8n ;;
        ollama-keepalive) want keepalive ;;
        mem0-base) want mem0 ;;
        qdrant) want qdrant ;;
        ollama-binary) want ollama ;;
        *) return 0 ;;
    esac
}

# --- models ------------------------------------------------------------------
# ID shown by `ollama list` == first 12 hex of the model's config digest == /api/tags `digest`.
modelfile_names() { local f; for f in "$AET_MODELFILES"/*.Modelfile; do [[ -e $f ]] && basename "$f" .Modelfile; done; }
modelfile_base() { sed -n 's/^FROM[[:space:]]\{1,\}//p' "$AET_MODELFILES/$1.Modelfile" | head -1; }
is_derived() { local n; for n in $(modelfile_names); do [[ "$1" == "$n" || "$1" == "$n:latest" ]] && return 0; done; return 1; }
is_embed() { local e; e=$(env_get "$AET_ROOT/.env" EMBED_MODEL nomic-embed-text); [[ "$1" == "$e" || "$1" == "$e:latest" || "$1" == "${e%:latest}:latest" ]]; }
fmt_gb() { awk -v b="$1" 'BEGIN{if (b < 1e8) printf "%.0f MB", b/1e6; else printf "%.1f GB", b/1e9}'; }

models_plan() { # read-only: compares local IDs with the registry, downloads nothing
    local tags name id size rid rsize st note total=0 big=0 f base bst n
    tags=$(curl -fsS -m 10 "$(ollama_url)/api/tags" 2>/dev/null | python3 -I -c '
import sys, json
for m in json.load(sys.stdin)["models"]:
    print(m["name"], m["digest"][:12], m["size"])') || { warn "models: Ollama not reachable — skipped"; return; }
    f=$(mktemp)
    while read -r name id _; do
        if is_derived "$name"; then continue; fi
        if out=$(res ollama-model "$name" </dev/null); then   # </dev/null: never eat the loop's stdin
            rid=${out%% *}; rsize=${out##* }
            # Compare CONFIG digests (see resolve.py local-config): `ollama list`'s ID is not comparable.
            id=$(res local-config "$name" </dev/null) || id="?"
            if [[ "$id" == "?" ]]; then st=check; note="local manifest unreadable: the real run pulls and compares IDs before/after"
            elif [[ "$rid" == "$id" ]]; then st=current; note=
            else
                st=update; note="download <= $(fmt_gb "$rsize")"
                total=$((total + rsize))
                if (( rsize > AET_BIG_MODEL_BYTES )); then note="$note  ASK FIRST (>10 GB)"; big=$((big + 1)); fi
            fi
            if is_embed "$name"; then
                [[ $st == update ]] && note="changed upstream — NOT pulled (embedding model, Qdrant depends on it)" || note="embedding model: never re-pulled"
                st=$([[ $st == update ]] && echo skip-embed || echo current)
            fi
        else rid="?"; st=unresolved; note="registry lookup failed (not compared, not pulled)"; fi
        printf '%s|%s|%s|%s|%s\n' "$name" "$id" "$rid" "$st" "$note" >> "$f"
        # the apply path pulls exactly these ("check" = local manifest unreadable: pull and compare)
        [[ -n "${AET_MODELS_TODO:-}" && ( $st == update || $st == check ) ]] && echo "$name|${rsize:-0}|$st" >> "$AET_MODELS_TODO"
    done <<EOF
$tags
EOF
    for n in $(modelfile_names); do   # derived models: rebuilt only when their base changed
        base=$(modelfile_base "$n")
        bst=$(grep -m1 "^$base|" "$f" | cut -d'|' -f4)
        id=$(res local-config "$n:latest" </dev/null) || id=$(echo "$tags" | awk -v n="$n" '$1==n||$1==n":latest"{print $2}')
        case "$bst" in
            update)  st=rebuild;  note="from $base, after its pull; verify CONTEXT via ollama ps; ASK before unloading" ;;
            current) st=current;  note="base $base unchanged" ;;
            *)       st=unknown;  note="base $base: ${bst:-not installed}" ;;
        esac
        printf '%s|%s|%s|%s|%s\n' "$n" "${id:-?}" "(derived)" "$st" "$note" >> "$f"
        [[ -n "${AET_MODELS_TODO:-}" && $st == rebuild ]] && echo "DERIVED|$n|$base" >> "$AET_MODELS_TODO"
    done
    echo; echo "Models (tag refresh = blanket yes; > 10 GB asks per model)"
    print_rows "$f" 48 model local-config remote-config status note
    echo "  total download upper bound: $(fmt_gb "$total") (ollama transfers only changed layers); $big model(s) need a per-model OK"
    rm -f "$f"
}

# --- the dry run ---------------------------------------------------------------
update_dry_run() {
    echo "Aetulla update --dry-run   channel: $AET_CHANNEL   (nothing is pulled, built, restarted or written)"
    preflight_light
    mkdir -p "$AET_STATE/logs" && AET_LOG="$AET_STATE/logs/update-dryrun-$(date +%Y%m%d-%H%M%S).log"
    : > "$AET_LOG"
    echo "  GitHub API: $(res github-rate || echo 'unknown')"
    if [[ $AET_CHANNEL == latest ]] && ! net_ok; then ok "offline — nothing to resolve"; return 0; fi
    PLAN_FILE=$(mktemp)
    resolve_targets
    build_rows
    echo
    print_rows "$PLAN_FILE" 20 component current target status note | tee -a "$AET_LOG"
    if (( AET_MODELS )) && want models; then models_plan | tee -a "$AET_LOG"; fi
    local free; free=$(df -Pk "$HOME" | awk 'NR==2{print int($4/1024/1024)}')
    echo; echo "  free disk: ${free} GB   log: $AET_LOG"
    rm -f "$PLAN_FILE"
}
