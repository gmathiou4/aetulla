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
import tarfile
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


def _size(p):
    if os.path.isdir(p):
        return sum(os.path.getsize(os.path.join(r, f)) for r, _, fs in os.walk(p) for f in fs)
    return os.path.getsize(p)


def backup_files_except(src, out_tgz, skip_prefix="database.sqlite"):
    """tar.gz of every top-level entry of `src` except the database files (those go through the sqlite
    backup API). For n8n this captures `config`, which holds the encryptionKey that decrypts every stored
    credential, so the archive is mode 600. Returns {top-level name: bytes}: names and sizes only, the
    CONTENT of these files is never read into the output."""
    sizes = {}
    with tarfile.open(out_tgz, "w:gz") as t:
        for name in sorted(os.listdir(src)):
            if name.startswith(skip_prefix):
                continue
            t.add(os.path.join(src, name), arcname=name)
            sizes[name] = _size(os.path.join(src, name))
    os.chmod(out_tgz, 0o600)
    return sizes


def _keep_mode(member, path):
    """tarfile's own 'tar' filter (rejects absolute paths, '..' and links that escape), then the ORIGINAL
    mode back: that filter clears setuid/setgid/sticky, and a restore should be exact (n8n's dirs are 2755)."""
    return tarfile.tar_filter(member, path).replace(mode=member.mode)


def restore_files(tgz, dst):
    """Put the archived entries back: existing ones are moved aside first and dropped only after a
    successful extract (a failed restore leaves *.aside behind, never a half-state with the originals gone).
    Owner and mode are kept exactly: the n8n user is not root, and a root-owned mode-600 config would
    lock n8n out of its own key. Returns the restored top-level names."""
    with tarfile.open(tgz) as t:
        tops = sorted({m.name.split("/")[0] for m in t.getmembers()})
        for top in tops:
            p = os.path.join(dst, top)
            if os.path.lexists(p):
                os.rename(p, p + ".aside")
        t.extractall(dst, filter=_keep_mode)
    for top in tops:
        a = os.path.join(dst, top) + ".aside"
        if os.path.isdir(a) and not os.path.islink(a):
            shutil.rmtree(a)
        elif os.path.lexists(a):
            os.remove(a)
    return tops


# Tables whose rows are the user's own data. A loss there after an upgrade is a real problem.
# Everything else (execution history is pruned by n8n on purpose, internal/feature tables get added,
# renamed or dropped by migrations) is only REPORTED.
N8N_USER_TABLES = ("workflow_entity", "credentials_entity", "user", "project", "project_relation",
                   "shared_workflow", "shared_credentials", "workflow_history", "tag_entity",
                   "workflows_tags", "folder", "variables")


def check_user_tables(before, after, protected=N8N_USER_TABLES):
    """Compare per-table row counts from before/after an upgrade. Returns (problems, notes).
    problems (fail): a protected table is missing or has fewer rows than before.
    notes (info only): any other table that lost rows or vanished WITH data. A table that vanished with 0 rows
    is ignored: migrations legitimately drop/rename empty tables, and a missing table must not read as -1 rows."""
    problems, notes = [], []
    for t, n in sorted(before.items()):
        have = after.get(t)
        if t in protected:
            if have is None or have < n:
                problems.append(f"{t}: {n} -> {'MISSING' if have is None else have}")
        elif have is None:
            if n > 0:
                notes.append(f"{t}: dropped/renamed with {n} rows")
        elif have < n:
            notes.append(f"{t}: {n} -> {have}")
    return problems, notes


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
