#!/bin/bash
RAW_DIR="/data/raw"
RINEX_DIR="/data/rinex"
LOG_FILE="/data/logs/convert.log"

# -u is required: str2str names files by UTC, not local time
PREV_HOUR=$(date -u -d "-1 hour" +"%Y%m%d%H")
RAW_FILE="$RAW_DIR/${PREV_HOUR}.ubx"

if [ -f "$RAW_FILE" ]; then
    convbin "$RAW_FILE" -v 3.04 \
        -o "$RINEX_DIR/${PREV_HOUR}.obs" \
        -n "$RINEX_DIR/${PREV_HOUR}.nav" \
        -g /dev/null \
        -h /dev/null \
        -q /dev/null \
        -l /dev/null \
        -s /dev/null
    if [ $? -eq 0 ]; then
        echo "$(date): Converted $RAW_FILE" >> "$LOG_FILE"
    else
        echo "$(date): FAILED to convert $RAW_FILE" >> "$LOG_FILE"
    fi
else
    echo "$(date): No raw file found for $PREV_HOUR" >> "$LOG_FILE"
fi
