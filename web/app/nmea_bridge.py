"""
TCP client for the filtered NMEA stream (GSV/VTG/GSA only) exposed by
the main container. Parses, aggregates, and re-broadcasts as JSON
over WebSocket. Never touches position — GGA/RMC are never on this
stream in the first place (enforced upstream), and anything unexpected
that does arrive is dropped here too, on principle.
"""
import asyncio
import json
import time
from collections import deque

import pynmea2

from . import config

# Satellites seen in the GSV cycle currently being assembled, keyed
# by (talker, prn) so multiple constellations don't collide.
# Tracked per-talker so one constellation's completed sequence never
# wipes another's still-in-progress or already-published data.
_gsv_in_progress: dict[str, dict[str, dict]] = {}  # talker -> {prn: data}
_last_satellites: dict[str, dict] = {}             # "{talker}-{prn}" -> data

# Rolling (timestamp, speed_kmph) samples for the movement window.
_speed_samples: deque[tuple[float, float]] = deque()

_last_fix_quality: dict = {}
_websocket_clients: set = set()


def _sentence_type(msg) -> str | None:
    # pynmea2 sentence_type is e.g. "GSV", "VTG", "GSA" regardless
    # of talker prefix (GP/GL/GA/GB/GQ/GN).
    return getattr(msg, "sentence_type", None)


def _handle_gsv(msg):
    talker = msg.talker
    total_msgs = int(msg.num_messages)
    msg_num = int(msg.msg_num)

    bucket = _gsv_in_progress.setdefault(talker, {})

    for i in range(1, 5):
        prn = getattr(msg, f"sv_prn_num_{i}", None)
        snr = getattr(msg, f"snr_{i}", None)
        elevation = getattr(msg, f"elevation_deg_{i}", None)
        azimuth = getattr(msg, f"azimuth_{i}", None)

        # Skip unused slots. Some receivers leave these blank,
        # others mark them with a literal "0" PRN — treat both as
        # empty, and additionally skip anything with no real data
        # at all as a safety net against other placeholder schemes.
        if not prn or prn == "0":
            continue
        if elevation is None and azimuth is None and snr is None:
            continue

        bucket[prn] = {
            "prn": prn,
            "talker": talker,
            "elevation": _to_num(elevation),
            "azimuth": _to_num(azimuth),
            "cn0": _to_num(snr),
        }

    # Only this talker's sequence is complete — merge just its
    # satellites into the published snapshot, leaving every other
    # constellation's already-published entries untouched.
    if msg_num == total_msgs:
        for prn, data in bucket.items():
            _last_satellites[f"{talker}-{prn}"] = data
        _gsv_in_progress[talker] = {}


def _handle_vtg(msg):
    speed_kmph = _to_num(msg.spd_over_grnd_kmph)
    if speed_kmph is None:
        return
    now = time.time()
    _speed_samples.append((now, speed_kmph))
    cutoff = now - config.MOVEMENT_WINDOW_SECONDS
    while _speed_samples and _speed_samples[0][0] < cutoff:
        _speed_samples.popleft()


def _handle_gsa(msg):
    global _last_fix_quality
    _last_fix_quality = {
        "fix_type": msg.mode_fix_type,  # 1=no fix, 2=2D, 3=3D
        "pdop": _to_num(msg.pdop),
        "hdop": _to_num(msg.hdop),
        "vdop": _to_num(msg.vdop),
    }


def _to_num(v):
    try:
        return float(v) if v not in (None, "") else None
    except (TypeError, ValueError):
        return None


def _current_state() -> dict:
    speeds = [s for _, s in _speed_samples]
    avg_speed = sum(speeds) / len(speeds) if speeds else 0.0
    # Noise-floor note (flagged earlier): a stationary receiver shows
    # small nonzero speed from Doppler noise. Surface the raw value;
    # let the frontend apply the "essentially stationary" threshold
    # so it stays a display concern, not a data-dropping one here.
    return {
        "satellites": list(_last_satellites.values()),
        "movement": {
            "avg_speed_kmph": round(avg_speed, 2),
            "window_seconds": config.MOVEMENT_WINDOW_SECONDS,
            "sample_count": len(speeds),
        },
        "fix_quality": _last_fix_quality,
        "updated_at": time.time(),
    }


async def _broadcast():
    if not _websocket_clients:
        return
    payload = json.dumps(_current_state())
    dead = set()
    for ws in _websocket_clients:
        try:
            await ws.send_text(payload)
        except Exception:
            dead.add(ws)
    _websocket_clients.difference_update(dead)


async def run_bridge():
    """Long-running task: connect, read, parse, broadcast, reconnect
    on failure. Never raises out of this loop — a stream hiccup
    should never take down the rest of the backend."""
    backoff = 1
    while True:
        try:
            reader, writer = await asyncio.open_connection(
                config.NMEA_HOST, config.NMEA_PORT
            )
            backoff = 1  # reset on successful connect
            while True:
                raw = await reader.readline()
                if not raw:
                    break  # connection closed by the other end
                line = raw.decode("ascii", errors="ignore").strip()
                if not line.startswith("$"):
                    continue
                try:
                    msg = pynmea2.parse(line)
                except pynmea2.ParseError:
                    continue

                sentence = _sentence_type(msg)
                if sentence not in config.ALLOWED_NMEA_TYPES:
                    continue  # defense in depth, per design

                if sentence == "GSV":
                    _handle_gsv(msg)
                elif sentence == "VTG":
                    _handle_vtg(msg)
                    await _broadcast()
                elif sentence == "GSA":
                    _handle_gsa(msg)

        except (ConnectionRefusedError, OSError):
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, 30)


def register_client(ws):
    _websocket_clients.add(ws)


def unregister_client(ws):
    _websocket_clients.discard(ws)


def get_current_state() -> dict:
    return _current_state()
