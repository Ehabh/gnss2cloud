#!/bin/bash
RAW_DIR="/data/raw"
RINEX_DIR="/data/rinex"
LOG_FILE="/data/logs/retention.log"

: "${STATION_NAME:?STATION_NAME env var not set}"
: "${B2_REMOTE:?B2_REMOTE env var not set}"
: "${STORM_REMOTE:?STORM_REMOTE env var not set}"

BUCKET_B2="${B2_REMOTE}/${STATION_NAME}"
BUCKET_STORM="${STORM_REMOTE}/${STATION_NAME}"
MIN_AGE_HOURS="${MIN_AGE_HOURS:-24}"

now_epoch=$(date -u +%s)

check_remote() {
    local remote="$1"
    local fname="$2"
    rclone lsf "$remote/" --include "$fname" 2>/dev/null | grep -q "^$fname$"
}

for raw_file in "$RAW_DIR"/*.ubx; do
    [ -e "$raw_file" ] || continue
    fname=$(basename "$raw_file")
    hour="${fname%.ubx}"

    [[ "$hour" =~ ^[0-9]{10}$ ]] || continue

    file_epoch=$(date -u -d "${hour:0:4}-${hour:4:2}-${hour:6:2} ${hour:8:2}:00:00" +%s)
    age_hours=$(( (now_epoch - file_epoch) / 3600 ))

    if [ "$age_hours" -lt "$MIN_AGE_HOURS" ]; then
        continue
    fi

    obs_file="$RINEX_DIR/${hour}.obs"
    nav_file="$RINEX_DIR/${hour}.nav"
    all_confirmed=true

    for remote in "$BUCKET_B2" "$BUCKET_STORM"; do
        for f in "${hour}.ubx" "${hour}.obs" "${hour}.nav"; do
            if ! check_remote "$remote" "$f"; then
                all_confirmed=false
                echo "$(date): Missing $f on $remote - will not delete $hour" >> "$LOG_FILE"
            fi
        done
    done

    if [ "$all_confirmed" = true ]; then
        rm -f "$raw_file" "$obs_file" "$nav_file"
        echo "$(date): Deleted local files for $hour (confirmed on both remotes)" >> "$LOG_FILE"
    fi
done
