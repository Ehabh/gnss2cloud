#!/bin/bash
RAW_DIR="/data/raw"
RINEX_DIR="/data/rinex"
LOG_FILE="/data/logs/upload.log"

: "${STATION_NAME:?STATION_NAME env var not set}"
: "${REMOTE_STORAGE_1:?REMOTE_STORAGE_1 env var not set}"
: "${REMOTE_STORAGE_2:?REMOTE_STORAGE_2 env var not set}"

REMOTES=("${REMOTE_STORAGE_1}" "${REMOTE_STORAGE_2}")

upload_file() {
    local file="$1"
    local remote="$2"

    rclone copy "$file" "$remote" >> "$LOG_FILE" 2>&1
    if [ $? -eq 0 ]; then
        echo "$(date): Uploaded $(basename "$file") to $remote" >> "$LOG_FILE"
    else
        echo "$(date): FAILED to upload $(basename "$file") to $remote" >> "$LOG_FILE"
    fi
}

# Self-healing sweep across both raw/ and rinex/, recursing into the
# YYYY/DDD subfolders created by convert_hourly.sh. Uploads mirror the
# same YYYY/DDD structure into the cloud bucket, e.g.
# b2:bucket/station01/2026/216/2026080411.obs
find "$RAW_DIR" "$RINEX_DIR" -type f \( -name "*.ubx" -o -name "*.obs" -o -name "*.nav" \) -mmin +5 | while read -r file; do
    fname=$(basename "$file")
    hour="${fname%.*}"
    [[ "$hour" =~ ^[0-9]{10}$ ]] || continue

    year="${hour:0:4}"
    doy=$(date -u -d "${hour:0:4}-${hour:4:2}-${hour:6:2}" +"%j")

    for base_remote in "${REMOTES[@]}"; do
        remote="${base_remote}/${STATION_NAME}/${year}/${doy}/"
        exists=$(rclone lsf "$remote" --include "$fname" 2>/dev/null)
        if [ -z "$exists" ]; then
            upload_file "$file" "$remote"
        fi
    done
done
