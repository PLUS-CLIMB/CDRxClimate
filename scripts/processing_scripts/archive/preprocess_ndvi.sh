#!/usr/bin/env bash
set -euo pipefail

# NDVI Preprocessing Script
# Handles sparse 10-day interval NDVI data organized in YYYY/MM/DD/ structure
# File naming: METOP_AVHRR_YYYYMMDD_S10_AFR_ndvi_psdc.nc
# Each month typically has 3 files: days 01, 11, 21 (10-day intervals)
#
# Usage: preprocess_ndvi.sh <input_folder> [output_base_folder]
# Example: preprocess_ndvi.sh /data/dv-data/raw/ndvi /data/dv-data/preprocessed/ndvi
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

process_ndvi_file() {
    file="$1"
    
    # Extract YYYYMMDD from METOP_AVHRR_YYYYMMDD_S10_AFR_ndvi_psdc.nc
    # Example: METOP_AVHRR_20100101_S10_AFR_ndvi_psdc.nc -> 20100101
    base_name="$( basename "$file" )"
    
    # Use regex to extract 8-digit date (YYYYMMDD) from filename
    # Pattern: METOP_AVHRR_<YYYYMMDD>_S10_
    date_str="$( printf '%s' "$base_name" | grep -oE '[0-9]{8}' | head -1 || true )"
    
    if [ -z "$date_str" ]; then
        [ "$VERBOSE" = "1" ] && echo "Skipping: $file (could not extract date)" >&2
        return 0
    fi
    
    # Parse date components
    year="${date_str:0:4}"
    month="${date_str:4:2}"
    day="${date_str:6:2}"
    
    # Construct output file path: YYYY/MM/DD/ndvi_YYYYMMDD.nc
    out_file="${OUTBASE}/${year}/${month}/${day}/ndvi_${date_str}.nc"
    
    # If output already exists, skip processing
    if [ -f "$out_file" ]; then
        [ "$VERBOSE" = "1" ] && echo "Skipping: $file (output exists: $out_file)" >&2
        return 0
    fi
    
    # Check if input file is readable (skip corrupted/unavailable files)
    if ! [ -r "$file" ]; then
        [ "$VERBOSE" = "1" ] && echo "Skipping: $file (not readable)" >&2
        return 0
    fi
    
    mkdir -p "$( dirname "$out_file" )" || { echo "Error: Failed to create directory for $out_file" >&2; return 1; }
    
    # If file is a multi-subdataset, use the first subdataset (NDVI data)
    # Try to detect first subdataset (stop at first match)
    subdata="$( gdalinfo "$file" 2>/dev/null | grep -m1 "SUBDATASET_1_NAME" | awk -F= '{ print $2 }' || true )"
    [ -n "$subdata" ] && file="$subdata"
    
    # Create a safe temporary file
    tmp="$( mktemp --suffix=.tif )"
    # Ensure tmp is removed on exit from this function/process
    trap 'rm -f "${tmp:-}"' EXIT
    
    # Print progress only when VERBOSE is set
    if [ "${VERBOSE:-0}" -ne 0 ]; then
        printf 'Processing NDVI: %s -> %s\n' "$file" "$out_file" >&2
    fi
    
    # Run GDAL tools quietly where possible
    gdal_translate -q -of GTiff -ot Float32 -unscale "$file" "$tmp"
    
    # Use configured target extent and resolution
    # gdalwarp parameters: -te <xmin> <ymin> <xmax> <ymax> (west, south, east, north)
    gdalwarp -q -overwrite -s_srs EPSG:4326 -of "$OUT_FORMAT" \
        -te "$TE_W" "$TE_S" "$TE_E" "$TE_N" \
        -tr "$RES_X" "$RES_Y" \
        -r "$RESAMPLE_METHOD" \
        -dstnodata "$NODATA" \
        "$tmp" "$out_file"
    
    # cleanup (trap will also handle this if something fails)
    rm -f "$tmp"
    
    return 0
}

# --- script entrypoint ---
input_folder="${1:-}"
output_base="${2:-}"  # Optional: user-provided output directory

if [ -z "$input_folder" ]; then
    echo "Usage: $0 <input_folder> [output_base_folder]"
    echo ""
    echo "Examples:"
    echo "  $0 /data/dv-data/raw/ndvi"
    echo "  $0 /data/dv-data/raw/ndvi /data/dv-data/preprocessed/ndvi"
    echo ""
    echo "Expected input structure:"
    echo "  /data/dv-data/raw/ndvi/YYYY/MM/DD/METOP_AVHRR_YYYYMMDD_S10_AFR_ndvi_psdc.nc"
    echo ""
    echo "Output structure:"
    echo "  /output/YYYY/MM/DD/ndvi_YYYYMMDD.nc"
    exit 1
fi

# Determine output folder
if [ -z "$output_base" ]; then
    # Default: derive from input folder parent directory
    input_parent="$( dirname "$input_folder" )"
    mainname="$( basename "$input_folder" )"
    OUTBASE="${input_parent}/preprocessed_${mainname}"
else
    # User-provided output base folder
    OUTBASE="$output_base"
fi

# Configure runtime defaults: parallel workers and verbosity
PARALLEL="${PARALLEL:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
VERBOSE="${VERBOSE:-0}"

export OUTBASE PARALLEL VERBOSE
export RES_X RES_Y TE_W TE_S TE_E TE_N OUT_FORMAT RESAMPLE_METHOD NODATA
export -f process_ndvi_file

# Start marker/timer so we can summarize what changed during this run
start_time="$(date +%s)"
start_marker="$(mktemp)"
touch "$start_marker"

# Find all NDVI NetCDF files and process them in parallel
# File pattern: METOP_AVHRR_*.nc
# Handle filenames with spaces using -print0 and -0 delimiter
find "$input_folder" -type f -name "METOP_AVHRR_*_ndvi_psdc.nc" -print0 | \
    xargs -0 -n1 -P "$PARALLEL" -I '{}' bash -c 'process_ndvi_file "$1"' _ '{}'

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

total_inputs="$(find "$input_folder" -type f -name "METOP_AVHRR_*_ndvi_psdc.nc" 2>/dev/null | wc -l || echo 0)"

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
echo "║              NDVI PREPROCESSING SUMMARY REPORT                 ║"
echo "╠════════════════════════════════════════════════════════════════╣"
echo "║ Input Directory:     $input_folder"
echo "║ Output Directory:    $OUTBASE"
echo "║ Data Type:           NDVI (10-day intervals)"
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
