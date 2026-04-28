"""
Auth helper.

The platform's chain-of-trust (Cloudflare Access → CloudFront WAF → IAM/OAC)
ensures the request reaching this code is already authenticated. Cloudflare
Access adds the `Cf-Access-Authenticated-User-Email` header before forwarding
to origin; we read it and trust it.

Locally there's no Cloudflare in the path, so the header is absent. We fall
back to a fixture user — the same code runs in dev and prod with no flags.

The user's email is the stable identity. Use it as the foreign key on
user-owned rows (e.g. `owner_email TEXT NOT NULL`). It survives session
expiry and re-login; no separate user-id table is needed.
"""

from __future__ import annotations

from typing import Annotated, TypedDict

from fastapi import Header


class User(TypedDict):
    email: str


def current_user(
    cf_access_authenticated_user_email: Annotated[str | None, Header()] = None,
) -> User:
    """FastAPI dependency. Use as `Depends(current_user)` on protected routes."""
    if cf_access_authenticated_user_email:
        return {"email": cf_access_authenticated_user_email}

    # No Cloudflare header → not running behind the platform → local dev.
    return {"email": "dev@local"}
