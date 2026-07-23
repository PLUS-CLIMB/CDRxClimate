#!/bin/bash

# script to download FVC from the LSA SAF data access service

cd "$( dirname "$0" )"



# src="https://datalsasaf.lsasvcs.ipma.pt/PRODUCTS/MSG-IODC/MDLAI/NETCDF"
src="https://datalsasaf.lsasvcs.ipma.pt/PRODUCTS/MSG/MDFVC/NETCDF"

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

mkdir -p fvc ; cd fvc

(
for y in $( seq 2010 $(date +%Y) ) ; do
        for m in $( seq -w 12 ) ; do
                for d in $( seq -w 01 31 ) ; do
                        date --date="${y}/${m}/${d}" &> /dev/null ; [ $? -ne "0" ] && continue
                        mkdir -p "${y}/${m}/${d}"
                        
                        data="$( wget -q -O- "${src}/${y}/${m}/${d}/"  --user=$USERNAME --password=$PASSWORD )"
                        [ -z "$data" ] && continue
                        echo "$data" | tr "\"" "\n" | grep "${y}/${m}/${d}" | while read url ; do
                                dt="$( basename "$url" | awk -F_ '{ print $6 }')"
                                day="$( date +%Y%m%d --date="${dt:0:4}-${dt:4:2}-${dt:6:2}" )"

                                echo "$(echo "$src" | cut -f -3 -d "/")${url}" "${y}/${m}/${d}/"
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
                wget -N "$url" --user=$USERNAME --password=$PASSWORD --accept=nc -P "$dir" &
                
                # Limit concurrent downloads to 4
                (($(jobs -r | wc -l) >= 4)) && wait
        fi
done
# Wait for all remaining downloads to complete
wait
