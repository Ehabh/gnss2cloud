#!/bin/bash
# Report-only health check - deliberately does NOT attempt to restart
# anything itself:
#   1. A missing /dev device usually means the receiver is physically
#      disconnected - no software fix applies.
#   2. Auto-restarting on every anomaly can mask a real underlying issue
#      and, if compromised, gives an automated process standing power to
#      act - this container runs as a non-root user with no elevated
#      privileges, and this script does not change that.
# This script only writes to /data/logs/health.log. Wire up real
# notifications (e.g. ntfy.sh) by adding a curl call in the alert
# branches below.

DEVICE="/dev/${GNSS_DEVICE:-gnss0}"
RAW_DIR="/data/raw"
LOG_FILE="/data/logs/health.log"
MAX_STALE_MINUTES=15

# 1. Is the receiver connected?
if [ ! -e "$DEVICE" ]; then
    echo "$(date): ALERT - $DEVICE does not exist. Receiver appears disconnected." >> "$LOG_FILE"
    exit 1
fi

# 2. Is str2str (PID 1 in this container) actually alive?
if ! kill -0 1 2>/dev/null; then
    echo "$(date): ALERT - main process (PID 1) is not running." >> "$LOG_FILE"
    exit 1
fi

# 3. Does the running process actually hold the device open?
# (Catches "alive but stuck" - the exact failure mode found during
# testing, where str2str kept running after a disconnect/reconnect
# but silently stopped writing data.)
real_device=$(readlink -f "$DEVICE")
if ! ls -l /proc/1/fd 2>/dev/null | grep -q "$real_device"; then
    echo "$(date): ALERT - main process is running but does NOT have $real_device open. Likely lost its device handle - container restart recommended." >> "$LOG_FILE"
    exit 1
fi

# 4. Is data actually recent?
latest_file=$(find "$RAW_DIR" -name "*.ubx" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)

if [ -z "$latest_file" ] || [ -z "$(find "$latest_file" -mmin -$MAX_STALE_MINUTES)" ]; then
    echo "$(date): ALERT - Device handle open but no recent data. Latest file: $latest_file" >> "$LOG_FILE"
    exit 1
fi

echo "$(date): OK - device connected, process alive, handle open, data flowing" >> "$LOG_FILE"
