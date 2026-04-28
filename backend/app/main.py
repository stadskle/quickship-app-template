"""
FastAPI entrypoint.

Same code runs locally (uvicorn) and in Lambda (Mangum). The `handler`
export at the bottom is what the Lambda Function URL invokes.

Yoyo migrations run on startup via the lifespan event — locally on
container start, in production on Lambda cold start (once per container,
fast no-op when nothing pending).

In production, the build step packs the Vite-built frontend into
`static/` at zip root; we mount it at /static/ and add a SPA fallback
that serves index.html for any unmatched non-/api/ path so React Router
can take over client-side routing.
"""

from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import Depends, FastAPI, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from mangum import Mangum

from app.lib import db
from app.lib.auth import User, current_user


@asynccontextmanager
async def lifespan(_app: FastAPI):
    db.apply_migrations()
    yield


app = FastAPI(title="__APP_NAME__", lifespan=lifespan)


@app.get("/api/_health")
def health():
    """Health check. Used by uptime monitors. Don't put auth on this one."""
    return {"ok": True}


@app.get("/api/me")
def me(user: User = Depends(current_user)):
    """Returns the authenticated user's identity (or the dev fixture locally)."""
    return user


# --- Frontend (production) -------------------------------------------------
#
# When the pipeline packs `frontend/dist/` into `static/` at zip root, the
# directory exists at runtime and we serve it. Locally the directory is
# absent and the mount is skipped — the Vite dev server handles the UI.

STATIC_DIR = Path(__file__).resolve().parent.parent / "static"

if STATIC_DIR.exists():
    app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")

    @app.get("/{path:path}")
    async def spa_fallback(path: str):
        """Catch-all: serve index.html so client-side routing works.
        Excludes /api/* (returns proper 404 for unknown endpoints)."""
        if path.startswith("api/"):
            raise HTTPException(status_code=404)
        index = STATIC_DIR / "index.html"
        if not index.exists():
            raise HTTPException(status_code=500, detail="frontend not built")
        return FileResponse(index)
else:
    @app.get("/")
    def hello():
        """API-only landing endpoint when no frontend is bundled."""
        return {"app": "__APP_NAME__", "ok": True}


# Lambda entrypoint. Mangum adapts API-Gateway/Function-URL events to ASGI.
handler = Mangum(app)
