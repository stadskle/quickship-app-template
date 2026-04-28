---
description: Start the local dev environment (postgres + backend hot reload)
---

Start the local dev loop.

Steps:
1. Run `docker compose up -d` to start Postgres and the backend in the background.
2. Wait for `docker compose ps` to show both services healthy/running (poll every 2-3 seconds, max ~30 seconds).
3. Run `curl -s http://localhost:8000/api/_health` to confirm the backend is responding.
4. Show the user the URLs:
   - Backend: http://localhost:8000
   - DB: `docker compose exec postgres psql -U <app-name>`
5. Tell them how to follow logs: `docker compose logs -f backend`, and how to stop: `docker compose down` (or `docker compose down -v` to wipe the DB volume).

If a service fails to start, dump the logs (`docker compose logs <service>`) and explain what's wrong.
