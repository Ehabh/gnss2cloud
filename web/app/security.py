"""
Auth seam for the web dashboard. Inactive by default (WEB_AUTH_ENABLED
unset/false) — every request is allowed through, but every route
already depends on this function, so turning on real authentication
later means replacing what happens INSIDE _check_auth, not adding
auth checks to every route one by one.

Nothing here should be treated as "real" security yet. It's a
placeholder with the right shape, not a working login system.
"""
from fastapi import Request, HTTPException

from . import config


async def require_auth(request: Request) -> str:
    """FastAPI dependency. Returns an identity string for the caller.
    Today: always "anonymous", auth disabled. Once WEB_AUTH_ENABLED
    is wired to a real mechanism, this becomes the one place that
    changes — validate a session/token, raise 401 on failure, return
    the real account identifier on success.
    """
    if not config.AUTH_ENABLED:
        return "anonymous"

    # Placeholder failure mode for when AUTH_ENABLED is flipped on
    # before real auth logic is implemented here — fail closed
    # rather than silently pretending to be secure.
    raise HTTPException(
        status_code=501,
        detail="WEB_AUTH_ENABLED is set, but no auth mechanism is implemented yet.",
    )
