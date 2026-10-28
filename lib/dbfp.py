"""SQLite helpers for bin/aetulla: backup, logical fingerprint, verification gates.

Why logical, not byte hashes: a WAL-mode database's bytes change whenever SQLite folds the
-wal into the main file (a clean start does it), without any data change. So the criterion
is the sha256 of iterdump() output, never of file bytes. Fingerprints are always taken from
a private temp copy (main + -wal + -shm), so the original is never opened for writing.
Nothing here prints row data: only hashes, table row counts, versions and verdicts.
"""
import hashlib
import os
import shutil
import sqlite3
import tempfile


def _copy_set(src, dstdir, name="db"):
    for sfx in ("", "-wal", "-shm"):
        if os.path.exists(src + sfx):
            shutil.copy2(src + sfx, os.path.join(dstdir, name + sfx))
    return os.path.join(dstdir, name)


def _version(c):
    """Schema version: Open WebUI/Alembic, else n8n/TypeORM migrations, else n/a."""
    for q in ("select version_num from alembic_version",
              "select name from migrations order by id desc limit 1"):
        try:
            r = c.execute(q).fetchone()
            if r:
                return str(r[0])
        except sqlite3.Error:
            pass
    return "n/a"


def fingerprint(path):
    """{logical, integrity, version, tables{name: rows}} of main+WAL at `path`."""
    tmp = tempfile.mkdtemp()
    try:
        c = sqlite3.connect(_copy_set(path, tmp))
        h = hashlib.sha256()
        for line in c.iterdump():
            h.update(line.encode() + b"\n")
        names = [t for (t,) in c.execute(
            "select name from sqlite_master where type='table' and name not like 'sqlite_%'").fetchall()]
        out = {
            "logical": h.hexdigest(),
            "integrity": c.execute("pragma integrity_check").fetchone()[0],
            "version": _version(c),
            "tables": {t: c.execute(f'select count(*) from "{t}"').fetchone()[0] for t in names},
        }
        c.close()
        return out
    finally:
        shutil.rmtree(tmp)


def backup_db(src, dst, live):
    """Always the sqlite3 backup API, one self-contained file (no -wal/-shm, journal=delete).
    live=True: the service is running, back up through its live file (consistent online backup).
    live=False: service stopped; back up from a private copy so the volume is never touched."""
    tmp = None
    if not live:
        tmp = tempfile.mkdtemp()
        src = _copy_set(src, tmp)
    s = sqlite3.connect(src)
    d = sqlite3.connect(dst)
    try:
        s.backup(d)
        d.execute("pragma journal_mode=delete")      # the copy keeps the source's WAL flag otherwise
        d.commit()
    finally:
        d.close()
        s.close()
        if tmp:
            shutil.rmtree(tmp)
    for sfx in ("-wal", "-shm"):
        if os.path.exists(dst + sfx):
            os.remove(dst + sfx)


def check_restored(path, manifest_entry):
    """Hard gate, after restore and BEFORE the service starts: logical hash == manifest."""
    fp = fingerprint(path)
    ok = fp["logical"] == manifest_entry["logical"] and fp["integrity"] == "ok"
    return ok, fp


def check_after_healthy(path, manifest_entry):
    """Hard gate once the service is healthy: integrity ok, same schema version, no table with
    fewer rows than the backup. The logical hash is informational only (services write on boot).
    Returns (problems[list of str], changed_since_restore[bool], fingerprint)."""
    fp = fingerprint(path)
    problems = []
    if fp["integrity"] != "ok":
        problems.append(f"integrity_check: {fp['integrity']}")
    if fp["version"] != manifest_entry["version"]:
        problems.append(f"schema version {fp['version']} != backup {manifest_entry['version']}")
    for t, n in manifest_entry["tables"].items():
        have = fp["tables"].get(t)
        if have is None or have < n:
            problems.append(f"table {t}: {have} rows < backup {n}")
    return problems, fp["logical"] != manifest_entry["logical"], fp
