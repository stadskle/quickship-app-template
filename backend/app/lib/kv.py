"""
Key-value store helper.

Production: DynamoDB. Each logical table maps to a real DynamoDB table
named `KV_TABLE_<NAME>` in env (set by the platform module from
`dynamodb_tables`). Hash key is `key` (string); attributes are `value`
(any JSON-serialisable map) and optional `ttl` (UNIX epoch seconds).

Local dev (no `KV_TABLE_*` env vars): single SQLite database at
`./local.db`, one row per logical-table+key pair. TTL is enforced
in-process on read.

API is the same in both modes:

    kv.put("sessions", "user-123", {"foo": 1}, ttl=3600)
    kv.get("sessions", "user-123")  # → {"foo": 1}, or None if missing/expired
    kv.delete("sessions", "user-123")
"""

from __future__ import annotations

import json
import os
import sqlite3
import time
from pathlib import Path
from typing import Any

_DYNAMO_MODE = any(k.startswith("KV_TABLE_") for k in os.environ)
_LOCAL_DB_PATH = Path("./local.db")


# ---------- DynamoDB backend ------------------------------------------------


class _DynamoBackend:
    def __init__(self):
        import boto3

        self._db = boto3.resource("dynamodb")

    def _table(self, logical_name: str):
        env_var = f"KV_TABLE_{logical_name.upper().replace('-', '_')}"
        full_name = os.environ.get(env_var)
        if not full_name:
            raise KeyError(
                f"DynamoDB table {logical_name!r} not configured "
                f"(env var {env_var} is missing). "
                f"Add {logical_name!r} to dynamodb_tables in infra/terraform.tfvars."
            )
        return self._db.Table(full_name)

    def get(self, table: str, key: str) -> dict[str, Any] | None:
        item = self._table(table).get_item(Key={"key": key}).get("Item")
        if not item:
            return None
        ttl = item.get("ttl")
        if ttl is not None and int(ttl) < int(time.time()):
            return None  # expired (DynamoDB TTL also reaps within ~48h)
        return item.get("value")

    def put(
        self, table: str, key: str, value: dict[str, Any], ttl_seconds: int | None
    ) -> None:
        item: dict[str, Any] = {"key": key, "value": value}
        if ttl_seconds is not None:
            item["ttl"] = int(time.time()) + ttl_seconds
        self._table(table).put_item(Item=item)

    def delete(self, table: str, key: str) -> None:
        self._table(table).delete_item(Key={"key": key})


# ---------- SQLite backend (local dev) --------------------------------------


class _SqliteBackend:
    def __init__(self):
        self._conn = sqlite3.connect(_LOCAL_DB_PATH, check_same_thread=False)
        self._conn.execute(
            """
            CREATE TABLE IF NOT EXISTS kv (
                table_name TEXT NOT NULL,
                key        TEXT NOT NULL,
                value      TEXT NOT NULL,
                ttl        INTEGER,
                PRIMARY KEY (table_name, key)
            )
            """
        )
        self._conn.commit()

    def get(self, table: str, key: str) -> dict[str, Any] | None:
        cur = self._conn.execute(
            "SELECT value, ttl FROM kv WHERE table_name = ? AND key = ?",
            (table, key),
        )
        row = cur.fetchone()
        if not row:
            return None
        value_json, ttl = row
        if ttl is not None and ttl < int(time.time()):
            self.delete(table, key)
            return None
        return json.loads(value_json)

    def put(
        self, table: str, key: str, value: dict[str, Any], ttl_seconds: int | None
    ) -> None:
        ttl_ts = int(time.time()) + ttl_seconds if ttl_seconds is not None else None
        self._conn.execute(
            "INSERT OR REPLACE INTO kv (table_name, key, value, ttl) VALUES (?, ?, ?, ?)",
            (table, key, json.dumps(value), ttl_ts),
        )
        self._conn.commit()

    def delete(self, table: str, key: str) -> None:
        self._conn.execute(
            "DELETE FROM kv WHERE table_name = ? AND key = ?",
            (table, key),
        )
        self._conn.commit()


_backend = _DynamoBackend() if _DYNAMO_MODE else _SqliteBackend()


# ---------- Public API ------------------------------------------------------


def get(table: str, key: str) -> dict[str, Any] | None:
    """Return the value at (table, key), or None if missing or expired."""
    return _backend.get(table, key)


def put(
    table: str,
    key: str,
    value: dict[str, Any],
    ttl_seconds: int | None = None,
) -> None:
    """Set the value at (table, key). Optional TTL in seconds from now."""
    _backend.put(table, key, value, ttl_seconds)


def delete(table: str, key: str) -> None:
    """Remove the row at (table, key). No error if missing."""
    _backend.delete(table, key)
