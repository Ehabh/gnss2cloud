#!/bin/bash
RAW_DIR="/data/raw"
RINEX_DIR="/data/rinex"
LOG_FILE="/data/logs/retention.log"

: "${STATION_NAME:?STATION_NAME env var not set}"
: "${REMOTE_STORAGE_1:?REMOTE_STORAGE_1 env var not set}"
: "${REMOTE_STORAGE_2:?REMOTE_STORAGE_2 env var not set}"

MIN_AGE_HOURS="${MIN_AGE_HOURS:-24}"
now_epoch=$(date -u +%s)

check_remote() {
    local remote="$1"
    local fname="$2"
    rclone lsf "$remote" --include "$fname" 2>/dev/null | grep -q "^$fname$"
}

 case "${GNSS_FORMAT:-}" in
     nov) RAW_EXT="gps" ;;
     sbf) RAW_EXT="sbf" ;;
     *)   RAW_EXT="ubx" ;;
 esac


find "$RAW_DIR" -type f -name "*.${RAW_EXT}.zst" | while read -r raw_file; do
    fname=$(basename "$raw_file")
    hour="${fname%.*}"
    hour="${hour%.*}"
    [[ "$hour" =~ ^[0-9]{10}$ ]] || continue

    year="${hour:0:4}"
    doy=$(date -u -d "${hour:0:4}-${hour:4:2}-${hour:6:2}" +"%j")

    file_epoch=$(date -u -d "${hour:0:4}-${hour:4:2}-${hour:6:2} ${hour:8:2}:00:00" +%s)
    age_hours=$(( (now_epoch - file_epoch) / 3600 ))
    if [ "$age_hours" -lt "$MIN_AGE_HOURS" ]; then
        continue
    fi

    crx_file="$RINEX_DIR/$year/$doy/${hour}.crx.gz"
    nav_file="$RINEX_DIR/$year/$doy/${hour}.nav.gz"
    all_confirmed=true

    for base_remote in "$REMOTE_STORAGE_1" "$REMOTE_STORAGE_2"; do
        remote="${base_remote}/${STATION_NAME}/${year}/${doy}"
        for f in "${hour}.${RAW_EXT}.zst" "${hour}.crx.gz" "${hour}.nav.gz"; do
            if ! check_remote "$remote" "$f"; then
                all_confirmed=false
                echo "$(date): Missing $f on $remote - will not delete $hour" >> "$LOG_FILE"
            fi
        done
    done

    if [ "$all_confirmed" = true ]; then
        rm -f "$raw_file" "$crx_file" "$nav_file"
        echo "$(date): Deleted local files for $hour (confirmed on both remotes)" >> "$LOG_FILE"
    fi
done

# Remove any YYYY/DDD folders left empty after deletion
find "$RAW_DIR" "$RINEX_DIR" -mindepth 2 -type d -empty -delete 2>/dev/null
