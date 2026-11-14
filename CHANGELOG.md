# Changelog

## v2.0.0 — Aurora DSQL replaces Neon (BREAKING)

Requires the platform at **v2.0.0** (see the platform repo's CHANGELOG for the full upgrade procedure — existing apps must be pinned to `?ref=v1.0.0` first).

- `app.lib.db` connects to Aurora DSQL with IAM auth (`aurora-dsql-python-connector`). New `db.run_in_transaction(fn)` retries optimistic-concurrency conflicts; `db.enabled()` reports whether the app has a database.
- Yoyo is replaced by `app.lib.migrate` (`python -m app.lib.migrate [apply|status|rollback]`): one statement per transaction, resumable after partial failure, waits for async index jobs, `-- quickship:batch` for >3,000-row backfills.
- Migrations run in the pipeline (buildspec `post_build`) before the Lambda update — no longer on cold start. Locally they run on backend startup.
- docker-compose no longer runs Postgres; the backend uses the app's `-localdev` DSQL cluster via `DSQL_ENDPOINT_PARAM` and your AWS profile.
- `infra/`: Neon provider removed.
- CLAUDE.md / `/migrate` / `/local` / `quickship-reviewer`: DSQL SQL rules and rewritten safe-migration recipes (no `SERIAL`, `CREATE INDEX ASYNC`, `CHECK ... NOT VALID` instead of `SET NOT NULL`, batched backfills).
