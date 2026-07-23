#!/bin/bash
#ndvi_img_nc.sh - Convert NDVI .img files to NetCDF with metadata (CF-compliant 1.8)
# Pipelines:
# 1. gdal_translate to convert .img to .nc with scaling and nodata
# 2. Python script to add CF-compliant metadata and attributes
# Usage: ./ndvi_img_nc.sh -c ndvi_config.sh # .ndvi_img_nc.sh --help
# Usage: ./ndvi_img_nc.sh -i <input_file_or_dir> -o <output_dir> -m <metadata_script.py> [--overwrite]

set -euo pipefail
# usage
usage() {
    cat <<USAGE
Usage: $0 -i <input_file_or_dir> -o <output_dir> -m <metadata_script.py> [--overwrite]
Options:
  -i, --input       Input .img file or directory containing .img files
  -o, --output      Output directory for .nc files
  -m, --metadata    Python script to add metadata (must accept --input and --output)
  --overwrite       Overwrite existing .nc files (default: skip)
  --parallel        Number of parallel jobs to run (default: 1)
  --dry-run         Show what would be done without actually doing it
Example:
  $0 -i /data/ndvi_imgs -o /data/ndvi_nc -m ./add_metadata.py --overwrite
USAGE
    exit 0
}

CONFIG_FILE=""
INPUT_PATH=""
OUTPUT_DIR=""
PYTHON_MD_SCRIPT=""
OVERWRITE=0
PARALLEL_JOBS=1
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config) CONFIG_FILE="$2"; shift 2 ;;
        -i|--input) INPUT_PATH="$2"; shift 2 ;;
        -o|--output) OUTPUT_DIR="$2"; shift 2 ;;
        -m|--metadata) PYTHON_MD_SCRIPT="$2"; shift 2 ;;
        --overwrite) OVERWRITE=1; shift ;;
        --parallel) PARALLEL_JOBS="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

# Optional config file
if [[ -n "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi

INPUT_PATH="${INPUT_PATH:-${INPUT_DIR:-}}"
OUTPUT_DIR="${OUTPUT_DIR:-${OUT_DIR:-}}"
PYTHON_MD_SCRIPT="${PYTHON_MD_SCRIPT:-${METADATA_SCRIPT:-./metadata.py}}"
OVERWRITE="${OVERWRITE:-0}"
PARALLEL_JOBS="${PARALLEL_JOBS:-1}"
DRY_RUN="${DRY_RUN:-0}"

[[ -n "$INPUT_PATH" ]] || { echo "ERROR: input missing"; exit 1; }
[[ -n "$OUTPUT_DIR" ]] || { echo "ERROR: output missing"; exit 1; }
[[ -e "$INPUT_PATH" ]] || { echo "ERROR: Input does not exist: $INPUT_PATH" | tee -a "$LOG_FILE"; exit 1; }
[[ -f "$PYTHON_MD_SCRIPT" ]] || { echo "ERROR: Metadata script not found: $PYTHON_MD_SCRIPT" | tee -a "$LOG_FILE"; exit 1; }


mkdir -p "$OUTPUT_DIR"
LOG_FILE="$OUTPUT_DIR/processing.log"
TMP_DIR="$OUTPUT_DIR/tmp_nc"
mkdir -p "$TMP_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

echo "Starting NDVI processing" | tee "$LOG_FILE"
echo "Input:  $INPUT_PATH" | tee -a "$LOG_FILE"
echo "Output: $OUTPUT_DIR" | tee -a "$LOG_FILE"
echo "Metadata script: $PYTHON_MD_SCRIPT" | tee -a "$LOG_FILE"
echo "Overwrite existing: $OVERWRITE" | tee -a "$LOG_FILE"
echo "Parallel jobs: $PARALLEL_JOBS" | tee -a "$LOG_FILE"

if command -v conda &> /dev/null; then
    eval "$(conda shell.bash hook)"
    conda activate gdal-env
else
    echo "WARNING: Conda not found, ensure GDAL is available in PATH" | tee -a "$LOG_FILE"
fi
# Valid dekad day-of-month tokens are 01, 11, 21 (for dekads 1, 2, 3 respectively)
get_valid_date_token() {
    local date_token
    date_token="$(basename "$1" | grep -oE '[0-9]{8}' | head -n1 || true)"
    [[ -z "$date_token" ]] && return 1

    case "${date_token:6:2}" in
        01|11|21)
            printf '%s\n' "$date_token"; return 0 ;;
        *)  return 1 ;;
    esac
}
declare -a valid_files valid_dates

if [[ -f "$INPUT_PATH" ]]; then
    mapfile -t raw_files < <(echo "$INPUT_PATH")
elif [[ -d "$INPUT_PATH" ]]; then
    mapfile -d '' raw_files < <(find "$INPUT_PATH" -type f -name "*_NDV.img" -print0 | sort -z)
else
    echo "ERROR: Input must be a file or directory: $INPUT_PATH" | tee -a "$LOG_FILE"; exit 1
fi

for f in "${raw_files[@]}"; do
    if dt="$(get_valid_date_token "$f")"; then
        valid_files+=("$f")
        valid_dates+=("$dt")
    else
        echo "SKIP: No valid date token found in $f" | tee -a "$LOG_FILE"
    fi
done

total=${#valid_files[@]}

echo "Valid NDVI dekad files found: $total" | tee -a "$LOG_FILE"
if [[ $DRY_RUN -eq 1 ]]; then
    echo "Dry run mode: no files will be processed" | tee -a "$LOG_FILE"
    printf "Example output filename: %s/ndvi_%s.nc\n" "$OUTPUT_DIR" "${valid_dates[@]}" | tee -a "$LOG_FILE"
    exit 0
fi

# per file worker
process_one(){
    local file="$1" date_token="$2"
    local idx="$3" local t0; t0=$(date +%s)
    local subdir="$OUTPUT_DIR/${date_token:0:4}/${date_token:4:2}"
    local output_file="$subdir/ndvi_${date_token}.nc" local tmp_file="$TMP_DIR/ndvi_${date_token}_raw.nc"
    mkdir -p "$subdir"
    if [[ -f "$output_file" && "$OVERWRITE" -ne 1 ]]; then
        echo "SKIP ($idx/$total): $output_file already exists" | tee -a "$LOG_FILE"         
        return 0
    fi
    echo "Processing ($idx/$total): $file" | tee -a "$LOG_FILE"
    if ! gdal_translate \
        -of netCDF \
        -ot Float32 \
        -scale 0 250 -1.0 1.0 \
        -a_nodata -9999 \
        "$file" "$tmp_file" >> "$LOG_FILE" 2>&1; then
        echo "ERROR($idx/$total): GDAL conversion failed for $date_token" | tee -a "$LOG_FILE"
        rm -f "$tmp_file"
        echo "FAIL"; return 0
    fi

    # step 2: add metadata with Python script
    local md_args=(--input "$tmp_file" --output "$output_file")
    [[ "$OVERWRITE" -eq 1 ]] && md_args+=(--overwrite)

    if ! python3 "$PYTHON_MD_SCRIPT" "${md_args[@]}" >> "$LOG_FILE" 2>&1; then
        echo "ERROR($idx/$total): Metadata writing failed for $date_token" | tee -a "$LOG_FILE"
        rm -f "$tmp_file" "$output_file"
        echo "FAIL"; return 0
    fi
    rm -f "$tmp_file"
    echo "OK ($idx/$total): ndvi_${date_token}.nc created in $(( $(date +%s) - t0 )) seconds" | tee -a "$LOG_FILE"
   
}

export -f process_one
export OUTPUT_DIR PYTHON_MD_SCRIPT OVERWRITE LOG_FILE TMP_DIR total

START_TIME=$(date +%s)
ok=0; fail=0; skipped=0; count=0

parse_results() {
    case "$1" in
        OK) ((ok++)) ;;
        FAIL) ((fail++)) ;;
        SKIP) ((skipped++)) ;;
    esac
    count=$((count + 1))
}

if [[ $PARALLEL_JOBS -gt 1 ]] && command -v parallel &> /dev/null; then
    log "Running in parallel mode with $PARALLEL_JOBS jobs"
    args_file="$TMP_DIR/args.txt"
    for idx in "${!valid_files[@]}"; do
        echo -e "${valid_files[idx]}\t${valid_dates[idx]}\t$((idx + 1))" 
    done > "$args_file"
    while IFS=read -r result; do
        parse_results "$result"
    done < <(parallel --colsep '\t' -j "$PARALLEL_JOBS" process_one {1} {2} {3} :::: "$args_file")
else
    [[ $PARALLEL_JOBS -gt 1 ]] && log "GNU parallel not found, running sequentially"
    for idx in "${!valid_files[@]}"; do
        count=$((count + 1))
        result=$(process_one "${valid_files[idx]}" "${valid_dates[idx]}" "$((idx + 1))")
        parse_results "$(echo "$result" | awk '{print $1}')"
    done
fi

ELAPSED=$(( $(date +%s) - START_TIME ))
log "Processing complete: $ok OK, $fail FAIL, $skipped SKIP in $((ELAPSED / 3600))h $((ELAPSED % 3600 / 60))m $((ELAPSED % 60))s"
if [[ $fail -ne 0 ]]; then
    log "Some files failed to process. Check $LOG_FILE for details."
    exit 1
fi
