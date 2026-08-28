"""
Web dashboard backend entrypoint. Wires together:
- Read-only log/status REST API (logs_api.py)
- NMEA bridge background task + WebSocket feed (nmea_bridge.py)
- Auth seam, applied to every route even though inactive today (security.py)

Read-only by design: this service never writes to the main
container's data, never touches .env/rclone.conf/Docker socket, and
has no endpoints that modify anything on the main container.
"""
import asyncio
import logging

from fastapi import Depends, FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from . import config, nmea_bridge, uptime
from .logs_api import router as logs_router
from .security import require_auth

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("gnss2cloud-web")

app = FastAPI(title="gnss2cloud dashboard (monitoring only)")

# Same-origin only by default — no CORS middleware added. If the
# frontend is ever served from a different origin, add an explicit
# allowlist here rather than wildcarding.

app.include_router(logs_router, dependencies=[Depends(require_auth)])
# Dashboard static assets (single-file HTML/JS, no build step). Mounted
# under /static rather than at "/" so it never shadows the API routes
# below. Not gated by require_auth: the HTML/JS itself contains no
# data — it only becomes useful once it calls the (already-gated)
# REST/WebSocket endpoints, so serving the file itself is harmless
# even if WEB_AUTH_ENABLED is ever turned on.
app.mount("/static", StaticFiles(directory="app/static"), name="static")


@app.get("/")
async def dashboard():
    return FileResponse("app/static/index.html")


@app.on_event("startup")
async def start_background_tasks():
    # Runs for the lifetime of the container; reconnects internally
    # on stream drops (see nmea_bridge.run_bridge). A failure here
    # should never prevent the REST API from serving log/status data.
    app.state.bridge_task = asyncio.create_task(nmea_bridge.run_bridge())
    logger.info(
        "NMEA bridge started (target=%s:%s)",
        config.NMEA_HOST,
        config.NMEA_PORT,
    )


@app.on_event("shutdown")
async def stop_background_tasks():
    # Without this, container stop/restart leaves run_bridge()'s task
    # dangling — harmless in practice (the process is exiting anyway)
    # but asyncio logs "Task was destroyed but it is pending!" on
    # every restart, which is noise worth eliminating rather than
    # learning to ignore.
    task = getattr(app.state, "bridge_task", None)
    if task:
        task.cancel()
        try:
            await task
        except asyncio.CancelledError:
            pass


@app.get("/api/status")
async def status(_: str = Depends(require_auth)):
    """Cheap liveness/identity endpoint for the dashboard itself —
    not the GNSS station's health (that's /api/logs/health).
    data_uptime is derived from health.log, not container uptime —
    see uptime.py for why."""
    return {
        "service": "gnss2cloud-web",
        "auth_enabled": config.AUTH_ENABLED,
        "data_uptime": uptime.compute_data_uptime(),
    }


@app.get("/api/nmea/current")
async def nmea_current(_: str = Depends(require_auth)):
    """Polling fallback for clients that don't use the WebSocket."""
    return nmea_bridge.get_current_state()


@app.websocket("/ws/nmea")
async def nmea_ws(websocket: WebSocket):
    # NOTE: auth seam is not yet wired into the WebSocket handshake —
    # FastAPI's Depends() on HTTP routes doesn't apply the same way
    # to WebSocket accept(). Flagged here deliberately rather than
    # silently skipped: when WEB_AUTH_ENABLED work happens (Step 6),
    # this endpoint needs its own explicit check before accept(),
    # not just relying on the REST routes being covered.
    if config.AUTH_ENABLED:
        await websocket.close(code=1011)
        return

    await websocket.accept()
    nmea_bridge.register_client(websocket)
    try:
        while True:
            # This endpoint is server-push only; we don't expect
            # client messages, but need to await something to detect
            # disconnects promptly.
            await websocket.receive_text()
    except WebSocketDisconnect:
        pass
    finally:
        nmea_bridge.unregister_client(websocket)
