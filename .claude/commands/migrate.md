---
description: Create a new Yoyo SQL migration in backend/migrations/
---

Create a new SQL migration file in `backend/migrations/` for: $ARGUMENTS

Steps:
1. List existing files in `backend/migrations/` to find the next sequence number (skip `.gitkeep`).
2. Compose a filename `NNNN_<slug>.sql` where `NNNN` is zero-padded 4-digit and `<slug>` is the description from $ARGUMENTS in snake_case.
3. Write the file with the SQL the user wants. If the description is high-level (e.g., "users table"), draft sensible SQL — `CREATE TABLE` with `id UUID PRIMARY KEY DEFAULT gen_random_uuid()`, `created_at TIMESTAMPTZ DEFAULT now()`, the obvious columns, and `CREATE INDEX` on commonly-queried columns. Use `IF NOT EXISTS` only if specifically asked to make it idempotent — Yoyo tracks applied migrations, so `IF NOT EXISTS` is usually unnecessary.
4. Show the file path and contents back to the user. Tell them: migrations apply automatically on backend container startup; restart the backend (`docker compose restart backend`) to apply, or `docker compose down && docker compose up` if they want to start clean.

Don't apply the migration yourself; the runtime does that.