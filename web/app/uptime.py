"""
"Data-flowing uptime" — time since the receiver's data stream was
last interrupted, derived entirely from health.log's existing
OK/ALERT lines (health_check.sh already runs every 5 minutes).

Deliberately NOT container/process uptime (which would need the
Docker socket — a door this project keeps closed by design). A
container can be "up" while the device handle is stale; this metric
tracks the thing that actually matters operationally.
"""
import os
import re
import time
from datetime import datetime, timezone

from . import config

# Matches health_check.sh's timestamp format, e.g.:
# "Thu Aug 27 04:05:00 UTC 2026: OK - device connected, ..."
_TS_RE = re.compile(r"^(\w{3} \w{3} +\d{1,2} \d{2}:\d{2}:\d{2} UTC \d{4}):")


def _parse_timestamp(line: str) -> float | None:
    match = _TS_RE.match(line)
    if not match:
        return None
    try:
        dt = datetime.strptime(match.group(1), "%a %b %d %H:%M:%S UTC %Y")
        return dt.replace(tzinfo=timezone.utc).timestamp()
    except ValueError:
        return None


def compute_data_uptime() -> dict:
    """Returns:
    - since_epoch: unix timestamp the current streak started, or None
      if health.log is empty/unreadable.
    - seconds: how long that streak has lasted.
    - estimated: True if no ALERT was found in the visible log —
      meaning `since_epoch` is just the oldest line we could see,
      not necessarily the true start (older lines may have rotated
      out). False means since_epoch is a real, confirmed transition.
    """
    path = config.ALLOWED_LOGS.get("health")
    try:
        with open(path, "r", errors="replace") as f:
            lines = f.readlines()
    except (FileNotFoundError, TypeError):
        return {"since_epoch": None, "seconds": None, "estimated": False}

    last_alert_ts = None
    earliest_ts = None

    for line in lines:
        ts = _parse_timestamp(line)
        if ts is None:
            continue
        if earliest_ts is None:
            earliest_ts = ts
        if "ALERT" in line:
            last_alert_ts = ts  # keep overwriting -> ends up as the LAST one

    now = time.time()

    if last_alert_ts is not None:
        return {
            "since_epoch": last_alert_ts,
            "seconds": round(now - last_alert_ts),
            "estimated": False,
        }
    if earliest_ts is not None:
        # No interruption visible in the log we can see — report the
        # oldest line as a lower bound, clearly flagged as such.
        return {
            "since_epoch": earliest_ts,
            "seconds": round(now - earliest_ts),
            "estimated": True,
        }
    return {"since_epoch": None, "seconds": None, "estimated": False}


def compute_container_uptime() -> dict:
    """Main (gnss2cloud) container uptime — read from a plain text
    file the entrypoint writes once at startup, NOT from the Docker
    API. Deliberately avoids the Docker socket, which this project
    keeps out of the web container by design — a compromised
    monitoring container should never be able to query, let alone
    control, other containers.
    """
    path = os.path.join(config.LOG_DIR, "started_at")
    try:
        with open(path, "r") as f:
            started_at = float(f.read().strip())
    except (FileNotFoundError, ValueError, OSError):
        return {"since_epoch": None, "seconds": None}

    return {
        "since_epoch": started_at,
        "seconds": round(time.time() - started_at),
    }
