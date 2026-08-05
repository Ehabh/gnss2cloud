#!/bin/bash
RAW_DIR="/data/raw"
RINEX_DIR="/data/rinex"
LOG_FILE="/data/logs/upload.log"

# Set these in docker-compose.yml / .env - see .env.example
: "${STATION_NAME:?STATION_NAME env var not set}"
: "${B2_REMOTE:?B2_REMOTE env var not set}"      # e.g. b2:your-bucket
: "${STORM_REMOTE:?STORM_REMOTE env var not set}" # e.g. storm:your-bucket

REMOTES=("${B2_REMOTE}/${STATION_NAME}/" "${STORM_REMOTE}/${STATION_NAME}/")

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

# Self-healing sweep: checks every local raw/rinex file against both
# remotes and uploads anything missing. A failure this run gets retried
# automatically next run - no separate retry logic needed.
for file in "$RAW_DIR"/*.ubx "$RINEX_DIR"/*.obs "$RINEX_DIR"/*.nav; do
    [ -e "$file" ] || continue

    fname=$(basename "$file")
    hour="${fname%.*}"
    [[ "$hour" =~ ^[0-9]{10}$ ]] || continue

    # skip files modified in the last 5 minutes (still being written)
    if [ "$(find "$file" -mmin -5)" ]; then
        continue
    fi

    for remote in "${REMOTES[@]}"; do
        exists=$(rclone lsf "$remote" --include "$fname" 2>/dev/null)
        if [ -z "$exists" ]; then
            upload_file "$file" "$remote"
        fi
    done
done
