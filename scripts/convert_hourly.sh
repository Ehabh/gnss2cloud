#!/bin/bash
RAW_DIR="/data/raw"
RINEX_DIR="/data/rinex"
LOG_FILE="/data/logs/convert.log"

# -u is required: str2str names files by UTC, not local time
PREV_HOUR=$(date -u -d "-1 hour" +"%Y%m%d%H")
RAW_FILE_FLAT="$RAW_DIR/${PREV_HOUR}.ubx"

# str2str writes flat files (kept simple/proven at capture time). This
# script reorganizes each closed hour into YYYY/DDD/ (year / day-of-year),
# matching standard GNSS/IGS station archive convention.
YEAR="${PREV_HOUR:0:4}"
DOY=$(date -u -d "${PREV_HOUR:0:4}-${PREV_HOUR:4:2}-${PREV_HOUR:6:2}" +"%j")

RAW_DEST_DIR="$RAW_DIR/$YEAR/$DOY"
RINEX_DEST_DIR="$RINEX_DIR/$YEAR/$DOY"

if [ -f "$RAW_FILE_FLAT" ]; then
    mkdir -p "$RAW_DEST_DIR" "$RINEX_DEST_DIR"
    mv "$RAW_FILE_FLAT" "$RAW_DEST_DIR/${PREV_HOUR}.ubx"
    RAW_FILE="$RAW_DEST_DIR/${PREV_HOUR}.ubx"

    convbin "$RAW_FILE" -v 3.04 \
        -o "$RINEX_DEST_DIR/${PREV_HOUR}.obs" \
        -n "$RINEX_DEST_DIR/${PREV_HOUR}.nav" \
        -g /dev/null \
        -h /dev/null \
        -q /dev/null \
        -l /dev/null \
        -s /dev/null
    if [ $? -eq 0 ]; then
        echo "$(date): Converted $RAW_FILE -> $RINEX_DEST_DIR/" >> "$LOG_FILE"
    else
        echo "$(date): FAILED to convert $RAW_FILE" >> "$LOG_FILE"
    fi
else
    echo "$(date): No raw file found for $PREV_HOUR" >> "$LOG_FILE"
fi
