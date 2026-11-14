"""
SQL migration runner for Aurora DSQL.

    python -m app.lib.migrate              # apply pending (same as `apply`)
    python -m app.lib.migrate status       # list applied / pending
    python -m app.lib.migrate rollback     # undo the latest migration (local dev only)

Where it runs:
- Pipeline: buildspec.yml runs `apply` against the prod cluster AFTER the
  orchestrator's terraform apply and BEFORE the new Lambda code goes live.
  A failing migration fails the build, so broken code never ships on top
  of a half-migrated schema. Lambda never runs migrations.
- Local: the backend container runs `apply` on startup against the
  `-localdev` twin cluster (QUICKSHIP_MIGRATE_ON_STARTUP=1).

Files live in backend/migrations/: `NNNN_desc.sql` (forward) and a sibling
`NNNN_desc.rollback.sql`. Plain SQL, statements separated by `;`.

Why not Yoyo / Alembic: DSQL allows only ONE DDL statement per transaction
and forbids mixing DDL with DML, so tools that wrap a migration (plus their
bookkeeping insert) in one transaction fail. This runner executes every
statement in its own autocommit transaction and records progress after
each one — if statement 3 of 5 fails, fix it and re-run; statements 1-2
are not re-executed.

Statement-level features:
- `CREATE INDEX ASYNC` / `ALTER TABLE ASYNC ... VALIDATE CONSTRAINT` return
  a job id; the runner waits for the job (sys.wait_for_job) so the next
  statement — and the new app code — can rely on it.
- A statement preceded by a `-- quickship:batch` comment is re-run until it
  affects 0 rows. Use it for backfills, because a DSQL transaction can
  modify at most 3,000 rows:

      -- quickship:batch
      UPDATE notes SET priority = 'normal'
      WHERE id IN (SELECT id FROM notes WHERE priority IS NULL LIMIT 1000);
"""

from __future__ import annotations

import hashlib
import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path

import sqlparse

from app.lib import db

# backend/app/lib/migrate.py → backend/migrations/ (also build/migrations/ in the pipeline)
MIGRATIONS_DIR = Path(__file__).resolve().parent.parent.parent / "migrations"
TABLE = "_quickship_migrations"
BATCH_MARKER = re.compile(r"--\s*quickship:batch\b", re.IGNORECASE)
FORWARD_FILE = re.compile(r"^(\d{4,}_[A-Za-z0-9_\-]+)\.sql$")


@dataclass
class Migration:
    id: str
    forward: Path
    rollback: Path | None

    def statements(self, path: Path | None = None) -> list[str]:
        return split_sql((path or self.forward).read_text())

    @property
    def checksum(self) -> str:
        return hashlib.sha256(self.forward.read_bytes()).hexdigest()


def split_sql(text: str) -> list[str]:
    """Split a file into executable statements, dropping comment-only chunks.

    Comments are kept on real statements (so `-- quickship:batch` survives).
    """
    out = []
    for raw in sqlparse.split(text):
        body = sqlparse.format(raw, strip_comments=True).strip().rstrip(";").strip()
        if body:
            out.append(raw.strip().rstrip(";").strip())
    return out


def discover() -> list[Migration]:
    if not MIGRATIONS_DIR.is_dir():
        return []
    found = []
    for path in sorted(MIGRATIONS_DIR.iterdir()):
        m = FORWARD_FILE.match(path.name)
        if not m or path.name.endswith(".rollback.sql"):
            continue
        rb = path.with_name(f"{m.group(1)}.rollback.sql")
        found.append(Migration(m.group(1), path, rb if rb.exists() else None))
    return found


def _ensure_table(cur) -> None:
    cur.execute(
        f"""CREATE TABLE IF NOT EXISTS {TABLE} (
            id                 TEXT PRIMARY KEY,
            checksum           TEXT NOT NULL,
            statements_applied INTEGER NOT NULL,
            completed_at       TIMESTAMPTZ
        )"""
    )


def _progress(cur) -> dict[str, tuple[str, int, object]]:
    cur.execute(f"SELECT id, checksum, statements_applied, completed_at FROM {TABLE}")
    return {r[0]: (r[1], r[2], r[3]) for r in cur.fetchall()}


def _execute(cur, stmt: str) -> None:
    """Run one statement in its own (autocommit) transaction."""
    if BATCH_MARKER.search(stmt):
        total = 0
        while True:
            cur.execute(stmt)
            if cur.rowcount <= 0:
                break
            total += cur.rowcount
        print(f"    batched: {total} rows", flush=True)
        return

    cur.execute(stmt)
    # Async DDL returns a job id — wait so later statements can rely on it.
    if cur.description and cur.description[0].name == "job_id":
        job_id = cur.fetchone()[0]
        print(f"    waiting for async job {job_id}", flush=True)
        cur.execute("SELECT sys.wait_for_job(%s)", (job_id,))
        ok = cur.fetchone()[0]
        if ok is False:
            raise RuntimeError(f"async DDL job {job_id} failed — see `SELECT * FROM sys.jobs`")


def _record(cur, mig: Migration, applied: int, done: bool) -> None:
    cur.execute(
        f"""INSERT INTO {TABLE} (id, checksum, statements_applied, completed_at)
            VALUES (%s, %s, %s, CASE WHEN %s THEN now() END)
            ON CONFLICT (id) DO UPDATE SET
              checksum = EXCLUDED.checksum,
              statements_applied = EXCLUDED.statements_applied,
              completed_at = EXCLUDED.completed_at""",
        (mig.id, mig.checksum, applied, done),
    )


def apply() -> None:
    """Apply all pending migrations. No-op if the app has no database."""
    migrations = discover()
    if not db.enabled():
        if migrations:
            print("migrate: no database configured — skipping", flush=True)
        return

    with db.connection(autocommit=True) as conn, conn.cursor() as cur:
        _ensure_table(cur)
        progress = _progress(cur)
        pending = 0
        for mig in migrations:
            checksum, applied, completed = progress.get(mig.id, (None, 0, None))
            if completed:
                if checksum != mig.checksum:
                    print(
                        f"migrate: WARNING {mig.forward.name} changed after it was applied — "
                        "edits to applied migrations are ignored; write a new migration.",
                        flush=True,
                    )
                continue
            pending += 1
            stmts = mig.statements()
            print(f"migrate: applying {mig.forward.name} ({len(stmts)} statements)", flush=True)
            for i, stmt in enumerate(stmts):
                if i < applied:
                    continue  # already ran in an earlier, partially-failed attempt
                _execute(cur, stmt)
                _record(cur, mig, i + 1, done=False)
            _record(cur, mig, len(stmts), done=True)
        print(f"migrate: {pending} applied, schema up to date", flush=True)


def rollback(*, allow_prod: bool = False) -> None:
    """Undo the latest completed migration using its .rollback.sql sibling."""
    if os.environ.get("DSQL_ENDPOINT") and not allow_prod:
        sys.exit(
            "Refusing to roll back: DSQL_ENDPOINT is set, so this looks like PRODUCTION. "
            "Production policy is roll-forward (write a new migration). "
            "Pass --i-know-this-is-production to override."
        )
    with db.connection(autocommit=True) as conn, conn.cursor() as cur:
        _ensure_table(cur)
        cur.execute(f"SELECT id FROM {TABLE} WHERE completed_at IS NOT NULL ORDER BY id DESC LIMIT 1")
        row = cur.fetchone()
        if not row:
            print("rollback: nothing to roll back")
            return
        mig = next((m for m in discover() if m.id == row[0]), None)
        if mig is None or mig.rollback is None:
            sys.exit(f"rollback: no {row[0]}.rollback.sql found")
        stmts = mig.statements(mig.rollback)
        print(f"rollback: {mig.rollback.name} ({len(stmts)} statements)")
        for stmt in stmts:
            _execute(cur, stmt)
        cur.execute(f"DELETE FROM {TABLE} WHERE id = %s", (mig.id,))


def status() -> None:
    with db.connection(autocommit=True) as conn, conn.cursor() as cur:
        _ensure_table(cur)
        progress = _progress(cur)
    for mig in discover():
        _, applied, completed = progress.get(mig.id, (None, 0, None))
        state = f"applied {completed:%Y-%m-%d %H:%M}" if completed else (
            f"PARTIAL ({applied} statements done)" if applied else "pending"
        )
        print(f"{mig.id:40} {state}")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "apply"
    if cmd == "apply":
        apply()
    elif cmd == "status":
        status()
    elif cmd == "rollback":
        rollback(allow_prod="--i-know-this-is-production" in sys.argv)
    else:
        sys.exit(f"usage: python -m app.lib.migrate [apply|status|rollback]")
