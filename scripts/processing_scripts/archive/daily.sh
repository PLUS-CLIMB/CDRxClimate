#!/usr/bin/env bash

set -euo pipefail

# GDAL NetCDF Preprocessing Script
# Usage: 
#   ./gdal_preprocess.sh [input_folder_or_file] [output_folder] [config_file]

CONFIG_FILE="${CONFIG_FILE:-./config.txt}"

# Function to read config values
get_config() {
    local key="$1"
    grep "^${key}" "$CONFIG_FILE" | cut -d'=' -f2 | xargs
}

# Get values from command-line arguments or config file
IN="${1:-$(get_config 'input_folder')}"
OUT="${2:-$(get_config 'output_folder')}"

if [[ -z "$IN" ]]; then echo "input folder/file missing"; exit 1; fi
if [[ -z "$OUT" ]]; then echo "output folder missing"; exit 1; fi

# Check if input is a file or folder
IS_FILE=0
if [[ -f "$IN" ]]; then
    IS_FILE=1
elif [[ ! -d "$IN" ]]; then
    echo "ERROR: Input path is neither a file nor a directory: $IN"
    exit 1
fi

# Source GDAL parameters from gdal.txt
GDAL_FILE="./gdal.txt"
if [[ ! -f "$GDAL_FILE" ]]; then
    echo "Error: GDAL config file not found: $GDAL_FILE"
    exit 1
fi
source "$GDAL_FILE"

# Get GDAL-specific parameters (can be overridden by env vars)
RES_X="${RES_X:-$res_x}"
RES_Y="${RES_Y:-$res_y}"
TE_W="${TE_W:-$te_w}"
TE_S="${TE_S:-$te_s}"
TE_E="${TE_E:-$te_e}"
TE_N="${TE_N:-$te_n}"
RESAMPLE_METHOD="${RESAMPLE_METHOD:-$resample_method}"
NODATA="${NODATA:-$nodata}"

PARALLEL="${PARALLEL:-$(get_config 'parallel')}"
PARALLEL="${PARALLEL:-4}"

LOG="${OUT%/}/gdal.log"

mkdir -p "$OUT"

# Clear previous log
echo "Starting GDAL preprocessing at $(date)" > "$LOG"
echo "Input folder: $IN" >> "$LOG"
echo "Output folder: $OUT" >> "$LOG"
echo "Resampling method: $RESAMPLE_METHOD" >> "$LOG"
echo "Resolution: ${RES_X}x${RES_Y}" >> "$LOG"
echo "Bounds: W=$TE_W S=$TE_S E=$TE_E N=$TE_N" >> "$LOG"
echo "" >> "$LOG"

# Function to extract date from filename
get_date() {
    echo "$1" | grep -oE '(19|20)[0-9]{6}' | head -n1 || true
}

# Function to extract variable name from NetCDF file
get_variable_name() {
    local file="$1"
    # Extract the first data variable name from the NetCDF file
    # Skip coordinate variables (lat, lon, time, etc.)
    ncdump -h "$file" 2>/dev/null | grep -E "^\s+(float|double)" | grep -v "latitude\|longitude\|lon\|lat\|time\|nbnds" | head -1 | awk '{print $2}' | sed 's/(.*//g' || true
}

# Function to regrid and clip a file using GDAL
# Usage: regrid_file "$input_file" "$output_file" "$variable_name_for_logging"
regrid_file() {
    local input_file="$1"
    local output_file="$2"
    local var_name="${3:-unknown}"
    
    local tmp_tif
    tmp_tif="$(mktemp --suffix=.tif)"
    trap 'rm -f "$tmp_tif"' RETURN
    
    # Translate to GeoTIFF
    if ! gdal_translate -q -of GTiff -ot Float32 "$input_file" "$tmp_tif" 2>>"$LOG"; then
        echo "ERROR: gdal_translate failed for $var_name" >> "$LOG"
        return 1
    fi
    
    # Warp to NetCDF with regridding and clipping
    if ! gdalwarp -q -overwrite -s_srs EPSG:4326 -t_srs EPSG:4326 -of NetCDF \
        -te "$TE_W" "$TE_S" "$TE_E" "$TE_N" \
        -tr "$RES_X" "$RES_Y" -r "$RESAMPLE_METHOD" \
        -dstnodata "$NODATA" "$tmp_tif" "$output_file" 2>>"$LOG"; then
        echo "ERROR: gdalwarp failed for $var_name" >> "$LOG"
        return 1
    fi
    
    return 0
}

# Export for subshells
export OUT LOG RES_X RES_Y TE_W TE_S TE_E TE_N RESAMPLE_METHOD NODATA

process_one() {
    local infile="$1"
    local base ymd yyyy mm outdir out tmp_tif var_name

    base="$(basename "$infile")"
    ymd="$(get_date "$base")"
    
    if [[ -z "$ymd" ]]; then
        echo "WARNING: No date found in $base, placing in root output folder" >> "$LOG"
        outdir="$OUT"
    else
        yyyy="${ymd:0:4}"
        mm="${ymd:4:2}"
        outdir="${OUT%/}/$yyyy/$mm"
    fi
    
    mkdir -p "$outdir"
    out="${outdir}/${base%.nc}_processed.nc"

    if [[ -f "$out" ]]; then
        return 0  # Skip silently, file already exists
    fi

    # Get list of subdatasets
    local subdatasets
    subdatasets=$(gdalinfo "$infile" 2>/dev/null | grep "SUBDATASET_.*_NAME=" | awk -F= '{print $2}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || true)
    
    if [[ -z "$subdatasets" ]]; then
        # No subdatasets, process file directly
        if regrid_file "$infile" "$out" "$base"; then
            # Extract and preserve variable name in metadata
            var_name=$(get_variable_name "$infile")
            if [[ -n "$var_name" ]]; then
                ncrename -v "Band1","$var_name" "$out" 2>>"$LOG" || true
                echo "Processed $base (var: $var_name)" >> "$LOG"
            else
                echo "Processed $base" >> "$LOG"
            fi
            return 0
        else
            echo "ERROR: $base (regridding failed)" >> "$LOG"
            return 1
        fi
    else
        # Has subdatasets - process each one separately and keep as separate files
        local tmp_dir tmp_sub sub_nc var_sub count subdataset_count var_dir
        tmp_dir="$(mktemp -d)"
        trap 'rm -rf "$tmp_dir"' RETURN
        count=0
        
        subdataset_count=$(echo "$subdatasets" | wc -l)
        echo "Processing $base with $subdataset_count subdatasets" >> "$LOG"
        
        while read -r subdata; do
            count=$((count + 1))
            tmp_sub="${tmp_dir}/sub_${count}.tif"
            sub_nc="${tmp_dir}/sub_${count}.nc"
            
            # Extract variable name from subdataset path
            # Format: NETCDF:"/path/to/file.nc":var_name
            var_sub=$(echo "$subdata" | awk -F':' '{print $NF}' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            
            # If extraction failed, default to var_N
            if [[ -z "$var_sub" ]] || [[ "$var_sub" == "$subdata" ]]; then
                var_sub="var_${count}"
            fi
            
            # Sanitize variable name for folder (remove slashes, special chars)
            var_clean=$(echo "$var_sub" | sed 's|/|_|g' | sed 's/[^a-zA-Z0-9_-]//g')
            if [[ -z "$var_clean" ]]; then
                var_clean="var_${count}"
            fi
            
            # Regrid the subdataset
            if regrid_file "$subdata" "$sub_nc" "$var_sub"; then
                # Create variable subdirectory within month folder
                var_dir="${outdir}/${var_clean}"
                mkdir -p "$var_dir"
                
                # Save with descriptive filename
                final_out="${var_dir}/${base%.nc}_${var_clean}.nc"
                cp "$sub_nc" "$final_out"
                
                echo "  Subdataset $count: $var_sub → ${var_clean}/${base%.nc}_${var_clean}.nc" >> "$LOG"
            else
                echo "ERROR: $base - subdataset $count ($var_sub) regridding failed" >> "$LOG"
                return 1
            fi
        done <<< "$subdatasets"
        
        if [[ $count -gt 0 ]]; then
            echo "Successfully processed $count subdatasets into separate files for $base" >> "$LOG"
            return 0
        else
            echo "ERROR: $base (no subdatasets processed)" >> "$LOG"
            return 1
        fi
    fi
}

export -f process_one get_date get_variable_name regrid_file

start_time=$(date +%s)

file_count=$(find "$IN" -type f \( -iname "*.nc" -o -iname "*.NC" \) | wc -l)

find "$IN" -type f \( -iname "*.nc" -o -iname "*.NC" \) -print0 | \
    xargs -0 -P "$PARALLEL" -I {} bash -c 'process_one "$1"' _ {}

end_time=$(date +%s)
total_time=$((end_time - start_time))

echo "" >> "$LOG"
echo "Total files found: $file_count" >> "$LOG"
echo "Processing time: ${total_time}s" >> "$LOG"
echo "Finished at $(date)" >> "$LOG"
