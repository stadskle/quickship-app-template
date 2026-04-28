---
description: Scaffold a new FastAPI route module
---

Add a FastAPI route for: $ARGUMENTS

Conventions for this app (from CLAUDE.md):
- Route files live at `backend/app/routes/<name>.py`. Create the `routes/` directory if it doesn't exist (with `__init__.py`).
- Use a `fastapi.APIRouter()` per file. Register the router in `backend/app/main.py` via `app.include_router(...)`.
- Routes that need authentication take `user: User = Depends(current_user)` from `app.lib.auth`. Routes that don't (health, public landing) omit the dependency.
- Path prefix: `/api/<resource>` for backend endpoints (frontend's Vite dev server proxies `/api/*` to the backend).
- Return JSON-serialisable dicts/Pydantic models; FastAPI handles serialization.

Steps:
1. Pick a descriptive filename for the route (e.g., `notes.py` for "notes" feature).
2. Create `backend/app/routes/__init__.py` if it doesn't exist (empty file).
3. Create `backend/app/routes/<name>.py` with the router and the requested endpoints.
4. Update `backend/app/main.py` to import and `include_router()` the new module.
5. Show the diff and tell the user to restart the backend container (or rely on uvicorn `--reload` to pick it up automatically).

For database-touching routes, use `app.lib.db.connection()` (not raw psycopg). Don't `import boto3` directly — use `app.lib.*` helpers when those land. If the user asks for a feature requiring a not-yet-built helper, flag that and ask whether to scaffold without it or wait.
