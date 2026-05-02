# Claude Code working notes — __APP_NAME__

This repo is a [quickship](https://github.com/your-org/quickship-platform) app. The platform standardises infrastructure, auth, and helpers so your job is to focus on the actual feature code. Stick to the conventions below — deviating breaks deploys or, worse, breaks security guarantees.

## Stack

- **Backend**: Python 3.12, FastAPI, Mangum (Lambda adapter)
- **Database**: Postgres (Neon in prod, docker-compose locally), Yoyo for migrations
- **Frontend** (later phase): Vite + React + Tailwind
- **Deploy**: AWS Lambda (Function URL), CloudFront, Cloudflare Access
- **Local dev**: `docker compose up` brings everything up

## Auth model

Cloudflare Access authenticates the user before any request reaches the app. The platform's chain-of-trust (Cloudflare → CloudFront WAF → OAC SigV4 → Lambda IAM) makes the auth header `Cf-Access-Authenticated-User-Email` trustworthy.

**The app code reads this header. Period.** No JWT validation, no JWKS, no PyJWT. The helper at `backend/app/lib/auth.py` exposes a FastAPI `Depends(current_user)` that:

- In production (header present): returns `{"email": "<user>"}`.
- Locally (header missing because Cloudflare isn't in the path): returns `{"email": "dev@local"}` as a fixture.

> ⚠ The local auth fixture trusts whatever `Cf-Access-Authenticated-User-Email` header it sees, falling back to `dev@local` if absent. That's safe on a single-developer laptop where docker-compose is reachable only from `localhost`. **Don't expose port 8000 publicly** (no `ngrok`, no router port-forward, no `--host 0.0.0.0` outside the container) — anyone reaching it could spoof any email by setting that header. For "let a teammate try my local app", use `./scripts/initialize.sh` instead and Cloudflare Access will gate it properly.

**Email is the identity.** It's stable across sessions, so use it directly as the foreign key on user-owned rows. Don't invent a `user_id` table or UUID — the email *is* the user ID.

Idiomatic per-user route:

```python
from fastapi import Depends
from app.lib.auth import current_user, User
from app.lib import db

@app.get("/api/notes")
def list_notes(user: User = Depends(current_user)):
    with db.connection() as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT id, body FROM notes WHERE owner_email = %s ORDER BY id DESC",
            (user["email"],),
        )
        return [{"id": r[0], "body": r[1]} for r in cur.fetchall()]

@app.post("/api/notes")
def create_note(body: str, user: User = Depends(current_user)):
    with db.transaction() as cur:
        cur.execute(
            "INSERT INTO notes (owner_email, body) VALUES (%s, %s) RETURNING id",
            (user["email"], body),
        )
        return {"id": cur.fetchone()[0]}
```

The matching migration would be `CREATE TABLE notes (id SERIAL PRIMARY KEY, owner_email TEXT NOT NULL, body TEXT NOT NULL);` plus an index on `owner_email`.

Health endpoints can omit the dep.

**No groups / roles yet.** The platform doesn't currently inject role info into requests. If you need admin-only routes, hardcode against email until the platform grows a role mechanism (don't roll your own).

## Database conventions

- **Migrations**: drop SQL files in `backend/migrations/`, named `NNNN_description.sql` (e.g., `0001_initial.sql`, `0002_notes_table.sql`). Yoyo runs them on Lambda cold start; locally they run on backend container startup.
- **Never `CREATE TABLE` from app code.** Always migrations.
- **Schema is yours**: relational, JSONB, hybrid — pick what fits the feature.
- **Forward + rollback are SIBLING files.** Yoyo 9's convention: `0007_add_priority.sql` for the forward migration, `0007_add_priority.rollback.sql` for the rollback. Both are plain SQL — no `-- migrate:` / `-- rollback:` markers (yoyo 9 does not parse those; if you put them inside one file, the "rollback" SQL runs as part of the forward apply). The `quickship-reviewer` agent enforces both files exist. If a migration is genuinely irreversible (e.g., `DROP COLUMN` loses data forever), the rollback file contains only a comment explaining why — explicit irreversibility is the rule.

## Safe migration recipes

Migrations run automatically on the next Lambda cold start in production. There is no manual gate, no preview environment, no "are you sure?" prompt. Once a migration is in `main` and `git push`-ed, the next request to your app applies it. **Treat schema changes with the same care as a `terraform apply` against a database.**

The `quickship-reviewer` agent flags destructive SQL and asks for explicit acknowledgement; these recipes are how to do destructive things safely.

> **Format reminder.** Each migration is **two files** in `backend/migrations/`:
> - `NNNN_<desc>.sql` — forward migration (plain SQL)
> - `NNNN_<desc>.rollback.sql` — rollback (plain SQL, or comment-only if irreversible)
>
> Don't put `-- migrate:` / `-- rollback:` markers inside one file — yoyo 9 doesn't parse those and the "rollback" SQL runs during apply.

### Adding a column

**Nullable column** — safe in one migration:

`0007_add_priority.sql`:
```sql
ALTER TABLE notes ADD COLUMN priority TEXT;
```

`0007_add_priority.rollback.sql`:
```sql
ALTER TABLE notes DROP COLUMN priority;
```

**NOT NULL column** — must be done in three migrations (expand-contract):

`0007_add_priority.sql`:
```sql
ALTER TABLE notes ADD COLUMN priority TEXT;
```
`0007_add_priority.rollback.sql`:
```sql
ALTER TABLE notes DROP COLUMN priority;
```

`0008_backfill_priority.sql`:
```sql
UPDATE notes SET priority = 'normal' WHERE priority IS NULL;
```
`0008_backfill_priority.rollback.sql`:
```sql
-- intentionally empty: undoing a backfill is a no-op data-wise.
```

`0009_priority_required.sql`:
```sql
ALTER TABLE notes ALTER COLUMN priority SET DEFAULT 'normal';
ALTER TABLE notes ALTER COLUMN priority SET NOT NULL;
```
`0009_priority_required.rollback.sql`:
```sql
ALTER TABLE notes ALTER COLUMN priority DROP NOT NULL;
ALTER TABLE notes ALTER COLUMN priority DROP DEFAULT;
```

This sequence guarantees no row ever fails the constraint mid-deploy.

### Renaming a column

Three deploys, never just one. The middle deploy keeps both columns visible.

`00NN_add_new_name.sql`:
```sql
ALTER TABLE notes ADD COLUMN body_v2 TEXT;
UPDATE notes SET body_v2 = body;
```
`00NN_add_new_name.rollback.sql`:
```sql
ALTER TABLE notes DROP COLUMN body_v2;
```

Then ship app code that reads `body_v2` and writes to BOTH `body` and `body_v2`. Then:

`00NN+1_drop_old_name.sql`:
```sql
ALTER TABLE notes DROP COLUMN body;
```
`00NN+1_drop_old_name.rollback.sql`:
```sql
-- IRREVERSIBLE: data in 'body' is gone after this. Restore from a Neon backup if needed.
```

Then ship app code that reads/writes only `body_v2`. The interim deploy is what makes the rename safe — without it, you have a window where the new code is reading a column that doesn't exist yet (or the old code is writing to a column that no longer exists).

### Dropping a column

Same expand-contract: stop using it in app code first, ship that, then drop.

`00NN_drop_legacy_field.sql`:
```sql
ALTER TABLE notes DROP COLUMN legacy_status;
```
`00NN_drop_legacy_field.rollback.sql`:
```sql
-- IRREVERSIBLE: data in 'legacy_status' is gone. The column was already
-- unused by app code as of deploy <YYYY-MM-DD>; the data was confirmed
-- non-essential before this migration shipped.
```

The comment in the rollback file is the audit trail — explicit acknowledgement that the data loss was intentional.

### Changing a column type

Don't `ALTER COLUMN ... TYPE` directly unless the conversion is trivial and tested. Safer:

`00NN_add_new_typed_column.sql`:
```sql
ALTER TABLE notes ADD COLUMN priority_int INTEGER;
UPDATE notes SET priority_int = CASE priority
  WHEN 'low' THEN 1
  WHEN 'normal' THEN 2
  WHEN 'high' THEN 3
END;
```
`00NN_add_new_typed_column.rollback.sql`:
```sql
ALTER TABLE notes DROP COLUMN priority_int;
```

Then app code transitions to read/write the new column, then drop the old.

### Production rollback policy

**Default: roll forward.** If a migration shipped a bad change, write a NEW migration that fixes it. Don't try to `yoyo rollback` against production — by the time you'd run it, app code has already written rows that the rollback can't reason about. Rollback in production is a last-resort manual operation, not a routine part of recovery.

The `.rollback.sql` sibling file's value is:
1. Local-dev testability (you can `yoyo rollback` to wipe a migration during iteration).
2. Forcing the author to think "is this reversible?" — half of bad migrations are caught by failing to write a sensible rollback.

### Capability disable = data loss

`database_enabled: true → false` in `infra/terraform.tfvars` means `terraform destroy` on the Neon role and database. **All data gone.** Same for `storage_enabled: true → false` (S3 bucket + objects) and removing entries from `dynamodb_tables` (table + rows).

If you mean "I don't want to use this capability anymore but keep the data": don't disable the flag. Just stop calling the helper from app code. The capability stays provisioned, costs nothing meaningful, and the data is preserved.

If you genuinely want to delete data: disable the flag, but understand it's irreversible. The `quickship-reviewer` agent will block `./scripts/initialize.sh` until you acknowledge.

## Helper imports — use these, not raw boto3

| Capability | Helper | Typical use |
|---|---|---|
| Auth | `app.lib.auth.current_user` | `user: User = Depends(current_user)` on protected routes |
| DB | `app.lib.db.connection()` / `db.transaction()` | psycopg context manager for Postgres |
| Storage (S3) | `app.lib.storage` | `storage.upload(key, bytes)`, `storage.presigned_url(key)` |
| KV (DynamoDB) | `app.lib.kv` | `kv.put("sessions", key, value, ttl_seconds=3600)`, `kv.get(...)` |
| Email (SES) | `app.lib.email` | `email.send(to=..., subject=..., body_text=...)` |
| AI (Bedrock) | `app.lib.ai` | `ai.generate(prompt)` for one-shot, `ai.chat(messages)` for multi-turn |
| AI (Claude / Anthropic API) | `app.lib.ai_claude` | Same shape as `ai.py`. Direct Anthropic API instead of Bedrock — see "Choosing an AI provider" below |
| Secrets | `app.lib.secrets` | `secrets.get("stripe_api_key")` — see "Adding a secret" below |

Every helper has a localhost fallback or a real-AWS-against-a-localdev-twin so the same code path runs in dev and prod:
- DB → docker-compose Postgres (separate from prod's Neon)
- Storage → real S3 against a per-app `*-localdev` bucket (free; provisioned alongside prod by the `quickship` module). Falls back to `./uploads/` on host disk if `STORAGE_BUCKET` env var isn't set (greenfield, before `/initialize`).
- KV → real DynamoDB against per-app `*-localdev` tables (free; provisioned alongside prod). Falls back to SQLite at `./local.db` if `KV_TABLE_*` env vars aren't set.
- Email → printed to stderr (you don't want local dev to send real email).
- AI → real AWS Bedrock with your dev credentials (no local mock; Nova Lite is cheap).

**Why localdev-twin for S3 + DynamoDB but not Postgres?** Empty DynamoDB tables and S3 buckets cost $0; Neon doesn't have a free-twin model. The DynamoDB/S3 twins give you real semantics (TTL, conditional writes, presigned URLs) without paying or risking prod data.

If you find yourself writing `import boto3` in a route file, **stop and check whether a helper exists**. The helpers handle local-dev fallbacks, IAM scoping, and platform conventions. Bypassing them creates dev/prod drift.

## Choosing an AI provider

Two helpers ship with the template, both with the same `generate(prompt)` / `chat(messages)` shape:

| | `app.lib.ai` (Bedrock) | `app.lib.ai_claude` (Anthropic API) |
|---|---|---|
| **Best for** | "Stay all-in-AWS, billing in one place, data inside the AWS region" | "Just give me Claude Sonnet/Opus quickly, friction-free" |
| **Setup friction** | Model access (Bedrock console) + Service Quotas (cross-region inference profile defaults at 0 in some regions; can require a support case) | Drop an API key in SSM and go |
| **Available models** | Whatever's published in your platform region (often a narrow set; eu-central-1 doesn't have Anthropic models on Bedrock as of 2026) | Full Claude family (Haiku / Sonnet / Opus) |
| **Data residency** | Bound to AWS region | Anthropic API endpoint (US/global) |
| **Billing** | AWS | Anthropic |
| **Default model** | `eu.amazon.nova-lite-v1:0` (regional inference profile) | `claude-sonnet-4-6` |

Default to **`ai_claude`** unless the user has stated a constraint that forces Bedrock (in-region data residency, single-AWS-bill mandate). It avoids the entire Bedrock-quota theatre and gives access to Claude models that aren't in the platform region.

### Using `ai_claude`

When `ai_models_enabled = true` is set in `infra/terraform.tfvars`, the platform automatically provisions an SSM SecureString placeholder at `/<prefix>/apps/<app>/anthropic_api_key` and injects it into the Lambda env as `ANTHROPIC_API_KEY`. Initial value is `"REPLACE_ME"`; the helper raises a clear error if used in that state.

Set the real key once, then redeploy:

```bash
aws --profile __AWS_PROFILE__ ssm put-parameter \
  --name /__AWS_PROFILE__/apps/__APP_NAME__/anthropic_api_key \
  --value 'sk-ant-...' \
  --type SecureString --overwrite \
  --region __AWS_REGION__

git push  # picks up the new env value (the platform's `data.aws_ssm_parameter` re-reads on apply)
```

Get the API key from [console.anthropic.com](https://console.anthropic.com/) → API Keys. A free-tier account is plenty for a single internal-tool app's volume.

> ⚠️ **Claude Max/Pro and the Anthropic API are separate billing tracks.** Same login, separate wallets:
>
> | Product | What it bills | Where you manage it |
> |---|---|---|
> | Claude Max / Pro | The chat product at claude.ai + Claude Code | claude.ai → Settings |
> | Anthropic API credits | Programmatic usage via api.anthropic.com (this helper, the SDK) | console.anthropic.com → Plans & Billing |
>
> Paying for Max/Pro does **not** give you API credits. If `ai_claude` returns 401/403 with a working key, the most likely cause is that the account has no API credits — top up at console.anthropic.com → Plans & Billing.

### Using `ai_claude` from code

```python
from app.lib import ai_claude

# Single-turn
text = ai_claude.generate("Summarise these todos: ...")

# Multi-turn
text = ai_claude.chat([
    {"role": "user", "content": "Hi"},
    {"role": "assistant", "content": "Hello! How can I help?"},
    {"role": "user", "content": "Plan a 3-step migration."},
])

# With system prompt or different model
text = ai_claude.generate(
    "Translate to Norwegian: ...",
    system="You translate concisely. Norwegian Bokmål.",
    model_id="claude-haiku-4-5-20251001",  # cheaper/faster for simple tasks
    max_tokens=200,
)
```

Errors map to HTTP statuses (429 for rate limit, 503 for connection issues, 504 for timeout) — surface them with `raise` and FastAPI handles the response.

## Calling the backend from the frontend

All non-GET requests to this app's backend MUST go through `frontend/src/lib/api.ts`. The plain `fetch()` API works for GET, but **breaks for POST/PUT/PATCH/DELETE-with-body** with HTTP 403 `InvalidSignatureException`.

Why: CloudFront's OAC (Origin Access Control) signs every request to the Lambda Function URL with SigV4. For body-bearing methods, AWS requires the **client** to include `x-amz-content-sha256: <sha256-of-body>` so CloudFront's signature reflects the body. Without that header, the Function URL's signature verification fails before Lambda is invoked. AWS docs: ["If you use PUT or POST methods with your Lambda function URL, your users must compute the SHA256 of the body..."](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-restricting-access-to-lambda.html)

Use:
```ts
import { apiGet, apiPost, apiPut, apiPatch, apiDelete, api } from "./lib/api"

// GET — plain fetch is also fine
const r = await apiGet("/api/notes")

// POST/PUT/PATCH/DELETE with body
await apiPost("/api/notes", { body: "hello" })
await apiPut("/api/notes/123", { body: "edit" })
await apiDelete("/api/notes/123")

// Anything custom (uncommon)
await api("POST", "/api/notes", { body: "..." }, { signal: ctrl.signal })
```

**Don't** call raw `fetch("/api/...", { method: "POST", body: ... })` — it'll work locally (Vite dev proxy bypasses CloudFront) but fail in production with a confusing 403.

## Enabling capabilities

Apps start with **all capabilities off** — bootstrap doesn't ask the user upfront because they don't know what they'll need. Your job (Claude) is to enable each capability the *first* time you realize it's needed for the feature being built, by editing `infra/terraform.tfvars` and then running `./scripts/initialize.sh`.

The platform supports exactly these five capabilities. Don't suggest other AWS services (RDS, ElastiCache, SQS, Step Functions, EventBridge, …) — they require a platform-admin discussion, not something a single app can self-serve.

| Capability | Enable how | Lambda env var | When you need it |
|---|---|---|---|
| **Postgres** | `database_enabled = true` in `terraform.tfvars` | `DATABASE_URL` | Any persistent / relational data: users, records, application state. Use the `app.lib.db` helper. |
| **S3 storage** | `storage_enabled = true` | `STORAGE_BUCKET` | File uploads, generated reports/PDFs/images, archives. Use `app.lib.storage`. |
| **DynamoDB tables** | `dynamodb_tables = ["sessions", "ratelimits"]` (one entry per logical table) | `KV_TABLE_<UPPER_NAME>` per table | High-throughput key/value lookups with simple schema (sessions, rate limits, idempotency keys). Use `app.lib.kv`. |
| **SES email** | `email_enabled = true` | `EMAIL_SENDER_DOMAIN` | Sending transactional email (signup confirmations, alerts). Use `app.lib.email`. |
| **Bedrock AI** | `ai_models_enabled = true` | (no env var; IAM grant only) | LLM calls. Use `app.lib.ai`. |

**Workflow when enabling**: edit `terraform.tfvars`, run `./scripts/initialize.sh`. The deploy creates the cloud resources (DB role+database, S3 bucket, etc.) and re-deploys the Lambda with the new env vars. Existing app code doesn't need to change — the helper just starts working in production. Locally, the helper continues using its fallback (postgres in docker-compose, `./uploads/`, SQLite, stderr) until you set the matching env vars in your shell or `docker-compose.yml`.

> ⚠ **Dev/prod parity caveat**: docker-compose always boots Postgres locally, even when `database_enabled = false`. So `db.connection()` works locally but raises in production with that flag off. If you call `db.connection()` and don't set `database_enabled = true`, you'll only discover the gap on first deploy. Best practice: only call DB helpers if you've also enabled the matching capability in `terraform.tfvars`.

**If the user asks for something outside this list** — e.g. "use Redis for caching", "set up an SQS queue", "trigger a Lambda from EventBridge", "use RDS instead of Neon" — explain that this isn't part of the quickship platform and point them at the platform admin. Don't try to wire raw AWS services around the platform.

## Adding a secret

For any value the app needs at runtime that should NOT be in source (API keys, signing secrets, third-party tokens):

1. **Declare the name in TF.** Edit `infra/terraform.tfvars` and add the secret name to `secret_names`. Names are lowercase letters/digits/underscores: `stripe_api_key`, `sendgrid_token`, etc.
   ```hcl
   secret_names = ["stripe_api_key", "sendgrid_token"]
   ```
2. **First deploy creates the placeholder.** Run `./scripts/initialize.sh`. Terraform creates an SSM SecureString at `/<prefix>/apps/<app>/<name>` with value `"REPLACE_ME"` and injects it into the Lambda as env var `<NAME_UPPERCASE>` (e.g. `STRIPE_API_KEY`). The app deploys but `secrets.get("stripe_api_key")` will raise a clear error if called.
3. **Set the real value.** Tell the user to run (or do it via the AWS console under Systems Manager → Parameter Store):
   ```bash
   aws ssm put-parameter \
     --name /<prefix>/apps/<app>/stripe_api_key \
     --value 'sk_live_...' \
     --type SecureString \
     --overwrite \
     --region eu-central-1
   ```
   The exact path to use comes from `terraform output` after step 2 (or substitute `<prefix>` and `<app>` from the values in `terraform.tfvars`).
4. **Re-deploy.** Run `./scripts/initialize.sh` again. Terraform re-reads SSM and pushes the new value into the Lambda env.

In app code:

```python
from app.lib import secrets

stripe_key = secrets.get("stripe_api_key")
```

Locally, just set the env var (`export STRIPE_API_KEY=sk_test_...` in your shell, or add it under `services.backend.environment` in `docker-compose.yml`). Same code path as production.

**Rotation** is the same dance starting from step 3: `put-parameter --overwrite`, then `./scripts/initialize.sh`. The new value reaches Lambda on the next apply.

**Security note**: secrets land in the Lambda env config in cleartext (visible to anyone with `lambda:GetFunctionConfiguration`). For this stack's threat model that's acceptable — same as `DATABASE_URL` — but don't put bank-grade secrets here. Anything more sensitive belongs in a dedicated KMS-encrypted env or a runtime SSM lookup, neither of which the platform supports today.

## AWS access for debugging

The platform provisions a per-developer IAM user with per-app permissions attached directly. The developer (or you, on their behalf) configures it once locally:

- **Profile name**: `__AWS_PROFILE__` (recorded in `infra/terraform.tfvars` as `aws_profile`; matches the platform's `name_prefix` per convention).
- For `aws ...` commands: use the `--profile __AWS_PROFILE__` flag form (this matches the whitelist in `.claude/settings.json` so common read-only calls run without prompting).
- For `docker compose up`: use `AWS_PROFILE=__AWS_PROFILE__ docker compose up` (or `export AWS_PROFILE=__AWS_PROFILE__` once in your shell). The container reads `AWS_PROFILE` from its environment to pick the right profile from the mounted `~/.aws/config` — a `--profile` flag on the docker side wouldn't reach the backend.

If the profile isn't set up yet, run `aws configure --profile __AWS_PROFILE__` and paste the access key + secret the platform admin sent. Region: usually `eu-central-1`. Output: `json`.

Verify it works:

```bash
aws --profile __AWS_PROFILE__ sts get-caller-identity
```

Success returns an `Arn:` ending in `user/__AWS_PROFILE__-developer-<name>`. If this fails:

| Error | Fix |
|---|---|
| `Unable to locate credentials` / `The config profile (__AWS_PROFILE__) could not be found` | Profile not configured. Run `aws configure --profile __AWS_PROFILE__` and paste the keys the admin sent. |
| `InvalidClientTokenId` | Access key wrong, or rotated. Ask the admin for the current key (or rotate yourself if you're admin). |
| `AccessDenied` on a specific resource | This user isn't on the app's `developers` list in the platform TF. Have the admin add the name and re-apply. |

### Common debug recipes

**Tail Lambda runtime logs** (the most-used command — runtime errors land here):

```bash
aws --profile __AWS_PROFILE__ logs tail /aws/lambda/__AWS_PROFILE__-<app> --follow --since 10m
```

**Tail CodeBuild logs** (for failed deploys):

```bash
aws --profile __AWS_PROFILE__ logs tail /aws/codebuild/__AWS_PROFILE__-<app> --follow --since 10m
```

**See pipeline state** (which stage is running, which failed):

```bash
aws --profile __AWS_PROFILE__ codepipeline get-pipeline-state --name __AWS_PROFILE__-<app>
```

The output's `latestExecution.status` per stage tells you `Succeeded`, `InProgress`, or `Failed`. For a failed stage, look at `errorDetails` in the same JSON.

**Get details of a specific build** (build ID comes from pipeline state or `list-builds-for-project`):

```bash
aws --profile __AWS_PROFILE__ codebuild batch-get-builds --ids <build-id>
```

**Trigger a manual pipeline run** (asks for confirmation — write op):

```bash
aws --profile __AWS_PROFILE__ codepipeline start-pipeline-execution --name __AWS_PROFILE__-<app>
```

**Read a secret value** (verify the operator set it correctly):

```bash
aws --profile __AWS_PROFILE__ ssm get-parameter \
  --name /__AWS_PROFILE__/apps/<app>/<secret_name> \
  --with-decryption \
  --query Parameter.Value --output text
```

**Set a secret value** (asks for confirmation — write op):

```bash
aws --profile __AWS_PROFILE__ ssm put-parameter \
  --name /__AWS_PROFILE__/apps/<app>/<secret_name> \
  --value '...' \
  --type SecureString \
  --overwrite
```

### When fetching logs, prefer `--since`

`aws logs tail` without bounds replays everything since the log group's retention horizon. Always pass `--since 10m` (or `1h`, etc.) unless you genuinely want the whole history.

For deeper search, use Logs Insights:

```bash
aws --profile __AWS_PROFILE__ logs start-query \
  --log-group-name /aws/lambda/__AWS_PROFILE__-<app> \
  --start-time $(date -v-1H +%s) \
  --end-time $(date +%s) \
  --query-string 'fields @timestamp, @message | filter @message like /error/i | sort @timestamp desc | limit 50'
```

The returned `queryId` then feeds `aws logs get-query-results --query-id <id>`.

### Local dev hits real AWS

For `docker compose up`, the backend container needs the profile in its environment. Two ways:

```bash
# Per-session: prefix the command
AWS_PROFILE=__AWS_PROFILE__ docker compose up

# Or set it once in your shell so future commands inherit
export AWS_PROFILE=__AWS_PROFILE__
docker compose up
```

The backend container reads creds from the mounted `~/.aws` and exercises real AWS for any capability the app declares (S3, DynamoDB, Bedrock, SSM secrets). The same role attached for debugging covers these — that's why the developer-access policy mirrors the Lambda execution role for capability resources.

## Scheduled jobs

When the user wants something to run on a cron — daily reports, periodic cleanup, hourly polls of an external API — use the platform's scheduled-jobs mechanism. AWS EventBridge Scheduler fires the Lambda with a special payload, and `backend/handler.py` routes those to functions in `backend/app/cron.py`.

### Adding a scheduled job

1. **Define the function** in `backend/app/cron.py`:
   ```python
   def daily_report():
       from app.lib import db, email
       with db.connection() as conn, conn.cursor() as cur:
           cur.execute("SELECT count(*) FROM notes")
           count = cur.fetchone()[0]
       email.send(to="ops@example.com", subject="Daily report",
                  body_text=f"{count} notes total.")
   ```
   - No arguments, no return value.
   - Use the standard `app.lib.*` helpers — same as a route handler.
   - Errors propagate. EventBridge retries 3× within 1h by default. Functions should be **idempotent** since retries can re-run partial work.

2. **Add the schedule** in `infra/terraform.tfvars`:
   ```hcl
   cron_schedules = [
     { name = "daily_report", expression = "cron(0 9 * * ? *)" },  # 9am UTC daily
   ]
   ```
   - `name` must match the function name exactly.
   - `expression` is AWS schedule syntax: `cron(min hour day-of-month month day-of-week year)` or `rate(1 hour)`. Note AWS cron uses `?` for "any" in day-of-month/day-of-week, and the year field is required. Time is UTC.

3. **Push to main.** The orchestrator runs `terraform apply`, which creates the EventBridge Scheduler resource. The pipeline then deploys the new Lambda code with the cron function defined.

### Testing locally

```bash
docker compose exec backend python -m app.cron daily_report
```

Runs the function once against your local Postgres + dev AWS creds. No schedule emulation — that'd be too noisy locally for daily/hourly jobs.

### Inspecting schedules in prod

```bash
# All this app's schedules
aws --profile __AWS_PROFILE__ scheduler list-schedules \
  --query "Schedules[?starts_with(Name, '__AWS_PROFILE__-__APP_NAME__')]" \
  --output table

# Details + next firing time
aws --profile __AWS_PROFILE__ scheduler get-schedule \
  --name __AWS_PROFILE__-__APP_NAME__-daily_report
```

### Manual test-fire in prod

If a job needs to be re-run out of band (e.g., it failed and you want a manual retry without waiting for the next scheduled fire):

```bash
aws --profile __AWS_PROFILE__ lambda invoke \
  --function-name __AWS_PROFILE__-__APP_NAME__ \
  --payload '{"_quickship_cron":"daily_report"}' \
  --cli-binary-format raw-in-base64-out \
  /tmp/cron-out.json
cat /tmp/cron-out.json
```

CloudWatch Lambda logs will show the run; same logs as regular requests.

### Removing a schedule

Delete the entry from `cron_schedules` in tfvars and push to main. Terraform destroys the EventBridge Scheduler resource. The function definition in `app/cron.py` can stay or be removed — without a schedule it just won't fire.

### Caveats / when not to use this

- **Long jobs**: Lambda's `timeout_seconds` (default 25) caps each invocation. For multi-minute work, either bump the timeout (max 900) or move to a different mechanism.
- **High frequency**: every 1 minute is fine; sub-minute isn't supported by EventBridge Scheduler. For high-frequency, consider whether the work belongs in a request handler instead.
- **State across runs**: schedules fire and forget. If a job needs to know "where did I leave off", store cursor state in DB or DynamoDB.

## Common tasks

- **Add a route**: create `backend/app/routes/<name>.py`, register in `app/main.py`. Pattern: `@router.get("/api/...")` with `Depends(current_user)`.
- **Add a migration**: create `backend/migrations/NNNN_description.sql` (forward, plain SQL) AND `backend/migrations/NNNN_description.rollback.sql` (rollback, plain SQL or comment-only if irreversible). See "Safe migration recipes" above.
- **Run locally**: `docker compose up`.
- **Deploy infra changes** (anything in `infra/`): `./scripts/initialize.sh`. Zips the working tree, uploads to the platform's orchestrator bucket, starts a CodeBuild that runs `terraform apply` with admin-level perms (the dev's own IAM user does NOT have apply perms — by design). Tails the logs until the build finishes.
- **Ship code changes**: `git push`, then **spawn a background monitor agent** — see "Watching a deploy" below. The user has IAM access keys but no AWS console access (by platform design — there's no SSO/console session for them), so you are their only window into the pipeline. If you don't surface the result, they're blind.
- **Destroy an app entirely**: `./scripts/destroy.sh`. Same orchestrator path with `MODE=destroy`. Strong confirmation required — irreversible.
- **Upgrade platform-owned files**: `./scripts/upgrade.sh` (dry-run) or `./scripts/upgrade.sh --apply`. Sync the bootstrap-flow scripts and Claude's agents/commands from the latest template. Doesn't touch app code, infra, or deps. Run when the platform announces an update; review with `git diff` afterward.
- **Inspect prod DB**: `psql "$(aws --profile __AWS_PROFILE__ ssm get-parameter --name /__AWS_PROFILE__/apps/__APP_NAME__/database_url --with-decryption --query Parameter.Value --output text --region eu-central-1)"`.
- **Bump Lambda timeout / memory**: uncomment `memory_mb` / `timeout_seconds` in `infra/terraform.tfvars`. Defaults (256 MB, 25 s) cover Bedrock + DB roundtrips for typical requests. Symptoms that suggest bumping: CloudWatch shows `Task timed out after 25.00 seconds` (raise timeout, max 900); cold starts or steady-state latency drag (raise memory — CPU scales with it). If a single request legitimately needs minutes, prefer a background-job pattern over a long Lambda.

## Watching a deploy

When the user wants to deploy ("push it", "ship this", "deploy", or right after they confirm a change is ready), the flow is:

1. **Review the diff first.** Invoke the `quickship-reviewer` agent over the changed files (`git diff main...HEAD` if on a branch, otherwise `git status` + `git diff`). The reviewer covers both platform-conformance violations AND the security mistakes amateurs commonly make (IDOR, SQL injection, mass assignment, SSRF, dangerouslySetInnerHTML, hardcoded secrets, etc.). If it reports any **block-merge** findings, surface them as the headline and **do not push** until the user has either fixed them or explicitly waived (waivers go in the commit message). The user is non-technical; they cannot spot these themselves — that's the contract.

   **Skip the review only when**: change is doc-only (markdown, README) with no code modifications; OR the user explicitly says "skip review" / "I've already reviewed".

2. **`git push`** — the pipeline triggers on the push (CodeStarSourceConnection webhook from GitLab/GitHub).
3. **Spawn a background agent to monitor the pipeline.** The user has IAM access keys but **no AWS console access** — by platform design, there's no SSO permission set / console session for the developer IAM user. That means they cannot click into a CodePipeline view, cannot tail CloudWatch logs in the browser, cannot see anything happening server-side except via you. If you don't watch and report, they sit looking at a terminal with no signal.

Use the Agent tool with `run_in_background: true`. Sample call:

```
Agent({
  description: "Monitor __APP_NAME__ deploy",
  subagent_type: "general-purpose",
  prompt: `Monitor the latest pipeline execution for '__AWS_PROFILE__-__APP_NAME__'. Loop:

  - Run: aws --profile __AWS_PROFILE__ codepipeline list-pipeline-executions --pipeline-name __AWS_PROFILE__-__APP_NAME__ --max-items 1 --query 'pipelineExecutionSummaries[0].{id:pipelineExecutionId,status:status,started:startTime}' --output json
  - If status is InProgress or no execution yet, sleep 20 seconds and retry.
  - If status is Succeeded, report: '✓ Deploy succeeded. App live at https://__APP_NAME__.<apex>' (find apex from infra/terraform.tfvars or the existing 'app_url' Terraform output if you can).
  - If status is Failed, fetch the last 50 lines from the failed stage's CodeBuild log group:
      aws --profile __AWS_PROFILE__ logs tail /aws/codebuild/__AWS_PROFILE__-__APP_NAME__ --since 10m --format short
    Report the failure with a 1-2 sentence diagnosis of the most likely cause based on the log.
  - Cap at 30 iterations (~10 minutes). Beyond that, report 'still running, check console' and stop.

  Keep output terse — one line on success, error excerpt + diagnosis on failure.`,
  run_in_background: true
})
```

After spawning, tell the user briefly: "Pushed. Watching the pipeline; I'll surface the result when it's done." Then continue with whatever else they asked. Claude Code surfaces the agent's result automatically when it completes — you don't need to poll or check on it.

**When NOT to spawn this agent:**
- Pure infra-only changes (no app code) — `./scripts/initialize.sh` already tails the orchestrator log directly. The pipeline picks up the same change on push but the orchestrator-tail captures the apply.
- The user is debugging something locally and explicitly doesn't want to push yet.
- Multiple pushes in quick succession — only spawn one agent for the latest push; cancel/skip earlier ones.

**Caveat to be honest about:** this works only inside this Claude Code session. If the user closes Claude before the deploy finishes, the background agent dies. For high-stakes deploys, also encourage them to keep the session open or check the pipeline manually afterward.

## Upgrading platform-owned files

The platform is on a continuous-release model — `template@main` evolves between when the user bootstrapped this app and now. A subset of the files in this repo are **platform-owned**: the helper scripts under `scripts/`, and Claude's own agents/commands under `.claude/`. They get fixes, new behaviour, security improvements over time. The user has no automatic way to pull those changes; that's what `./scripts/upgrade.sh` does.

### When to suggest running it

Recommend `./scripts/upgrade.sh` when:
- The user mentions a platform-side change ("the platform team said…", "I read in the README…").
- A debug session uncovers behaviour that doesn't match what's documented in this CLAUDE.md (e.g., the reviewer agent missed a rule that the platform's reviewer should now catch).
- The user asks "is there an upgrade?" / "any platform updates?" / "am I out of date?"

The script's manifest is intentionally narrow (8 files, none of them user-editable in normal use), so suggesting it is low-risk.

### Reading the output

```
$ ./scripts/upgrade.sh
→ Fetching https://github.com/stadskle/quickship-app-template.git@main...
  ~ scripts/initialize.sh                 # ← this file changed in template since bootstrap
  + .claude/commands/newverb.md (new)     # ← template added a new file

2 file(s) differ from template@main.
Re-run with --apply to overwrite. (Dry run; no files modified.)
```

`~` = file content differs. `+` = template has a new file the app doesn't. No output for a file means it's already in sync.

After `--apply`:
```
✓ Updated 2 file(s).
```

The script does **not** auto-commit. Always do this next:
1. Run `git diff` to verify what changed (the user trusts you to interpret this — most diffs will be straightforward platform-fix-vs-old-version).
2. `git add` the affected files.
3. Commit with a message like "platform upgrade" so it's clear in the log this wasn't a feature change.
4. `git push` (the pipeline ignores changes to `scripts/` and `.claude/` for code deploys, but the commit still lands in git history).

### What it doesn't touch

App code (`backend/app/main.py`, `backend/app/routes/`, `frontend/src/App.tsx`), infra (`infra/`), data (`backend/migrations/`), and dependency files (`requirements.txt`, `package.json`) are **never** modified by upgrade.sh. If the platform changes how, e.g., `app.lib.ai_claude` works, the user has to opt in by reading the changelog and editing their own code — upgrade.sh won't push helper-library changes (yet — manifest may grow).

### When something breaks after upgrade

If a synced file breaks something (rare — manifest is platform code), the safe restore is `git checkout HEAD~1 -- <file>` (assuming you committed before testing). Worst case: re-curl the file from the old template ref via `--ref <commit-sha>`.

## Working with the test environment

If `test_environment_enabled = true` in `infra/terraform.tfvars`, the app has a parallel stack at `<app>-test.<apex>` deployed from a `test` git branch. Two pipelines, two Lambdas, two databases (when DB is enabled), two of everything per-app — fully isolated from prod.

### Branch model

| Branch | Pipeline | What it deploys |
|---|---|---|
| `main` | prod | Runs orchestrator → `terraform apply` (covers BOTH prod and test infra) → updates prod Lambda code |
| `test` | test | Code-only update of test Lambda (no `terraform apply`) |

Critical asymmetry: **infra changes flow only through `main`**. The test pipeline does NOT run terraform — if it did, the test branch's `terraform.tfvars` would race the main branch's against the same shared tfstate. Don't try to set capabilities or change resources from the `test` branch; those edits get ignored until they merge back to `main`.

### Typical workflow

```bash
# Try a risky change first on test
git checkout test
git merge main           # bring test up to date with prod
# … edit backend/frontend code …
git commit -am "experimental change"
git push                 # test pipeline → updates <app>-test.<apex>

# Validate it at https://<app>-test.<apex>

# Promote to prod when happy
git checkout main
git merge test           # fast-forward or no-ff, your call
git push                 # prod pipeline → terraform apply + updates <app>.<apex>
```

### When to suggest the test environment

Recommend turning it on (`test_environment_enabled = true` + re-deploy via `./scripts/initialize.sh` or a main-branch push) when:
- The user is about to make a change that's risky to validate locally (Bedrock prompts, SES sends, third-party API integrations, anything that's awkward to mock).
- They're tweaking auth/access flows that depend on Cloudflare Access being in front.
- They've had a prod regression and want a smoke-test layer.

Push back when:
- The app is single-developer, low-stakes, and they're already happy with `docker compose up` for iteration. The test env doubles cost and adds branch-juggling friction.

### Toggling the test env later

To turn ON later: edit tfvars (`test_environment_enabled = true`), commit, push to main → orchestrator provisions the test stack. Manually push the `test` branch (`git branch test main && git push -u origin test`) so the test pipeline has a source.

To turn OFF: edit tfvars (`test_environment_enabled = false`), commit, push to main → orchestrator destroys the test-side resources. The `test` branch on the remote stays around but is unused.

## Changing the Python version (rare)

Default is Python 3.12 across Lambda, local Dockerfile, and (when wired) CodeBuild. To upgrade or downgrade:

1. Set `runtime = "python3.13"` in `infra/terraform.tfvars` — this drives the Lambda runtime and the CodeBuild image.
2. In `docker-compose.yml`, under `services.backend`, add a `build:` block with `args: { PYTHON_VERSION: "3.13" }` so local matches.
3. Reinstall deps locally: `docker compose build backend && docker compose up`.

All three must match (Lambda runtime, local image, CodeBuild image) — psycopg/cryptography wheels are compiled per Python minor and won't load if mixed. The Terraform variable is the single source of truth; only the docker-compose arg is duplicated.

## Security rules

Amateurs build these apps. You (Claude) carry the burden of *not* introducing common security holes — the user won't know to ask. Treat every feature as half-done until you've checked these. Run `/review` (or invoke the `quickship-reviewer` agent) before declaring a feature complete.

### Authorization on every read AND write

Every query touching user-owned data filters by `owner_email = %s`. This includes "look up by ID" — the ID alone is not authorization.

```python
# WRONG — IDOR. Any logged-in user can read or delete any note by guessing IDs.
cur.execute("SELECT body FROM notes WHERE id = %s", (note_id,))
cur.execute("DELETE FROM notes WHERE id = %s", (note_id,))

# RIGHT — scoped to current user.
cur.execute(
    "SELECT body FROM notes WHERE id = %s AND owner_email = %s",
    (note_id, user["email"]),
)
cur.execute(
    "DELETE FROM notes WHERE id = %s AND owner_email = %s",
    (note_id, user["email"]),
)
```

### Parameterized SQL only

Never f-strings, never string concat. `cur.execute(query, params)` always — psycopg handles escaping. The single exception is dynamic identifiers (table/column names), which require `psycopg.sql.Identifier`.

```python
# WRONG — SQL injection.
cur.execute(f"SELECT * FROM notes WHERE owner_email = '{email}'")
cur.execute("SELECT * FROM notes WHERE owner_email = '" + email + "'")

# RIGHT.
cur.execute("SELECT * FROM notes WHERE owner_email = %s", (email,))
```

### Mass-assignment guard

When building UPDATEs or INSERTs from request bodies, list explicit columns. Never splat a Pydantic model into SQL.

```python
# WRONG — caller can set owner_email or any other column you didn't think of.
update_fields = ", ".join(f"{k} = %s" for k in payload.dict())
cur.execute(f"UPDATE notes SET {update_fields} WHERE id = %s", ...)

# RIGHT — explicit allowlist.
cur.execute(
    "UPDATE notes SET body = %s, updated_at = now() WHERE id = %s AND owner_email = %s",
    (payload.body, note_id, user["email"]),
)
```

### File uploads

- Validate type (`Content-Type` and/or magic bytes) and size (cap at a reasonable limit, e.g. 10 MB).
- S3 keys are server-built, never user-provided: use `f"{user['email']}/{uuid4()}/{safe_name}"`. Never let the request body control the key.
- Strip path components from filenames before use (`os.path.basename`).

### Secrets

- Never store API keys, tokens, or passwords in Postgres rows or DynamoDB. Use SSM (the platform exposes a helper-readable path).
- Never log request bodies, headers, or env vars wholesale. If you must log a request, redact (`{"action": "create_note", "user": user["email"], "body_len": len(body)}`).

### React XSS

- Trust React's auto-escaping. Don't use `dangerouslySetInnerHTML` unless rendering known-safe HTML, and even then sanitize with DOMPurify.
- User-provided URLs in `href`/`src`: validate they start with `http://`, `https://`, or `mailto:` — block `javascript:` and `data:`.

### Outbound HTTP (SSRF)

If the app fetches a URL the user provided, validate it: block private IP ranges (`127.0.0.0/8`, `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.169.254`) and require an http/https scheme. Lambda's metadata service is a juicy target.

### Email injection

When sending email based on user input, the `to`, `subject`, and headers must come from server-controlled values or be strictly validated. Never put raw user input into a `Cc`/`Bcc` field.

### Dependency freshness

LLMs (you) often pin stale versions because training data is older than the registry. Before adding or bumping a dependency:

1. Fetch the **current latest stable** version from PyPI / npm — don't guess from memory.
   - `pip index versions <package>` or check `https://pypi.org/project/<package>/`
   - `npm view <package> version`
2. Use the project's existing pin convention:
   - `package.json` → caret pins like `"^X.Y.Z"` (locks major; allows minor + patch).
   - `requirements.txt` → compatible-release like `pkg~=X.Y.Z` (locks minor; allows patch).
   - This gives hallucination resilience (a non-existent specific patch resolves to latest in range) and automatic security patches without template-side maintenance.
3. Prefer existing helpers and stdlib. New deps are surface area; the burden of justification is on the new dep.
4. If the user asks for a feature that needs a new dep, surface that explicitly: "this needs `<package>` (latest is `X.Y.Z`) — confirm before I add it?"

When bumping the major (or pulling in something that requires a major-version bump on an existing dep), read the changelog for breaking changes — don't just bump and pray.

### Lockfiles are required for the pipeline

`frontend/package-lock.json` MUST be committed. The pipeline runs `npm ci` (not `npm install`) for deterministic builds, and `npm ci` errors out immediately when the lockfile is missing — frontend build fails, no Lambda code ships.

After any change to `frontend/package.json` (adding, bumping, removing a dep), regenerate and commit the lockfile:

```bash
cd frontend && npm install
git add package.json package-lock.json
```

Same applies to `backend/requirements.txt` if you ever produce a `requirements-lock.txt` (we don't currently — pip's strictness model is different from npm's).

## Don'ts

- ❌ Don't validate JWTs in app code. The platform does it at the edge.
- ❌ Don't `CREATE TABLE` from app code. Use migrations.
- ❌ Don't `import boto3` in route handlers. Use `app.lib.*` helpers.
- ❌ Don't add an `Authorization` header check. Cloudflare Access handles auth.
- ❌ Don't call `fetch("/api/...", { method: "POST", body: ... })` from the frontend. Use `apiPost` (or `apiPut`/`apiPatch`/`apiDelete`) from `frontend/src/lib/api.ts`. Raw fetch with body fails in production with HTTP 403 `InvalidSignatureException`.
- ❌ Don't add `dotenv` or `.env`-loading machinery. The container injects env vars; locally `docker-compose.yml` does it.
- ❌ Don't write the test suite to mock AWS — use the helper local-dev fallbacks (write to `./uploads/`, SQLite for KV, stdout for email).

## Reference

- Platform module source: `infra/main.tf` references `quickship-platform//modules/quickship`. Full docs in that repo.
- Platform spec for this app: `https://specs.<platform-domain>/__APP_NAME__/spec.json` (once Step 8 lands).
