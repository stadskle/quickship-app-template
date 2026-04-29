"""
Postgres connection + Yoyo migration runner.

Same code path runs locally (against the docker-compose Postgres) and in
production (against Neon). The migration runner applies pending SQL files
from `backend/migrations/` on startup; if `DATABASE_URL` is unset (database
not enabled for this app), all functions are no-ops.
"""

from __future__ import annotations

import os
import re
from contextlib import contextmanager
from pathlib import Path

import psycopg
from yoyo import get_backend, read_migrations

DATABASE_URL = os.environ.get("DATABASE_URL")

# backend/app/lib/db.py → backend/migrations/
_MIGRATIONS_DIR = Path(__file__).resolve().parent.parent.parent / "migrations"


def _yoyo_url(url: str) -> str:
    """Translate a stdlib postgres URL into yoyo's psycopg-v3 form.

    yoyo's default driver for `postgresql://` is psycopg2; we install psycopg
    (v3) only. The `postgresql+psycopg://` scheme tells yoyo to use psycopg v3.
    psycopg.connect() itself only accepts plain `postgresql://`, so we keep
    the original DATABASE_URL for runtime queries and only rewrite for yoyo.
    """
    return re.sub(r"^postgres(ql)?://", "postgresql+psycopg://", url, count=1)


def apply_migrations() -> None:
    """Apply any pending migrations. Idempotent. No-op if no DATABASE_URL."""
    if not DATABASE_URL:
        return

    backend = get_backend(_yoyo_url(DATABASE_URL))
    migrations = read_migrations(str(_MIGRATIONS_DIR))
    with backend.lock():
        backend.apply_migrations(backend.to_apply(migrations))


def connection() -> psycopg.Connection:
    """Open a new psycopg connection. Caller is responsible for closing.

    Idiomatic usage (auto-closes, auto-commits or rolls back):

        with db.connection() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT now()")
                ts = cur.fetchone()[0]
    """
    if not DATABASE_URL:
        raise RuntimeError(
            "DATABASE_URL is not set. Set database_enabled = true in infra/terraform.tfvars "
            "(or add it to docker-compose.yml's backend env vars for local dev)."
        )
    return psycopg.connect(DATABASE_URL)


@contextmanager
def transaction():
    """Context manager for a transactional cursor.

    Commits on clean exit, rolls back on exception. Closes the connection
    afterwards. Use for any multi-statement unit of work.

        with db.transaction() as cur:
            cur.execute("INSERT INTO notes (...) VALUES (...)")
            cur.execute("UPDATE counters SET n = n + 1")
            cur.fetchone()  # if you need to read a RETURNING row
    """
    with connection() as conn:
        with conn.transaction(), conn.cursor() as cur:
            yield cur
