"""
metadata.py - Rename Band1 -> NDVI, attach CF-1.8 metadata, compress to NetCDF4

Usage:
    python3 metadata.py --input <raw.nc> --output <final.nc> [--overwrite]
"""
from __future__ import annotations
import argparse
import sys
from datetime import datetime
from pathlib import Path
import re

import numpy as np
import pandas as pd
import xarray as xr

DATE_RE = re.compile(r"\d{8}")

def find_main_variable(ds: xr.Dataset) -> str:
    """Find the main variable in the dataset, excluding coordinates and attributes."""
    if "Band1" in ds.data_vars:
        return "Band1"
    vars_ = list(ds.data_vars)
    if not vars_:
        raise ValueError("No data variables found in the dataset.")
    return vars_[0]

def extract_date(path: Path) -> str:
    """Extract date from filename using regex."""
    match = DATE_RE.search(path.name)
    if not match:
        raise ValueError(f"Date not found in filename: {path.name}")
    return match.group()

def main() -> None:
    parser = argparse.ArgumentParser(description="Attach CF-1.8 metadata and compress a GDAL-converted NDVI nc file")
    parser.add_argument("--input", "-i", required=True, help="Raw nc from gdal_translate")
    parser.add_argument("--output", "-o", required=True, help="Final output nc path")
    parser.add_argument("--overwrite", action="store_true", help="Allow overwriting existing output file")
    args = parser.parse_args()

    input_path=Path(args.input)
    if not input_path.is_file():
        print(f"Error: {args.input} is not a valid file.")
        return
    out_path=Path(args.output)
    if out_path.exists() and not args.overwrite:
        print(f"Error: Output file {args.output} already exists. Use --overwrite to allow overwriting.")
        return
    out_path.parent.mkdir(parents=True, exist_ok=True)

    # extract date from input or output filename
    try:
        date_str = extract_date(input_path)
    except ValueError as e:
        date_str =extract_date(out_path)
    print(f"Extracted date: {date_str}")
    
    with xr.open_dataset(input_path) as ds:
        var = find_main_variable(ds)
        print(f"Found variable: {var}")
        da = (
            ds[var]
            .rename("NDVI")
            .astype(np.float32))

    #safety mask

    da = da.where((da >= -1.0) & (da <= 1.0))

    time_value = pd.to_datetime(date_str, format="%Y%m%d")
    da = da.expand_dims(time=[time_value])
    da.attrs = {
        "long_name": "Normalized Difference Vegetation Index",
        "standard_name": "ndvi",
        "units": "1",
        "valid_min": np.float32(-1.0),
        "valid_max": np.float32(1.0),
        "coverage_content_type": "pyhsicalMeasurement",
    }

    out = da.to_dataset()
    
    out['time'].attrs = {
        "long_name": "time",
        "standard_name": "time",
    }

    out.attrs = {
        "title": "NDVI Dekadal",
        "Conventions": "CF-1.8",
        "source": "GDAL conversion from original IMG file sourced from LSAF EUMETSAT",
        "history": f"Created {datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')} by metadata.py",
    }

    encoding ={
        "NDVI": {
            "dtype": "float32",
            "zlib": True,
            "complevel": 4,
            "shuffle": True,
            "_FillValue": np.float32(-9999.0)
        }
    }

    out.to_netcdf(out_path, encoding=encoding)

    print(f"Metadata written to {args.output}")

if __name__ == "__main__":
    main()
