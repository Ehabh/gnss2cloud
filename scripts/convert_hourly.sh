#!/bin/bash
RAW_DIR="/data/raw"
RINEX_DIR="/data/rinex"
LOG_FILE="/data/logs/convert.log"

# -u is required: str2str names files by UTC, not local time
PREV_HOUR=$(date -u -d "-1 hour" +"%Y%m%d%H")

# GNSS_FORMAT is optional. When unset, this defaults to u-blox's raw
# extension and lets convbin auto-detect the format (the original,
# tested behavior). Set it to match GNSS_FORMAT in .env for non-u-blox
# receivers. See docs/receiver-setup.md.
FORMAT_ARGS=()
case "${GNSS_FORMAT:-}" in
    nov) RAW_EXT="gps"; FORMAT_ARGS=(-r nov) ;;
    sbf) RAW_EXT="sbf"; FORMAT_ARGS=(-r sbf) ;;
    *)   RAW_EXT="ubx" ;;
esac

RAW_FILE_FLAT="$RAW_DIR/${PREV_HOUR}.${RAW_EXT}"

# str2str writes flat files (kept simple/proven at capture time). This
# script reorganizes each closed hour into YYYY/DDD/ (year / day-of-year),
# matching standard GNSS/IGS station archive convention.
YEAR="${PREV_HOUR:0:4}"
DOY=$(date -u -d "${PREV_HOUR:0:4}-${PREV_HOUR:4:2}-${PREV_HOUR:6:2}" +"%j")

RAW_DEST_DIR="$RAW_DIR/$YEAR/$DOY"
RINEX_DEST_DIR="$RINEX_DIR/$YEAR/$DOY"

if [ -f "$RAW_FILE_FLAT" ]; then
    mkdir -p "$RAW_DEST_DIR" "$RINEX_DEST_DIR"
    mv "$RAW_FILE_FLAT" "$RAW_DEST_DIR/${PREV_HOUR}.${RAW_EXT}"
    RAW_FILE="$RAW_DEST_DIR/${PREV_HOUR}.${RAW_EXT}"

    convbin "$RAW_FILE" -v 3.04 "${FORMAT_ARGS[@]}" \
        -o "$RINEX_DEST_DIR/${PREV_HOUR}.obs" \
        -n "$RINEX_DEST_DIR/${PREV_HOUR}.nav" \
        -g /dev/null \
        -h /dev/null \
        -q /dev/null \
        -l /dev/null \
        -s /dev/null
        if [ $? -eq 0 ]; then
        OBS_FILE="$RINEX_DEST_DIR/${PREV_HOUR}.obs"
        NAV_FILE="$RINEX_DEST_DIR/${PREV_HOUR}.nav"
        CRX_FILE="$RINEX_DEST_DIR/${PREV_HOUR}.crx"

        # rnx2crx rejects non-standard filenames like .obs, so we use
        # filter mode (stdin/stdout) rather than passing the file directly.
        if rnx2crx - < "$OBS_FILE" > "$CRX_FILE" 2>>"$LOG_FILE"; then
            gzip -f "$CRX_FILE"
            rm -f "$OBS_FILE"
        else
            echo "$(date): FAILED to Hatanaka-compress $OBS_FILE — falling back to plain gzip" >> "$LOG_FILE"
            rm -f "$CRX_FILE"
            gzip -f "$OBS_FILE"
        fi

        gzip -f "$NAV_FILE"
        zstd -q -f --rm "$RAW_FILE"

        echo "$(date): Converted $RAW_FILE -> $RINEX_DEST_DIR/" >> "$LOG_FILE"
    else
        echo "$(date): FAILED to convert $RAW_FILE" >> "$LOG_FILE"
    fi
else
    echo "$(date): No raw file found for $PREV_HOUR" >> "$LOG_FILE"
fi
