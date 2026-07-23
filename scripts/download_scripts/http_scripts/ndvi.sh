#!/bin/bash

# script to download 10 day NDVI from the LSA SAF data access service

# Usage: ./ndvi.sh [START_YEAR] [END_YEAR] [OUTPUT_DIR] [UNZIP]
# Example: ./ndvi.sh 2010 2024 ndvi 1
cd "$( dirname "$0" )"



# src="https://datalsasaf.lsasvcs.ipma.pt/PRODUCTS/MSG-IODC/MDLAI/NETCDF"
src="https://datalsasaf.lsasvcs.ipma.pt/PRODUCTS/EPS/ENDVI10/ENVI"
START_YEAR="${1:-2010}"
END_YEAR="${2:-$(date +%Y)}"
OUT_DIR="${3:-ndvi}"
UNZIP="${4:-0}"

# Load credentials from .env (next to script or its parent dir)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for ENV_CAND in "$SCRIPT_DIR/.env" "$SCRIPT_DIR/../.env"; do
  if [ -f "$ENV_CAND" ]; then
    set -a
    # shellcheck source=/dev/null
    . "$ENV_CAND"
    set +a
    break
  fi
done
if [ -z "${USERNAME:-}" ] || [ -z "${PASSWORD:-}" ]; then
  echo "Error: USERNAME or PASSWORD not set after loading .env" >&2
  exit 1
fi

mkdir -p "$OUT_DIR" ; cd "$OUT_DIR"

(
for y in $( seq "$START_YEAR" "$END_YEAR" ) ; do
        for m in $( seq -w 12 ) ; do
                for d in 01 11 21 ; do
                        date --date="${y}/${m}/${d}" &> /dev/null ; [ $? -ne "0" ] && continue
                        mkdir -p "${y}/${m}"
                        
                        data="$( wget -q -O- "${src}/${y}/${m}/${d}/"  --user=$USERNAME --password=$PASSWORD )"
                        [ -z "$data" ] && continue
                        echo "$data" | tr "\"" "\n" | grep "${y}/${m}/${d}" | grep "AFR_V200.zip" | while read url ; do
                                echo "$(echo "$src" | cut -f -3 -d "/")${url}" "${y}/${m}/"
                        done

                done
        done
done

) | while read url_and_dir ; do
        url="$(echo "$url_and_dir" | awk '{print $1}')"
        dir="$(echo "$url_and_dir" | awk '{print $2}')"
        if [ -n "$url" ] && [ -n "$dir" ]; then
                echo "Downloading to directory: $dir"
                echo "URL: $url"
                # Download files in parallel using background processes
                wget -N "$url" --user=$USERNAME --password=$PASSWORD --accept=zip  -P "$dir" &
                
                # Limit concurrent downloads to 4
                (($(jobs -r | wc -l) >= 4)) && wait
        fi
done
# Wait for all remaining downloads to complete
wait

if [ "$UNZIP" = "1" ] || [ "$UNZIP" = "yes" ] || [ "$UNZIP" = "true" ]; then
        command -v unzip >/dev/null 2>&1 || { echo "Error: unzip is not installed" >&2; exit 1; }
        find . -type f -name "*.zip" -print0 | while IFS= read -r -d '' z ; do
                if unzip -n "$z" -d "$(dirname "$z")"; then
                        rm -f "$z"
                else
                        echo "Warning: failed to unzip $z; keeping archive" >&2
                fi
        done
fi
