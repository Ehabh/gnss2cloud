#!/bin/bash
set -e
# Start the scheduler as a fully detached background session (setsid),
# with explicit stdin/stdout/stderr redirection. Without this, str2str's
# continuous \r-based status output was found to leak into supercronic's
# log stream once str2str became PID 1 via exec below, blocking job
# logging (and effectively scheduling) for up to ~45 minutes at a time.
setsid supercronic /etc/gnss2cloud.cron \
    < /dev/null >> /data/logs/supercronic.log 2>&1 &

# GNSS_FORMAT is optional. When unset, str2str auto-detects the stream
# format (this is the original, tested behavior for u-blox receivers).
# Set it to force a specific RTKLIB format token for non-u-blox
# receivers, e.g. "nov" for NovAtel OEM4/OEM6/OEM7/OEMStar, or "sbf"
# for Septentrio. See docs/receiver-setup.md.
FORMAT_SUFFIX=""
case "${GNSS_FORMAT:-}" in
    nov) RAW_EXT="gps"; FORMAT_SUFFIX="#nov" ;;
    sbf) RAW_EXT="sbf"; FORMAT_SUFFIX="#sbf" ;;
    *)   RAW_EXT="ubx" ;;
esac

# NMEA_SOURCE_MODE controls whether/how a filtered NMEA stream (GSV,
# VTG, GSA only — never GGA/RMC) is made available on
# tcpsvr://:${NMEA_INTERNAL_PORT} for the optional web dashboard's
# live position/CN0 panel. Purely additive: default (none) reproduces
# today's behavior exactly. See docs/receiver-setup.md.
#
#   none      - no NMEA output at all (default)
#   shared    - receiver puts NMEA on the SAME port as raw capture;
#               add a second -out to the existing str2str call below.
#   dedicated - receiver has a SEPARATE port/virtual-port for NMEA
#               (NMEA_DEVICE_PATH); a fully independent str2str
#               process handles it, decoupled from raw capture.
NMEA_SOURCE_MODE="${NMEA_SOURCE_MODE:-none}"
NMEA_INTERNAL_PORT="${NMEA_INTERNAL_PORT:-5015}"

EXTRA_OUT=()
case "${NMEA_SOURCE_MODE}" in
    none)
        ;;
    shared)
        # IMPORTANT: str2str duplicates the ENTIRE input stream to
        # every -out — it does not split by message type. A direct
        # `-out tcpsvr://:${NMEA_INTERNAL_PORT}` here would put the
        # full raw binary (RXM-RAWX/SFRBX, etc.) on that port
        # alongside the NMEA text, not just GSV/VTG/GSA. To keep the
        # "GSV/VTG/GSA only, nothing else on the wire" guarantee true
        # even in shared mode, str2str writes the combined stream to
        # a local FIFO instead, and a grep filter + socat relay only
        # forward lines that actually match the allowed sentences.
        # `grep -a` treats the (partly binary) FIFO content as text
        # so it doesn't abort on non-text bytes; framing right at a
        # binary/text boundary can very occasionally clip a line —
        # acceptable for a monitoring feed, unlike the raw archive.
        NMEA_FIFO="/tmp/nmea_combined.fifo"
        rm -f "${NMEA_FIFO}"
        mkfifo "${NMEA_FIFO}"

        # Reader must exist before str2str opens the FIFO for
        # writing (a FIFO write-open blocks until a reader attaches),
        # so this is started before the final exec below, same
        # ordering pattern as supercronic at the top of this file.
        (grep --line-buffered -a -E '^\$(GP|GL|GA|GB|GQ|GN)(GSV|VTG|GSA),' \
            < "${NMEA_FIFO}" \
            | socat -u - "TCP-LISTEN:${NMEA_INTERNAL_PORT},fork,reuseaddr") \
            < /dev/null >> /data/logs/nmea_filter.log 2>&1 &

        EXTRA_OUT=(-out "file://${NMEA_FIFO}")
        ;;
    dedicated)
        if [ -z "${NMEA_DEVICE_PATH:-}" ]; then
            echo "NMEA_SOURCE_MODE=dedicated requires NMEA_DEVICE_PATH to be set. Exiting." >&2
            exit 1
        fi
        # Separate physical port already carries NMEA only (nothing
        # else was ever enabled on it — see docs/receiver-setup.md),
        # so no filtering relay is needed here: this stream never
        # contains raw binary observables to begin with.
        str2str -in "serial://${NMEA_DEVICE_PATH}:${NMEA_BAUD:-9600}" \
            -out "tcpsvr://:${NMEA_INTERNAL_PORT}" \
            < /dev/null >> /data/logs/nmea_stream.log 2>&1 &
        ;;
    *)
        echo "Unknown NMEA_SOURCE_MODE='${NMEA_SOURCE_MODE}' (expected none|shared|dedicated). Exiting." >&2
        exit 1
        ;;
esac

date +%s > /data/logs/started_at

# str2str becomes the container's main (PID 1) process. If it exits,
# Docker's restart policy (set in docker-compose.yml) brings it back.
exec str2str -in "serial://${GNSS_DEVICE}:${GNSS_BAUD}${FORMAT_SUFFIX}" \
    -out "file:///data/raw/%Y%m%d%h.${RAW_EXT}::S=1" \
    "${EXTRA_OUT[@]}"
