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

# str2str becomes the container's main (PID 1) process. If it exits,
# Docker's restart policy (set in docker-compose.yml) brings it back.
exec str2str -in "serial://${GNSS_DEVICE}:${GNSS_BAUD}${FORMAT_SUFFIX}" \
    -out "file:///data/raw/%Y%m%d%h.${RAW_EXT}::S=1"
