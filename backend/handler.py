"""
Lambda entrypoint shim.

The platform's tinyapp module configures Lambda with `handler = "handler.handler"`
(expects a callable named `handler` at zip root). We re-export Mangum's ASGI
adapter from `app.main` so the FastAPI app IS the handler.
"""

from app.main import handler

__all__ = ["handler"]
