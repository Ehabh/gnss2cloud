#!/bin/bash
RAW_DIR="/data/raw"
RINEX_DIR="/data/rinex"
LOG_FILE="/data/logs/retention.log"

: "${STATION_NAME:?STATION_NAME env var not set}"
: "${REMOTE_STORAGE_1:?REMOTE_STORAGE_1 env var not set}"
: "${REMOTE_STORAGE_2:?REMOTE_STORAGE_2 env var not set}"

MIN_AGE_HOURS="${MIN_AGE_HOURS:-24}"
now_epoch=$(date -u +%s)

STATE_DIR="/data/logs/upload_state"

is_confirmed() {
    local fname="$1"
    [ -f "$STATE_DIR/${fname}.r1.ok" ] && [ -f "$STATE_DIR/${fname}.r2.ok" ]
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
    obs_fallback_file="$RINEX_DIR/$year/$doy/${hour}.obs.gz"
    nav_file="$RINEX_DIR/$year/$doy/${hour}.nav.gz"
    all_confirmed=true

    if [ -f "$crx_file" ]; then
        obs_variant="$crx_file"
        obs_variant_name="${hour}.crx.gz"
    elif [ -f "$obs_fallback_file" ]; then
        obs_variant="$obs_fallback_file"
        obs_variant_name="${hour}.obs.gz"
    else
        obs_variant=""
        obs_variant_name=""
        echo "$(date): No .crx.gz or .obs.gz found locally for $hour - skipping" >> "$LOG_FILE"
    fi

    for f in "${hour}.${RAW_EXT}.zst" "${obs_variant_name}" "${hour}.nav.gz"; do
        [ -z "$f" ] && { all_confirmed=false; continue; }
        if ! is_confirmed "$f"; then
            all_confirmed=false
            echo "$(date): $f not yet confirmed on both remotes - will not delete $hour" >> "$LOG_FILE"
        fi
    done

    if [ "$all_confirmed" = true ]; then
        rm -f "$raw_file" "$obs_variant" "$nav_file"
        rm -f "$STATE_DIR/${hour}.${RAW_EXT}.zst".r1.ok "$STATE_DIR/${hour}.${RAW_EXT}.zst".r2.ok
        rm -f "$STATE_DIR/${obs_variant_name}".r1.ok "$STATE_DIR/${obs_variant_name}".r2.ok
        rm -f "$STATE_DIR/${hour}.nav.gz".r1.ok "$STATE_DIR/${hour}.nav.gz".r2.ok
        echo "$(date): Deleted local files for $hour (confirmed on both remotes)" >> "$LOG_FILE"
    fi
done

# Remove any YYYY/DDD folders left empty after deletion
find "$RAW_DIR" "$RINEX_DIR" -mindepth 2 -type d -empty -delete 2>/dev/null
