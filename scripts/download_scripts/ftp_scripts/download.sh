#!/bin/bash

# Check if wget is installed
command -v wget >/dev/null 2>&1 || { echo >&2 "wget is required but it's not installed. Aborting."; exit 1; }

cd "$(dirname "$0" )"

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
    
# Base directory for downloads
mkdir -p sm
cd sm

# Base FTP path (per-year subdirectories)
BASE_FTP_PATH="/h142/h142/netCDF4"

# Define years to loop through: from 2010 up to 2018
YEARS=($(seq 2019 2021))

# Loop through years and download everything under the per-year folder
for YEAR in "${YEARS[@]}"; do
    echo "Processing year: $YEAR"

    # Create subdirectory for this year
    mkdir -p "${YEAR}"

    # Mirror the remote year directory into the local ${YEAR} folder.
    # Use recursive wget instead of parsing HTML directory listings which are fragile.
    URL="ftp://ftphsaf.meteoam.it${BASE_FTP_PATH}/${YEAR}/"

    echo "Mirroring $URL -> ./${YEAR}/"

    # --no-parent    : don't ascend to parent directories
    # -nH            : don't create host-prefixed directory
    # --cut-dirs=4   : strip leading path components (h141/h141/netCDF/YEAR)
    # -t 3 --wait=1  : retries and polite wait between attempts
    # --reject       : avoid index.html files created by some servers
    wget -r -nH --no-parent --cut-dirs=4 --reject 'index.html*' -t 3 --wait=1 \
        --user="$USERNAME" --password="$PASSWORD" -P "${YEAR}" "$URL"
done

exit 0


