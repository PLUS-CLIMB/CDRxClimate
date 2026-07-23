#!/bin/bash
set -euo pipefail

CONFIG="${1:-./config.txt}"
get_cfg() { grep "^$1=" "$CONFIG" | cut -d'=' -f2 | xargs 2>/dev/null || echo ""; }
get_grd() { grep "^$1=" "$(get_cfg grid_file)" | cut -d'=' -f2 | xargs 2>/dev/null || echo ""; }

IN_DIR="${2:-$(get_cfg input_folder)}"
OUT_DIR="${3:-$(get_cfg output_folder)}"
LOGFILE=$(get_cfg logfile)
mkdir -p "$OUT_DIR"; LOG="$OUT_DIR/$LOGFILE"; > "$LOG"
log_msg() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG"; }

RES=$(get_grd resolution); W=$(get_grd west); S=$(get_grd south); E=$(get_grd east); N=$(get_grd north); CRS=$(get_grd crs); RSM=$(get_grd resample)
GRID_FILE=$(get_cfg cdo_grid_file)

NFILES=$(find "$IN_DIR" -name "*.nc" -type f | wc -l)
SAMPLE_FILE=$(find "$IN_DIR" -name "*.nc" -type f | head -1)
NVARS=$(cdo sinfo "$SAMPLE_FILE" 2>/dev/null | grep "Grid used" | wc -l)
[[ $NVARS -eq 0 ]] && NVARS=1
TOTAL_TASKS=$((NFILES * NVARS))
log_msg "Input: $IN_DIR | Output: $OUT_DIR | Grid: $W,$S,$E,$N @ $RES° | CRS: $CRS"
log_msg "Files: $NFILES | Total tasks: $TOTAL_TASKS"

START_TIME=$(date +%s)
TASK_COUNT=0

while IFS= read -r f; do
    fn=$(basename "$f"); yr=$(echo "$fn" | grep -oE '[0-9]{4}' | head -1 || echo 0000); mo=$(echo "$fn" | grep -oE '[0-9]{8}' | head -1 | cut -c5-6 || echo 00)
    [[ -z "$yr" ]] && yr=$(dirname "$f" | grep -oE '/(20[0-9]{2})/' | tail -1 | tr -d '/' || echo 0000)
    [[ -z "$mo" ]] && mo=$(dirname "$f" | grep -oE '/(0[1-9]|1[0-2])/' | tail -1 | tr -d '/' || echo 00)
    
    VARS=$(cdo sinfo "$f" 2>/dev/null | grep "var" | awk '{print $1}' | tr '\n' ' ')
    
    for v in $VARS; do
        TASK_COUNT=$((TASK_COUNT + 1))
        CURR_TIME=$(date +%s); ELAPSED=$((CURR_TIME - START_TIME))
        [[ $TASK_COUNT -gt 1 ]] && AVG_TIME=$((ELAPSED / (TASK_COUNT - 1))) && ETA=$(((TOTAL_TASKS - TASK_COUNT) * AVG_TIME)) || ETA=0
        
        od="$OUT_DIR/$v/$yr/$mo"; mkdir -p "$od"; of="$od/${fn}_processed.nc"
        
        cdo -f nc4 -z zip_9 -sellonlatbox,$W,$E,$S,$N -remap,"$GRID_FILE" "$f" "$of" 2>>"$LOG" && \
            log_msg "[$TASK_COUNT/$TOTAL_TASKS | ETA ${ETA}s] $fn[$v]→$v/$yr/$mo" || \
            log_msg "[$TASK_COUNT/$TOTAL_TASKS | ETA ${ETA}s] $fn[$v] [FAILED]"
    done
done < <(find "$IN_DIR" -name "*.nc" -type f)

END_TIME=$(date +%s); TOTAL_TIME=$((END_TIME - START_TIME))
log_msg "Done! Total time: ${TOTAL_TIME}s | Tasks/sec: $(echo "scale=2; $TOTAL_TASKS / $TOTAL_TIME" | bc)"
