#!/usr/bin/env bash
set -euo pipefail

# Multi-format Preprocessing Script
# Supports: daily (YYYY/MM/DD structure), monthly (YYYY/MM structure), sm (YYYY flat structure)
# 
# Usage: pre-processing.sh <input_folder> [daily|monthly|sm] [output_base_folder]
# Defaults to daily mode.
#
# Modes:
#   daily   - Dense daily data in YYYY/MM/DD/ folders (LST, ERA5, etc.)
#   monthly - Monthly data in YYYY/MM/ folders
#   sm      - Soil Moisture: daily files in YYYY/ folder (all days per year in one folder)
#
# Environment variables (user-configurable):
#   VERBOSE=1   -> print per-file progress (default: quiet)
#   PARALLEL=N  -> number of parallel workers (default: number of CPUs)
#
#   RES_X, RES_Y           -> target resolution in degrees for gdalwarp -tr (defaults: 0.1, 0.1)
#   TE_W, TE_S, TE_E, TE_N -> target extent for gdalwarp -te (defaults: -18.0 10.0 40.0 20.0)
#   OUT_FORMAT             -> GDAL output format (default: NetCDF)
#   RESAMPLE_METHOD        -> Resampling method (default: nearest; options: nearest, bilinear, cubic, mode, average)
#   NODATA                 -> NoData value to preserve (default: nan)

# User-configurable defaults (can be overridden by exporting env vars before run)
RES_X="${RES_X:-0.1}"
RES_Y="${RES_Y:-0.1}"
TE_W="${TE_W:--18.0}"
TE_S="${TE_S:-10.0}"
TE_E="${TE_E:-40.0}"
TE_N="${TE_N:-20.0}"
OUT_FORMAT="${OUT_FORMAT:-NetCDF}"
RESAMPLE_METHOD="${RESAMPLE_METHOD:-nearest}"  # nearest, bilinear, cubic, mode, average
NODATA="${NODATA:-nan}"  # preserve NaN values (or specify numeric value)
OUTFOLDER="${OUTFOLDER:-}"  # Output folder basename (e.g., 'evpt', 'lst_daily', 'sm')

process_file() {
    file="$1"

    # Extract date from filename
    # Handles formats like:
    #   h141_2010010100_R01.nc          (SM: YYYYMMDDHH)
    #   era5_land_2m_temperature_2010_01.nc (ERA5: YYYY_MM)
    #   sm_20100101.nc                  (SM: YYYYMMDD)
    #   METOP_AVHRR_20100101_S10_AFR_ndvi_psdc.nc (NDVI: YYYYMMDD)
    
    base_name="$( basename "$file" )"
    name_no_ext="${base_name%.*}"
    
    # Try to extract 8+ digit date (YYYYMMDD or YYYYMMDDHH)
    # First look for pattern like h141_<digits>_ (captures date between underscores)
    dt="$( printf '%s' "$base_name" | grep -oE '_[0-9]{8,10}_' | tr -d '_' || true )"
    
    # If not found, try trailing digits (e.g., sm_20100101.nc or ..._20100102)
    if [ -z "$dt" ]; then
        dt_raw="$( printf '%s' "$name_no_ext" | grep -oE '[0-9_]+$' || true )"
        dt="$( printf '%s' "$dt_raw" | tr -d '_' )"
    fi
    
    # Fallback to field-based extraction if we couldn't find a date
    if [ -z "$dt" ]; then
        dt="$( basename "$file" | awk -F_ '{ print $6 }' 2>/dev/null || true )"
        dt="${dt%.*}"
    fi
    
    if [ -z "$dt" ]; then
        [ "$VERBOSE" = "1" ] && echo "Skipping: $file (could not extract date)" >&2
        return 0
    fi

    # Extract YYYYMMDD (ignore hour if present)
    # For YYYYMMDDHH format, take first 8 chars; for YYYYMMDD, take all 8
    dt="${dt:0:8}"
    
    # If monthly mode, only consider YYYYMM (ignore day)
    if [ "${MODE:-daily}" = "monthly" ]; then
        dt="${dt:0:6}"
    fi

    # Normalize/validate date parts
    year="${dt:0:4}"
    month="${dt:4:2}"
    daypart="${dt:6:2}"

    if [ "${MODE:-daily}" = "monthly" ]; then
        # For monthly mode use year and month only (normalize to YYYYMM)
        ymm="$( date +%Y%m --date="${year}-${month}-01" 2>/dev/null || printf "%s%s" "$year" "$month")"
        out_file="${OUTBASE}/${ymm:0:4}/${ymm:4:2}/monthly_${OUTFOLDER}_${ymm}.nc"
    elif [ "${MODE:-daily}" = "sm" ]; then
        # For SM mode: organize output as YYYY/MM/DD/ (from flat YYYY/ input)
        ymd="$( date +%Y%m%d --date="${year}-${month}-${daypart}" 2>/dev/null || printf "%s%s%s" "$year" "$month" "$daypart")"
        out_file="${OUTBASE}/${ymd:0:4}/${ymd:4:2}/${ymd:6:2}/sm_${OUTFOLDER}_${ymd}.nc"
    else
        # Default: daily mode (normalize to YYYYMMDD)
        ymd="$( date +%Y%m%d --date="${year}-${month}-${daypart}" 2>/dev/null || printf "%s%s%s" "$year" "$month" "$daypart")"
        out_file="${OUTBASE}/${ymd:0:4}/${ymd:4:2}/${ymd:6:2}/daily_${OUTFOLDER}_${ymd}.nc"
    fi

    # If output already exists, skip processing
    if [ -f "$out_file" ]; then
        return 0
    fi

    # Check if input file is readable (skip corrupted/unavailable files)
    if ! [ -r "$file" ]; then
        [ "$VERBOSE" = "1" ] && echo "Skipping: $file (not readable)" >&2
        return 0
    fi

    mkdir -p "$( dirname "$out_file" )" || { echo "Error: Failed to create directory for $out_file" >&2; return 1; }

    # If file is a multi-subdataset, use the first subdataset
    # Try to detect first subdataset (stop at first match)
    subdata="$( gdalinfo "$file" 2>/dev/null | grep -m1 "SUBDATASET_1_NAME" | awk -F= '{ print $2 }' || true )"
    [ -n "$subdata" ] && file="$subdata"

    # Create a safe temporary file
    tmp="$( mktemp --suffix=.tif )"
    # Ensure tmp is removed on exit from this function/process
    trap 'rm -f "${tmp:-}"' EXIT

    # Print progress only when VERBOSE is set
    if [ "${VERBOSE:-0}" -ne 0 ]; then
        printf 'Processing: %s -> %s\n' "$file" "$out_file" >&2
    fi

    # Run GDAL tools quietly where possible and prefer fewer output lines
    gdal_translate -q -of GTiff -ot Float32 -unscale "$file" "$tmp"

    # Apply gdalwarp: reproject, clip to extent, resample to target resolution
    # -te xmin ymin xmax ymax = west south east north
    gdalwarp -q -overwrite -s_srs EPSG:4326 -of "$OUT_FORMAT" -te "$TE_W" "$TE_S" "$TE_E" "$TE_N" -tr "$RES_X" "$RES_Y" -r "$RESAMPLE_METHOD" -dstnodata "$NODATA" "$tmp" "$out_file"

    # cleanup (trap will also handle this if something fails)
    rm -f "$tmp"

    return 0
}
 
# --- script entrypoint ---
input_folder="${1:-}"
mode="${2:-daily}"
output_base="${3:-}"  # Optional: user-provided output directory

if [ -z "$input_folder" ]; then
    echo "Usage: $0 <input_folder> [daily|monthly|sm] [output_base_folder]"
    echo ""
    echo "Examples:"
    echo "  $0 /data/input"
    echo "  $0 /data/input daily"
    echo "  $0 /data/input sm /data/output"
    exit 1
fi

case "$mode" in
    daily|monthly|sm)
        ;;
    *)
        echo "Invalid mode: $mode. Use 'daily', 'monthly', or 'sm'."
        exit 2
        ;;
esac

# Determine output folder
if [ -z "$output_base" ]; then
    # Default: derive from input folder parent directory
    input_parent="$( dirname "$input_folder" )"
    mainname="$( basename "$input_folder" )"
    OUTBASE="${input_parent}/${mode}_${mainname}"
else
    # User-provided output base folder
    OUTBASE="$output_base"
fi

MODE="$mode"

# Configure runtime defaults: parallel workers and verbosity
PARALLEL="${PARALLEL:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
VERBOSE="${VERBOSE:-0}"

# Set OUTFOLDER from input folder name if not already set
if [ -z "$OUTFOLDER" ]; then
    OUTFOLDER="$( basename "$input_folder" )"
fi

export MODE OUTBASE PARALLEL VERBOSE OUTFOLDER
export RES_X RES_Y TE_W TE_S TE_E TE_N OUT_FORMAT RESAMPLE_METHOD NODATA
export -f process_file

# Start marker/timer so we can summarize what changed during this run
start_time="$(date +%s)"
start_marker="$(mktemp)"
touch "$start_marker"

# Find files and process them in parallel, handling filenames with spaces.
# Skip dates without data automatically
# xargs will run up to $PARALLEL workers. To ensure the filename is passed as
# the first argument inside the bash -c, we use the '_' placeholder and pass
# the filename as the next argument (becomes $1 inside the -c script).
find "$input_folder" -type f -print0 | xargs -0 -n1 -P "$PARALLEL" -I '{}' bash -c '[ -f "$1" ] && process_file "$1"' _ '{}'

# end timer and compute elapsed
end_time="$(date +%s)"
elapsed=$((end_time - start_time))
hours=$((elapsed/3600))
mins=$((elapsed%3600/60))
secs=$((elapsed%60))
time_str="$(printf '%02d:%02d:%02d' "$hours" "$mins" "$secs")"

# Count new output files written under OUTBASE since start_marker
if [ -d "$OUTBASE" ]; then
    processed_count="$(find "$OUTBASE" -type f -newer "$start_marker" 2>/dev/null | wc -l || echo 0)"
else
    processed_count=0
fi

total_inputs="$(find "$input_folder" -type f 2>/dev/null | wc -l || echo 0)"

# Calculate output directory size
output_size="0"
if [ -d "$OUTBASE" ]; then
    output_size="$(du -sh "$OUTBASE" 2>/dev/null | awk '{print $1}' || echo "0B")"
fi

# Calculate processing rate (files per hour)
if [ $elapsed -gt 0 ]; then
    rate=$((processed_count * 3600 / elapsed))
else
    rate=0
fi

# Print summary report
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                   PROCESSING SUMMARY REPORT                   ║"
echo "╠════════════════════════════════════════════════════════════════╣"
echo "║ Input Directory:     $input_folder"
echo "║ Output Directory:    $OUTBASE"
echo "║ Processing Mode:     $mode"
echo "╠════════════════════════════════════════════════════════════════╣"
echo "║ Configuration:"
echo "║   Resolution (X, Y):      ${RES_X}°, ${RES_Y}°"
echo "║   Extent (W, S, E, N):    ${TE_W}, ${TE_S}, ${TE_E}, ${TE_N}"
echo "║   Resampling Method:      $RESAMPLE_METHOD"
echo "║   Parallel Workers:       $PARALLEL"
echo "╠════════════════════════════════════════════════════════════════╣"
echo "║ Results:"
echo "║   Total Input Files:      ${total_inputs}"
echo "║   Processed (New):        ${processed_count}"
echo "║   Skipped (Existing):     $((total_inputs - processed_count))"
echo "║   Output Directory Size:  ${output_size}"
echo "║   Processing Rate:        ${rate} files/hour"
echo "║   Total Time Elapsed:     ${time_str} (H:M:S)"
echo "╚════════════════════════════════════════════════════════════════╝"
echo

# cleanup marker
rm -f "$start_marker"

exit 0