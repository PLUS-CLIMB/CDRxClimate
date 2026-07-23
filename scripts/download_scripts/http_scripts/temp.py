import cdsapi
import os
from datetime import datetime

# Create client
client = cdsapi.Client()

dataset = "reanalysis-era5-land-monthly-means"

# Define year range from 2010 to current year
start_year = 2010
current_year = datetime.now().year


# Create base directory structure
base_dir = "era5_data"
os.makedirs(base_dir, exist_ok=True)

# Download data for each year and month
for year in range(start_year, current_year + 1):
    # Create year directory
    year_dir = os.path.join(base_dir, str(year))
    os.makedirs(year_dir, exist_ok=True)
    
    # Determine months to download (for current year, only up to current month)
    if year == current_year:
        
        max_month = datetime.now().month - 1
    else:
        max_month = 12
    
    for month in range(1, max_month + 1):
        month_str = f"{month:02d}"
        month_dir = os.path.join(year_dir, month_str)
        os.makedirs(month_dir, exist_ok=True)
        
        # Define filename
        filename = f"era5_land_2m_temperature_{year}_{month_str}.nc"
        filepath = os.path.join(month_dir, filename)
        
        # Skip if file already exists
        if os.path.exists(filepath):
            print(f"File already exists: {filepath}")
            continue
        
        print(f"Downloading data for {year}-{month_str}...")
        
        request = {
            "product_type": ["monthly_averaged_reanalysis"],
            "variable": ["2m_temperature"],
            "year": [str(year)],
            "month": [month_str],
            "time": ["00:00"],
            "data_format": "netcdf",
            "download_format": "unarchived", 
            "area": [20.0, -18.0, 10.0, 40.0],  # North, West, South, East
        }
        
        try:
            client.retrieve(dataset, request).download(filepath)
            print(f"Successfully downloaded: {filepath}")
        except Exception as e:
            print(f"Error downloading {year}-{month_str}: {e}")
            continue

print("Download process completed!")
