"""
Aurora DSQL connection helpers.

Same code path runs locally and in production — both talk to a real Aurora
DSQL cluster (there is no local DSQL emulator):

- Production (Lambda): `DSQL_ENDPOINT` env var is set by the platform.
  Auth uses the Lambda execution role.
- Local (`docker compose up`): `DSQL_ENDPOINT_PARAM` points at the SSM
  parameter holding this app's `-localdev` twin cluster endpoint. Auth uses
  your AWS profile (`AWS_PROFILE`, mounted from ~/.aws).

Auth is IAM-only: every connect generates a short-lived token via the
aurora-dsql-python-connector. No passwords, no connection strings.

If neither variable resolves to an endpoint (database not enabled for this
app), `enabled()` is False and `connection()` raises a clear error.

DSQL differences that matter in app code:
- Optimistic concurrency: conflicting writes fail at COMMIT with SQLSTATE
  40001 instead of waiting on a lock. Use `run_in_transaction(fn)`, which
  retries automatically, for any read-modify-write.
- A transaction may modify at most 3,000 rows. Batch bigger writes.
- DDL and DML can't share a transaction. Schema changes belong in
  migrations (see app/lib/migrate.py), never in app code.
"""

from __future__ import annotations

import functools
import os
import random
import time
from collections.abc import Callable
from contextlib import contextmanager
from typing import TypeVar

import aurora_dsql_psycopg as dsql
import psycopg

T = TypeVar("T")

DB_USER = "admin"
DB_NAME = "postgres"


@functools.cache
def endpoint() -> str | None:
    """Resolve this app's DSQL endpoint, or None if no database is enabled."""
    direct = os.environ.get("DSQL_ENDPOINT")
    if direct:
        return direct

    param = os.environ.get("DSQL_ENDPOINT_PARAM")
    if not param:
        return None

    import boto3

    ssm = boto3.client("ssm")
    try:
        return ssm.get_parameter(Name=param)["Parameter"]["Value"]
    except ssm.exceptions.ParameterNotFound:
        # database_enabled = false (or /initialize hasn't run yet).
        return None


def enabled() -> bool:
    return endpoint() is not None


def connection(*, autocommit: bool = False) -> psycopg.Connection:
    """Open a new IAM-authenticated connection. Caller closes it.

        with db.connection() as conn:
            with conn.cursor() as cur:
                cur.execute("SELECT now()")
                ts = cur.fetchone()[0]
    """
    host = endpoint()
    if not host:
        raise RuntimeError(
            "No database configured. Set database_enabled = true in infra/terraform.tfvars "
            "and run ./scripts/initialize.sh (that also creates the -localdev cluster "
            "docker compose uses)."
        )
    return dsql.connect(host=host, user=DB_USER, dbname=DB_NAME, autocommit=autocommit)


@contextmanager
def transaction():
    """Transactional cursor. Commits on clean exit, rolls back on exception.

    No automatic retry — if the body does a read-then-write that can race
    with another request, use `run_in_transaction` instead.

        with db.transaction() as cur:
            cur.execute("INSERT INTO notes (...) VALUES (...) RETURNING id")
            new_id = cur.fetchone()[0]
    """
    with connection() as conn:
        with conn.transaction(), conn.cursor() as cur:
            yield cur


def is_conflict(error: BaseException) -> bool:
    """True for DSQL optimistic-concurrency conflicts (safe to retry)."""
    return getattr(error, "sqlstate", None) in ("40001", "OC000", "OC001")


def run_in_transaction(fn: Callable[[psycopg.Cursor], T], *, attempts: int = 5) -> T:
    """Run `fn(cursor)` in a transaction, retrying on OCC conflicts.

    `fn` may be called more than once, so it must not have side effects
    outside the database (no emails, no S3 writes) — do those after this
    returns.

        def bump(cur):
            cur.execute("UPDATE counters SET n = n + 1 WHERE name = %s RETURNING n", ("hits",))
            return cur.fetchone()[0]

        n = db.run_in_transaction(bump)
    """
    for attempt in range(1, attempts + 1):
        try:
            with transaction() as cur:
                return fn(cur)
        except psycopg.Error as e:
            if not is_conflict(e) or attempt == attempts:
                raise
            time.sleep(min(0.01 * 2**attempt, 0.5) * (1 + random.random()))
    raise AssertionError("unreachable")


def apply_migrations() -> None:
    """Apply pending migrations. No-op if no database. See app/lib/migrate.py."""
    from app.lib import migrate

    migrate.apply()
