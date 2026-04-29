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

> ⚠ The local auth fixture trusts whatever `Cf-Access-Authenticated-User-Email` header it sees, falling back to `dev@local` if absent. That's safe on a single-developer laptop where docker-compose is reachable only from `localhost`. **Don't expose port 8000 publicly** (no `ngrok`, no router port-forward, no `--host 0.0.0.0` outside the container) — anyone reaching it could spoof any email by setting that header. For "let a teammate try my local app", use `/deploy` instead and Cloudflare Access will gate it properly.

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

## Helper imports — use these, not raw boto3

| Capability | Helper | Typical use |
|---|---|---|
| Auth | `app.lib.auth.current_user` | `user: User = Depends(current_user)` on protected routes |
| DB | `app.lib.db.connection()` / `db.transaction()` | psycopg context manager for Postgres |
| Storage (S3) | `app.lib.storage` | `storage.upload(key, bytes)`, `storage.presigned_url(key)` |
| KV (DynamoDB) | `app.lib.kv` | `kv.put("sessions", key, value, ttl_seconds=3600)`, `kv.get(...)` |
| Email (SES) | `app.lib.email` | `email.send(to=..., subject=..., body_text=...)` |
| AI (Bedrock) | `app.lib.ai` | `ai.generate(prompt)` for one-shot, `ai.chat(messages)` for multi-turn |
| Secrets | `app.lib.secrets` | `secrets.get("stripe_api_key")` — see "Adding a secret" below |

Every helper has a localhost fallback so the same code path runs in dev and prod:
- DB → docker-compose Postgres
- Storage → `./uploads/` on the host
- KV → SQLite at `./local.db`
- Email → printed to stderr
- AI → real AWS Bedrock with your dev credentials (no local mock)

If you find yourself writing `import boto3` in a route file, **stop and check whether a helper exists**. The helpers handle local-dev fallbacks, IAM scoping, and platform conventions. Bypassing them creates dev/prod drift.

## Enabling capabilities

Apps start with **all capabilities off** — bootstrap doesn't ask the user upfront because they don't know what they'll need. Your job (Claude) is to enable each capability the *first* time you realize it's needed for the feature being built, by editing `infra/terraform.tfvars` and then running `/deploy`.

The platform supports exactly these five capabilities. Don't suggest other AWS services (RDS, ElastiCache, SQS, Step Functions, EventBridge, …) — they require a platform-admin discussion, not something a single app can self-serve.

| Capability | Enable how | Lambda env var | When you need it |
|---|---|---|---|
| **Postgres** | `database_enabled = true` in `terraform.tfvars` | `DATABASE_URL` | Any persistent / relational data: users, records, application state. Use the `app.lib.db` helper. |
| **S3 storage** | `storage_enabled = true` | `STORAGE_BUCKET` | File uploads, generated reports/PDFs/images, archives. Use `app.lib.storage`. |
| **DynamoDB tables** | `dynamodb_tables = ["sessions", "ratelimits"]` (one entry per logical table) | `KV_TABLE_<UPPER_NAME>` per table | High-throughput key/value lookups with simple schema (sessions, rate limits, idempotency keys). Use `app.lib.kv`. |
| **SES email** | `email_enabled = true` | `EMAIL_SENDER_DOMAIN` | Sending transactional email (signup confirmations, alerts). Use `app.lib.email`. |
| **Bedrock AI** | `ai_models_enabled = true` | (no env var; IAM grant only) | LLM calls. Use `app.lib.ai`. |

**Workflow when enabling**: edit `terraform.tfvars`, run `/deploy`. The deploy creates the cloud resources (DB role+database, S3 bucket, etc.) and re-deploys the Lambda with the new env vars. Existing app code doesn't need to change — the helper just starts working in production. Locally, the helper continues using its fallback (postgres in docker-compose, `./uploads/`, SQLite, stderr) until you set the matching env vars in your shell or `docker-compose.yml`.

> ⚠ **Dev/prod parity caveat**: docker-compose always boots Postgres locally, even when `database_enabled = false`. So `db.connection()` works locally but raises in production with that flag off. If you call `db.connection()` and don't set `database_enabled = true`, you'll only discover the gap on first deploy. Best practice: only call DB helpers if you've also enabled the matching capability in `terraform.tfvars`.

**If the user asks for something outside this list** — e.g. "use Redis for caching", "set up an SQS queue", "trigger a Lambda from EventBridge", "use RDS instead of Neon" — explain that this isn't part of the quickship platform and point them at the platform admin. Don't try to wire raw AWS services around the platform.

## Adding a secret

For any value the app needs at runtime that should NOT be in source (API keys, signing secrets, third-party tokens):

1. **Declare the name in TF.** Edit `infra/terraform.tfvars` and add the secret name to `secret_names`. Names are lowercase letters/digits/underscores: `stripe_api_key`, `sendgrid_token`, etc.
   ```hcl
   secret_names = ["stripe_api_key", "sendgrid_token"]
   ```
2. **First deploy creates the placeholder.** Run `/deploy`. Terraform creates an SSM SecureString at `/<prefix>/apps/<app>/<name>` with value `"REPLACE_ME"` and injects it into the Lambda as env var `<NAME_UPPERCASE>` (e.g. `STRIPE_API_KEY`). The app deploys but `secrets.get("stripe_api_key")` will raise a clear error if called.
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
4. **Re-deploy.** Run `/deploy` again. Terraform re-reads SSM and pushes the new value into the Lambda env.

In app code:

```python
from app.lib import secrets

stripe_key = secrets.get("stripe_api_key")
```

Locally, just set the env var (`export STRIPE_API_KEY=sk_test_...` in your shell, or add it under `services.backend.environment` in `docker-compose.yml`). Same code path as production.

**Rotation** is the same dance starting from step 3: `put-parameter --overwrite`, then `/deploy`. The new value reaches Lambda on the next apply.

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

## Common tasks

- **Add a route**: create `backend/app/routes/<name>.py`, register in `app/main.py`. Pattern: `@router.get("/api/...")` with `Depends(current_user)`.
- **Add a migration**: create `backend/migrations/NNNN_description.sql` with the next sequential number. Plain SQL.
- **Run locally**: `docker compose up`.
- **Deploy infra changes** (Terraform): `/deploy`. Runs the security review, sets `git_repo` if needed, plans, applies. After the first apply creates the pipeline, code changes ship via `git push` automatically — only re-run `/deploy` when something in `infra/` changes.
- **Ship code changes**: `git push`. CodePipeline detects, builds, and updates the Lambda. Watch progress at `terraform output -raw pipeline_console_url`.
- **Inspect prod DB**: `psql "$(aws --profile __AWS_PROFILE__ ssm get-parameter --name /__AWS_PROFILE__/apps/__APP_NAME__/database_url --with-decryption --query Parameter.Value --output text --region eu-central-1)"`.

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

When bumping the major (or pulling in something that requires a major-version bump on an existing dep), read the changelog for breaking changes — don't just bump and pray. Lockfiles (`package-lock.json` once you `npm install`, optional `requirements-lock.txt` via `pip freeze`) capture the exact resolved tree per repo for reproducibility.

## Don'ts

- ❌ Don't validate JWTs in app code. The platform does it at the edge.
- ❌ Don't `CREATE TABLE` from app code. Use migrations.
- ❌ Don't `import boto3` in route handlers. Use `app.lib.*` helpers.
- ❌ Don't add an `Authorization` header check. Cloudflare Access handles auth.
- ❌ Don't add `dotenv` or `.env`-loading machinery. The container injects env vars; locally `docker-compose.yml` does it.
- ❌ Don't write the test suite to mock AWS — use the helper local-dev fallbacks (write to `./uploads/`, SQLite for KV, stdout for email).

## Reference

- Platform module source: `infra/main.tf` references `quickship-platform//modules/quickship`. Full docs in that repo.
- Platform spec for this app: `https://specs.<platform-domain>/__APP_NAME__/spec.json` (once Step 8 lands).
