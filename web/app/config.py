"""
Central config for the web dashboard backend. Keep every env var
read in one place so it's obvious what this container depends on.
"""
import os

# --- Log/status API (Step 4) ---
# Fixed allowlist, not derived from client input. Keys are the names
# exposed via the REST API (e.g. /api/logs/health); values are the
# paths inside the read-only /data/logs mount. Never add an entry
# here that isn't meant to be readable by anyone who can reach this
# service.
LOG_DIR = "/data/logs"
ALLOWED_LOGS = {
    "health": os.path.join(LOG_DIR, "health.log"),
    "upload": os.path.join(LOG_DIR, "upload.log"),
    "retention": os.path.join(LOG_DIR, "retention.log"),
    "convert": os.path.join(LOG_DIR, "convert.log"),
}

# How many trailing lines to return per log by default (keeps
# responses small; the dashboard doesn't need full history).
LOG_TAIL_LINES = int(os.environ.get("WEB_LOG_TAIL_LINES", "50"))

# --- NMEA bridge (Step 5) ---
# Host/port of the filtered tcpsvr:// stream on the main container.
# Compose service name resolves via the internal Docker network —
# no IP, no credentials, nothing beyond a plain TCP connection.
NMEA_HOST = os.environ.get("NMEA_BRIDGE_HOST", "gnss2cloud")
NMEA_PORT = int(os.environ.get("NMEA_INTERNAL_PORT", "5015"))

# Sentences this service will ever parse or forward. Enforced again
# here (not just at the str2str/filter layer) as defense in depth —
# anything else received on the socket is silently dropped.
ALLOWED_NMEA_TYPES = {"GSV", "VTG", "GSA"}

# Rolling window (seconds) used to compute short-term movement from
# VTG speed samples for the dashboard's "movement" indicator.
MOVEMENT_WINDOW_SECONDS = int(os.environ.get("WEB_MOVEMENT_WINDOW_S", "60"))

# --- Auth seam (Step 6, inactive by default) ---
# No-op today. Exists so enabling real auth later is a swap-in
# inside security.py, not a rewrite of every route.
AUTH_ENABLED = os.environ.get("WEB_AUTH_ENABLED", "false").lower() == "true"

# --- Security-event log sink (Step 7, inactive by default) ---
# Separate from ALLOWED_LOGS above — this one is written by this
# container, not read from the main container's mount, and is never
# exposed via the log/status API's read endpoints.
SECURITY_LOG_PATH = os.environ.get(
    "WEB_SECURITY_LOG_PATH", "/data/web_logs/security_events.log"
)
