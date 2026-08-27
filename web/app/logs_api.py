"""
Read-only REST endpoints for the operational logs the main container
already produces. Fixed allowlist only (config.ALLOWED_LOGS) — no
filename or path ever comes from the client, so there's no path-
traversal surface here regardless of what a request contains.
"""
from fastapi import APIRouter, HTTPException

from . import config

router = APIRouter(prefix="/api/logs", tags=["logs"])


def _tail(path: str, n: int) -> list[str]:
    """Return the last n lines of a file, or [] if it doesn't exist
    yet (e.g. retention.log before the first cycle has ever run —
    that's a normal state, not an error)."""
    try:
        with open(path, "r", errors="replace") as f:
            lines = f.readlines()
    except FileNotFoundError:
        return []
    return [line.rstrip("\n") for line in lines[-n:]]


@router.get("/")
def list_available_logs():
    """What log names exist, so the frontend doesn't hardcode them."""
    return {"available": sorted(config.ALLOWED_LOGS.keys())}


@router.get("/{name}")
def get_log(name: str, lines: int = config.LOG_TAIL_LINES):
    if name not in config.ALLOWED_LOGS:
        # Deliberately vague — don't confirm/deny internal path
        # structure beyond the known-safe allowlist names.
        raise HTTPException(status_code=404, detail="Unknown log name")

    lines = max(1, min(lines, 1000))  # bound the request, both directions
    path = config.ALLOWED_LOGS[name]
    return {"name": name, "lines": _tail(path, lines)}
