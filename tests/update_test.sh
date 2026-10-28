#!/usr/bin/env bash
# shellcheck disable=SC2016  # bash -c bodies are single-quoted on purpose (the subshell expands them)
# Tests for bin/aetulla that never touch the real stack, volumes or .env.
# The destructive proof (forced failure -> automatic rollback) is documented at the
# bottom and run by hand: HEALTH_FORCE_FAIL=open-webui bin/aetulla update
set -o pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; failn=0
t() { # t "name" command...
    local n=$1; shift
    if "$@" >"$T/out" 2>&1; then echo "ok   $n"; pass=$((pass+1)); else echo "FAIL $n"; sed 's/^/     /' "$T/out"; failn=$((failn+1)); fi
}

# Fixture root: fake .env/.env.example, no secrets.
export AET_ROOT="$T/root"; mkdir -p "$AET_ROOT/web-extractor"
printf 'A=1\nB=keep-me\n' > "$AET_ROOT/.env"
printf 'A=default\nB=default\nNEW_KEY=hello\n# COMMENTED=1\n' > "$AET_ROOT/.env.example"
printf 'fastapi==1\n' > "$AET_ROOT/web-extractor/requirements.txt"
# shellcheck disable=SC1091  # path computed from this script's location
source "$HERE/lib/aetulla.sh"

# 1. .env merge adds only new keys and never rewrites existing values
t "env_merge adds new key"        bash -c 'source "$0"; env_merge | grep -q NEW_KEY' "$HERE/lib/aetulla.sh"
t "env_merge keeps existing"      bash -c 'grep -qx "B=keep-me" "$AET_ROOT/.env" && grep -qx "A=1" "$AET_ROOT/.env"'
t "env_merge idempotent"          bash -c 'source "$0"; [ "$(env_merge)" = "no new keys" ]' "$HERE/lib/aetulla.sh"

# 2. dev guard: not on a tag => dev; tag + clean => release; tag + dirty => dev
git -C "$AET_ROOT" init -q && git -C "$AET_ROOT" -c user.email=t@t -c user.name=t add -A >/dev/null 2>&1
git -C "$AET_ROOT" -c user.email=t@t -c user.name=t commit -qm init
git_mode; t "dev guard: untagged"   test "$GIT_MODE" = dev
git -C "$AET_ROOT" tag v0.0.1
git_mode; t "release: tag + clean"  test "$GIT_MODE" = release
echo x >> "$AET_ROOT/.env.example"; git_mode
t "dev guard: tag + dirty"          test "$GIT_MODE" = dev

# 3. plain `docker compose` works with no wrapper and shows the pinned tags; nothing floats
t "plain compose shows pins"  bash -c "cd '$HERE' && docker compose config --images | grep -q 'open-webui:v[0-9]'"
t "no :latest images"         bash -c "! grep -E '^[[:space:]]+image:.*:latest' '$HERE/docker-compose.yml'"
t "no unpinned/variable image tags" bash -c "! grep -E '^[[:space:]]+image:.*[\$]' '$HERE/docker-compose.yml'"

# 4. Playwright: ONE place for the version, no runtime download, server == client
t "playwright version written exactly once" bash -c "ver=\$(docker compose -f '$HERE/docker-compose.yml' --env-file /dev/null config --format json 2>/dev/null | python3 -I -c 'import json,sys;print(json.load(sys.stdin)[\"services\"][\"playwright\"][\"build\"][\"args\"][\"PLAYWRIGHT_VERSION\"])'); n=\$(grep -rF \"\$ver\" '$HERE/docker-compose.yml' '$HERE/playwright' '$HERE/web-extractor' | wc -l); echo \"version=\$ver occurrences=\$n\"; [ \"\$n\" -eq 1 ]"
t "no npx -y in compose"             bash -c "! grep -n 'npx -y' '$HERE/docker-compose.yml'"
t "playwright is a local build"       bash -c "docker compose -f '$HERE/docker-compose.yml' --env-file /dev/null config --images 2>/dev/null | grep -qx 'aetulla-playwright:local'"
t "server arg == web-extractor arg"   bash -c "source '$HERE/lib/aetulla.sh'; read -r a b < <(docker compose -f '$HERE/docker-compose.yml' --env-file /dev/null config --format json 2>/dev/null | pins_from_json); echo \"server=\$a client=\$b\"; [ -n \"\$a\" ] && [ \"\$a\" = \"\$b\" ]"
t "extractor reqs have no playwright pin" bash -c "! grep -qi '^playwright' '$HERE/web-extractor/requirements.txt'"
t "pin check detects npx command"     bash -c "source '$HERE/lib/aetulla.sh'; docker compose -f '$HERE/docker-compose.yml' --env-file /dev/null config --format json 2>/dev/null | sed 's|\"command\": \[|\"command\": [\"npx\", |' | pins_from_json"'; [ $? -ne 0 ]'
t "pin check detects a version split" bash -c "source '$HERE/lib/aetulla.sh'; docker compose -f '$HERE/docker-compose.yml' --env-file /dev/null config --format json 2>/dev/null | python3 -I -c 'import json,sys;d=json.load(sys.stdin);d[\"services\"][\"web-extractor\"][\"build\"][\"args\"][\"PLAYWRIGHT_VERSION\"]=\"0.0.1\";print(json.dumps(d))' | pins_from_json | awk '{exit (\$1==\$2)}'"
t "all three local builds are tracked" bash -c "source '$HERE/lib/aetulla.sh'; [[ \" \${LOCAL_BUILDS[*]} \" == *\" mem0 \"* && \" \${LOCAL_BUILDS[*]} \" == *\" web-extractor \"* && \" \${LOCAL_BUILDS[*]} \" == *\" playwright \"* ]]"

# 4b. rollback restores the local images (web-extractor AND playwright) under their compose names
t "rollback restores both local images" bash -c '
    source "$0"; TB=$(mktemp -d); local_image_name() { echo "aetulla-test/$1:t"; }
    A=$(docker image inspect -f "{{.Id}}" curlimages/curl:8.10.1); B=$(docker image inspect -f "{{.Id}}" qdrant/qdrant:v1.12.4)
    printf "web-extractor=%s\nplaywright=%s\n" "$A" "$B" > "$TB/local-images.env"
    restore_local_images "$TB"
    x=$(docker image inspect -f "{{.Id}}" aetulla-test/web-extractor:t); y=$(docker image inspect -f "{{.Id}}" aetulla-test/playwright:t)
    docker rmi aetulla-test/web-extractor:t aetulla-test/playwright:t >/dev/null; rm -rf "$TB"
    [ "$x" = "$A" ] && [ "$y" = "$B" ]' "$HERE/lib/aetulla.sh"

# 4c. data integrity rule (lib/dbfp.py): logical hash, never a byte hash.
#     restore gate (before start): logical == manifest. After healthy: integrity ok, same schema
#     version, no table lost rows; logical hash is informational ("changed since restore").
t "WAL-bearing DB backs up + restores to the same logical hash, gates behave" python3 -I - "$HERE/lib" <<'PY'
import hashlib, os, shutil, sqlite3, sys, tempfile
sys.path.insert(0, sys.argv[1])
import dbfp
T = tempfile.mkdtemp()
live = os.path.join(T, "live.db")
c = sqlite3.connect(live)
c.execute("pragma journal_mode=wal"); c.execute("pragma wal_autocheckpoint=0")
c.execute("create table alembic_version(version_num text)"); c.execute("insert into alembic_version values('abc123')")
c.execute("create table t(id integer primary key, v text)")
c.executemany("insert into t(v) values(?)", [(f"row{i}",) for i in range(200)]); c.commit()
assert os.path.getsize(live + "-wal") > 0, "test needs a NON-empty WAL"
fp_live = dbfp.fingerprint(live)                           # fingerprint reads main+wal from a copy
for mode in (True, False):                                 # service running / stopped: same result
    bk = os.path.join(T, f"bk{mode}.db")
    dbfp.backup_db(live, bk, live=mode)
    assert not os.path.exists(bk + "-wal") and not os.path.exists(bk + "-shm"), "backup must be one file"
    assert sqlite3.connect(bk).execute("pragma journal_mode").fetchone()[0] == "delete"
    assert dbfp.fingerprint(bk)["logical"] == fp_live["logical"], f"backup(live={mode}) logical hash differs"
man = dict(dbfp.fingerprint(os.path.join(T, "bkTrue.db")))
# restore = copy the single backup file into the volume (journals removed), then the gate
vol = os.path.join(T, "vol"); os.mkdir(vol); d = os.path.join(vol, "restored.db")
shutil.copyfile(os.path.join(T, "bkTrue.db"), d)
ok, _ = dbfp.check_restored(d, man); assert ok, "restore gate must pass for an intact restore"
# bytes may change without any data change (WAL checkpoint): logical hash must not
before = hashlib.sha256(open(live, "rb").read()).hexdigest(); c.close()
after = hashlib.sha256(open(live, "rb").read()).hexdigest()
assert before != after, "expected the main file bytes to change once the WAL is folded in"
assert dbfp.fingerprint(live)["logical"] == fp_live["logical"], "checkpoint must not change the logical hash"
# after-healthy gates
p, changed, _ = dbfp.check_after_healthy(d, man); assert not p and not changed
x = sqlite3.connect(d); x.execute("insert into t(v) values('boot write')"); x.commit(); x.close()
p, changed, _ = dbfp.check_after_healthy(d, man); assert not p and changed, "a boot write is informational, not a failure"
x = sqlite3.connect(d); x.execute("delete from t where id < 10"); x.commit(); x.close()
p, _, _ = dbfp.check_after_healthy(d, man); assert any("table t" in m for m in p), "lost rows must fail"
x = sqlite3.connect(d); x.execute("update alembic_version set version_num='zzz'"); x.commit(); x.close()
p, _, _ = dbfp.check_after_healthy(d, man); assert any("schema version" in m for m in p), "schema change must fail"
bad = os.path.join(vol, "bad.db"); shutil.copyfile(os.path.join(T, "bkTrue.db"), bad)
x = sqlite3.connect(bad); x.execute("update t set v='tampered' where id=1"); x.commit(); x.close()
ok, _ = dbfp.check_restored(bad, man); assert not ok, "restore gate must fail on a different logical hash"
print("ok: backup(live/stopped) == live logical hash; bytes changed", before[:8], "->", after[:8], "but logical hash did not")
PY
t "byte hashes are never the criterion" bash -c "! grep -nE 'sha256sum|file_sha|src_sha|cold-copy|hexdigest\(\) *==' '$HERE/lib/aetulla.sh'"

# 5. offline: unreachable check URL => exit 0 + message, nothing changed
t "offline exits 0 with message" bash -c "AETULLA_CHECK_URL=http://127.0.0.1:9 '$HERE/bin/aetulla' update | grep -q 'offline'"

# 6. Ollama advisory never calls anything that upgrades
t "no upgrade command is executed" bash -c "! grep -nE '^[^#]*(install\.sh *\| *sh|systemctl (restart|stop) ollama)' '$HERE/lib/aetulla.sh' | grep -v 'upgrade yourself'"

echo "passed=$pass failed=$failn"
[ "$failn" -eq 0 ]
# Manual proof of rollback (Phase 3):  HEALTH_FORCE_FAIL=open-webui bin/aetulla update
#   expect: exit != 0, webui.db sha256 equals its pre-update value, old images running.
