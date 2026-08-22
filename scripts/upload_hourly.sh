#!/bin/bash
RAW_DIR="/data/raw"
RINEX_DIR="/data/rinex"
LOG_FILE="/data/logs/upload.log"

: "${STATION_NAME:?STATION_NAME env var not set}"
: "${REMOTE_STORAGE_1:?REMOTE_STORAGE_1 env var not set}"
: "${REMOTE_STORAGE_2:?REMOTE_STORAGE_2 env var not set}"

REMOTES=("${REMOTE_STORAGE_1}" "${REMOTE_STORAGE_2}")

STATE_DIR="/data/logs/upload_state"
mkdir -p "$STATE_DIR"

upload_file() {
    local file="$1"
    local remote="$2"

    if rclone copy "$file" "$remote" >> "$LOG_FILE" 2>&1; then
        echo "$(date): Uploaded $(basename "$file") to $remote" >> "$LOG_FILE"
        return 0
    else
        echo "$(date): FAILED to upload $(basename "$file") to $remote" >> "$LOG_FILE"
        return 1
    fi
}

# Self-healing sweep across both raw/ and rinex/, recursing into the
# YYYY/DDD subfolders created by convert_hourly.sh. Uploads mirror the
# same YYYY/DDD structure into the cloud bucket, e.g.
# Bucket_Name:bucket/station01/2026/216/2026080411.obs
#
# Once a file is confirmed on a given remote, a marker is written to
# STATE_DIR so future runs skip the API check entirely for that
# file+remote combo — without this, every locally-retained file (up to
# MIN_AGE_HOURS worth) gets re-checked via API every single hour,
# which can exceed provider transaction caps even in normal operation.
case "${GNSS_FORMAT:-}" in
    nov) RAW_EXT="gps" ;;
    sbf) RAW_EXT="sbf" ;;
    *)   RAW_EXT="ubx" ;;
esac
find "$RAW_DIR" "$RINEX_DIR" -type f \( -name "*.${RAW_EXT}.zst" -o -name "*.crx.gz" -o -name "*.obs.gz" -o -name "*.nav.gz" \) -mmin +5 | while read -r file; do
    fname=$(basename "$file")
    hour="${fname%.*}"
    hour="${hour%.*}"
    [[ "$hour" =~ ^[0-9]{10}$ ]] || continue

    year="${hour:0:4}"
    doy=$(date -u -d "${hour:0:4}-${hour:4:2}-${hour:6:2}" +"%j")

    for i in 1 2; do
        marker="$STATE_DIR/${fname}.r${i}.ok"
        [ -f "$marker" ] && continue

        remote_var="REMOTE_STORAGE_${i}"
        base_remote="${!remote_var}"
        remote="${base_remote}/${STATION_NAME}/${year}/${doy}/"
        exists=$(rclone lsf "$remote" --include "$fname" 2>/dev/null)
        if [ -n "$exists" ]; then
            touch "$marker"
        elif upload_file "$file" "$remote"; then
            touch "$marker"
        fi
    done
done
