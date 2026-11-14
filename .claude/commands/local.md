---
description: Start the local dev environment (backend + frontend hot reload, -localdev DSQL)
---

Start the local dev loop.

Steps:
1. Run `docker compose up -d` to start the backend and frontend in the background. (There is no database container — the backend talks to this app's `-localdev` Aurora DSQL cluster in AWS through the developer's AWS profile.)
2. Wait for `docker compose ps` to show both services running (poll every 2-3 seconds, max ~30 seconds).
3. Run `curl -s http://localhost:8000/api/_health` to confirm the backend is responding.
4. Show the user the URLs:
   - Frontend: http://localhost:5173
   - Backend: http://localhost:8000
   - Migrations: `docker compose exec backend python -m app.lib.migrate status`
5. Tell them how to follow logs: `docker compose logs -f backend`, and how to stop: `docker compose down`.

If the backend logs show `No database configured` but the app uses the DB, `database_enabled` isn't on yet or `./scripts/initialize.sh` hasn't run — that's what creates the `-localdev` cluster. If they show an AWS credentials / `AccessDenied` error, the developer's platform AWS profile (`aws_profile` in `infra/terraform.tfvars`) isn't configured or they aren't listed in `developers` in `infra/terraform.tfvars`.

If a service fails to start, dump the logs (`docker compose logs <service>`) and explain what's wrong.
