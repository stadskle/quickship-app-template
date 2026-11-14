---
description: Create a new Aurora DSQL SQL migration in backend/migrations/
---

Create a new SQL migration in `backend/migrations/` for: $ARGUMENTS

Steps:
1. List existing files in `backend/migrations/` to find the next sequence number (skip `.gitkeep`).
2. Compose filenames `NNNN_<slug>.sql` and `NNNN_<slug>.rollback.sql`, where `NNNN` is zero-padded 4-digit and `<slug>` is the description from $ARGUMENTS in snake_case.
3. Write the forward file with the SQL the user wants, following CLAUDE.md "DSQL SQL rules". If the description is high-level (e.g., "users table"), draft sensible SQL — `CREATE TABLE` with `id UUID PRIMARY KEY DEFAULT gen_random_uuid()`, `created_at TIMESTAMPTZ NOT NULL DEFAULT now()`, the obvious columns, and `CREATE INDEX ASYNC` on commonly-queried columns. In particular:
   - never `SERIAL`; never plain `CREATE INDEX` (always `ASYNC`); no `ASC`/`DESC` in index columns;
   - no `SET NOT NULL` / `ALTER COLUMN ... TYPE` / defaults on `ADD COLUMN` — use the recipes in CLAUDE.md "Safe migration recipes";
   - any `UPDATE`/`DELETE` that may touch more than a few hundred rows gets a `-- quickship:batch` line above it and a `LIMIT`ed subquery that only matches rows still needing work.
   - `IF NOT EXISTS` is unnecessary — the runner tracks applied migrations.
4. Write the rollback file: SQL that undoes the forward file, or a comment-only `-- IRREVERSIBLE: <why>` if it can't be undone.
5. Show both paths and contents to the user. Tell them: locally the migration applies on backend startup — `docker compose restart backend` (check with `docker compose exec backend python -m app.lib.migrate status`); in production the pipeline applies it on the next push, before the new code goes live.

Don't apply the migration yourself; the runtime does that.
