import marimo

__generated_with = "0.23.16"
app = marimo.App(width="medium")


@app.cell
def _(mo):
    mo.md(r"""
    ## Spatial Proximity Algorithms

    The most useful algorithms are:

    | Purpose | Algorithm | Output column |
    |:-----------|:------------:|------------:|
    |Basic proximity |	Centroid-to-centroid distance	| centroid_distance_km
    Physical touching/neighbouring| Queen/Rook contiguity|is_adjacent
    Nearest destination logic	|k-nearest neighbours	|origin_distance_rank, is_top5_nearest
    Distance decay	|Distance-band classification|	distance_band_km
    Real travel proximity	|Network shortest path	|road_distance_km, travel_time_min
    Statistical testing|	Gravity / Poisson model|	distance coefficient

    distance alone is not a key driver anymore, many people still believe and it might not be true for all the
    """)
    return


@app.cell
def _():
    import marimo as mo
    import polars as pl
    import numpy as np
    import matplotlib.pyplot as plt
    from matplotlib.patches import Polygon as MplPolygon
    from matplotlib.collections import PatchCollection, LineCollection
    from matplotlib import cm, colors as mcolors
    from pathlib import Path
    import shapely
    from shapely.strtree import STRtree

    return (
        LineCollection,
        MplPolygon,
        PatchCollection,
        Path,
        STRtree,
        cm,
        mcolors,
        mo,
        np,
        pl,
        plt,
        shapely,
    )


@app.cell
def _(Path):
    # ------------------------------------------------------------------
    # Paths
    # ------------------------------------------------------------------
    mobility_path = Path("./mobility_data/processed_mobility_tables/long_od_time_weighted_A_30days.parquet")
    units_path = Path("./mobility_data/spatial_units_with_lat_lon.parquet")
    prox_path = Path("./mobility_data/processed_mobility_tables/prox_lookup.parquet")

    # Optional future climate file: one row = unit + date.
    climate_path = Path("./mobility_data/climate_unit_time.parquet")

    cube_dir = Path("./mobility_data/vector_cubes")
    cube_dir.mkdir(parents=True, exist_ok=True)

    od_time_out = cube_dir / "od_time_enriched.parquet"
    origin_time_out = cube_dir / "origin_time_cube.parquet"
    contiguity_out = cube_dir / "contiguity_edges.parquet"
    origin_climate_out = cube_dir / "origin_climate_cube.parquet"
    od_climate_out = cube_dir / "od_climate_cube.parquet"

    missing = [str(p) for p in [mobility_path, units_path, prox_path] if not p.exists()]
    if missing:
        raise FileNotFoundError("Missing required input files:\n" + "\n".join(missing))
    return (
        climate_path,
        contiguity_out,
        mobility_path,
        od_climate_out,
        od_time_out,
        origin_climate_out,
        origin_time_out,
        prox_path,
        units_path,
    )


@app.cell
def _(
    LineCollection,
    MplPolygon,
    PatchCollection,
    cm,
    mcolors,
    np,
    pl,
    shapely,
):
    # ------------------------------------------------------------------
    # Pure Polars + Shapely helpers: no pandas, no geopandas.
    # ------------------------------------------------------------------
    NUMERIC_TYPES = {
        pl.Float32, pl.Float64,
        pl.Int8, pl.Int16, pl.Int32, pl.Int64,
        pl.UInt8, pl.UInt16, pl.UInt32, pl.UInt64,
    }

    def safe_float_array(values):
        out = []
        for v in values:
            if v is None:
                out.append(np.nan)
            else:
                try:
                    out.append(float(v))
                except Exception:
                    out.append(np.nan)
        return np.asarray(out, dtype=float)

    def series_to_float_array(df, col):
        if col not in df.columns or df.height == 0:
            return np.asarray([], dtype=float)
        return safe_float_array(df[col].to_list())

    def zscore_array(values):
        arr = safe_float_array(values)
        mean = np.nanmean(arr)
        std = np.nanstd(arr)
        if not np.isfinite(std) or std == 0:
            return arr * np.nan
        return (arr - mean) / std

    def centered_moving_average(values, _window):
        arr = safe_float_array(values)
        if _window <= 1 or len(arr) < _window:
            return arr
        half = _window // 2
        out = np.full(len(arr), np.nan, dtype=float)
        for i in range(len(arr)):
            start = max(0, i - half)
            end = min(len(arr), i + half + 1)
            out[i] = np.nanmean(arr[start:end])
        return out

    def lag_array(values, _lag):
        # Positive lag = earlier climate aligned with current mobility.
        arr = safe_float_array(values)
        out = np.full(len(arr), np.nan, dtype=float)
        if _lag == 0:
            return arr
        if _lag > 0:
            out[_lag:] = arr[:-_lag]
        else:
            out[:_lag] = arr[-_lag:]
        return out

    def corr_ignore_nan(a, b):
        aa = safe_float_array(a)
        bb = safe_float_array(b)
        mask = np.isfinite(aa) & np.isfinite(bb)
        if mask.sum() < 3:
            return np.nan
        return float(np.corrcoef(aa[mask], bb[mask])[0, 1])

    def choose_id_col(cols):
        for c in ["norm_id", "norm_spatial_id", "unit_id", "id"]:
            if c in cols:
                return c
        raise KeyError("Could not find a spatial unit id column. Expected norm_id or norm_spatial_id.")

    def choose_name_col(cols):
        for c in ["plot_name", "name", "unit_name", "origin_name", "NAME_2", "ADM2_EN", "label"]:
            if c in cols:
                return c
        return None

    def parse_geometry(value):
        if value is None:
            return None
        try:
            if isinstance(value, memoryview):
                return shapely.from_wkb(value.tobytes())
            if isinstance(value, (bytes, bytearray)):
                return shapely.from_wkb(bytes(value))
            if isinstance(value, str):
                # Supports WKT strings if the file stores geometry that way.
                return shapely.from_wkt(value)
        except Exception:
            return None
        return None

    def load_units_without_geopandas(units_path):
        units_df = pl.read_parquet(units_path).with_row_index("_unit_row")
        unit_id_col = choose_id_col(units_df.columns)
        name_col = choose_name_col(units_df.columns)

        if name_col is None:
            units_df = units_df.with_columns(pl.col(unit_id_col).cast(pl.Utf8).alias("plot_name"))
        else:
            units_df = units_df.with_columns(
                pl.when(pl.col(name_col).is_not_null())
                .then(pl.col(name_col).cast(pl.Utf8))
                .otherwise(pl.col(unit_id_col).cast(pl.Utf8))
                .alias("plot_name")
            )

        geometry_col = None
        for c in ["geometry", "geom", "wkb_geometry"]:
            if c in units_df.columns:
                geometry_col = c
                break

        geoms = []
        if geometry_col is not None:
            geoms = [parse_geometry(v) for v in units_df[geometry_col].to_list()]
        else:
            geoms = [None] * units_df.height

        unit_ids = units_df[unit_id_col].to_list()
        plot_names = units_df["plot_name"].to_list()
        unit_name_lookup = dict(zip(unit_ids, plot_names))
        unit_index_lookup = {uid: i for i, uid in enumerate(unit_ids)}
        has_geometry = any(g is not None and not g.is_empty for g in geoms)

        return units_df, geoms, unit_id_col, unit_name_lookup, unit_index_lookup, has_geometry

    def iter_polygons(geom):
        if geom is None or getattr(geom, "is_empty", True):
            return
        gtype = geom.geom_type
        if gtype == "Polygon":
            yield geom
        elif gtype == "MultiPolygon":
            for poly in geom.geoms:
                yield poly
        elif gtype == "GeometryCollection":
            for part in geom.geoms:
                yield from iter_polygons(part)

    def build_polygon_patches(geoms, values=None):
        patches = []
        patch_values = []
        for i, geom in enumerate(geoms):
            value = None if values is None else values[i]
            for poly in iter_polygons(geom) or []:
                coords = np.asarray(poly.exterior.coords)
                if coords.shape[0] >= 3:
                    patches.append(MplPolygon(coords, closed=True))
                    patch_values.append(value)
        return patches, patch_values

    def plot_polygons(
        _ax,
        geoms,
        values=None,
        cmap="viridis",
        facecolor="lightgrey",
        edgecolor="white",
        linewidth=0.25,
        alpha=1.0,
        legend=False,
        legend_label=None,
        missing_color="lightgrey",
    ):
        if values is None:
            patches, _ = build_polygon_patches(geoms)
            if patches:
                collection = PatchCollection(
                    patches,
                    facecolor=facecolor,
                    edgecolor=edgecolor,
                    linewidth=linewidth,
                    alpha=alpha,
                )
                _ax.add_collection(collection)
            return None

        values_arr = safe_float_array(values)
        valid_geoms = []
        valid_values = []
        missing_geoms = []
        for geom, val in zip(geoms, values_arr):
            if np.isfinite(val):
                valid_geoms.append(geom)
                valid_values.append(val)
            else:
                missing_geoms.append(geom)

        if missing_geoms:
            missing_patches, _ = build_polygon_patches(missing_geoms)
            if missing_patches:
                missing_collection = PatchCollection(
                    missing_patches,
                    facecolor=missing_color,
                    edgecolor=edgecolor,
                    linewidth=linewidth,
                    alpha=0.8,
                )
                _ax.add_collection(missing_collection)

        if not valid_geoms:
            return None

        valid_patches, patch_values = build_polygon_patches(valid_geoms, valid_values)
        if not valid_patches:
            return None

        patch_values = safe_float_array(patch_values)
        norm = mcolors.Normalize(vmin=np.nanmin(patch_values), vmax=np.nanmax(patch_values))
        collection = PatchCollection(
            valid_patches,
            cmap=cm.get_cmap(cmap),
            norm=norm,
            edgecolor=edgecolor,
            linewidth=linewidth,
            alpha=alpha,
        )
        collection.set_array(patch_values)
        _ax.add_collection(collection)

        if legend:
            cbar = _ax.figure.colorbar(collection, ax=_ax, orientation="horizontal", shrink=0.7, pad=0.03)
            if legend_label:
                cbar.set_label(legend_label)

        return collection

    def plot_boundaries(_ax, geoms, color="black", linewidth=1.5, linestyle="-"):
        lines = []
        for geom in geoms:
            for poly in iter_polygons(geom) or []:
                coords = np.asarray(poly.exterior.coords)
                if coords.shape[0] >= 2:
                    lines.append(coords)
        if lines:
            collection = LineCollection(lines, colors=color, linewidths=linewidth, linestyles=linestyle)
            _ax.add_collection(collection)
            return collection
        return None

    def set_equal_extent(_ax, geoms, pad_ratio=0.05):
        bounds = []
        for geom in geoms:
            if geom is not None and not geom.is_empty:
                bounds.append(geom.bounds)
        if not bounds:
            _ax.set_axis_off()
            return
        arr = np.asarray(bounds, dtype=float)
        minx, miny = np.nanmin(arr[:, 0]), np.nanmin(arr[:, 1])
        maxx, maxy = np.nanmax(arr[:, 2]), np.nanmax(arr[:, 3])
        dx = max(maxx - minx, 1e-9)
        dy = max(maxy - miny, 1e-9)
        _ax.set_xlim(minx - dx * pad_ratio, maxx + dx * pad_ratio)
        _ax.set_ylim(miny - dy * pad_ratio, maxy + dy * pad_ratio)
        _ax.set_aspect("equal", adjustable="box")
        _ax.axis("off")

    def representative_xy(geom):
        if geom is None or geom.is_empty:
            return None
        p = geom.representative_point()
        return float(p.x), float(p.y)

    def geoms_by_ids(unit_ids_to_get, unit_index_lookup, unit_geoms):
        out = []
        for uid in unit_ids_to_get:
            idx = unit_index_lookup.get(uid)
            out.append(None if idx is None else unit_geoms[idx])
        return out

    def numeric_columns(lf, exclude):
        schema = lf.collect_schema()
        return [c for c, dtype in schema.items() if c not in exclude and dtype in NUMERIC_TYPES]

    def map_metric_column(selected_flow, selected_metric):
        if selected_flow == "Departures":
            mapping = {
                "Total flow": "total_depart",
                "Flow-weighted distance": "flow_weighted_distance_depart_km",
                "Share to top 5 nearest": "share_depart_top5_nearest",
                "Share to adjacent units": "share_depart_adjacent",
                "Positive destinations": "n_positive_dest_depart",
            }
        else:
            mapping = {
                "Total flow": "total_return",
                "Flow-weighted distance": "flow_weighted_distance_return_km",
                "Share to top 5 nearest": "share_return_top5_nearest",
                "Share to adjacent units": "share_return_adjacent",
                "Positive destinations": "n_positive_dest_return",
            }
        labels = {
            "total_depart": "Total departures",
            "total_return": "Total returns",
            "flow_weighted_distance_depart_km": "Flow-weighted departure distance, km",
            "flow_weighted_distance_return_km": "Flow-weighted return distance, km",
            "share_depart_top5_nearest": "Share of departures to top 5 nearest",
            "share_return_top5_nearest": "Share of returns to top 5 nearest",
            "share_depart_adjacent": "Share of departures to adjacent units",
            "share_return_adjacent": "Share of returns to adjacent units",
            "n_positive_dest_depart": "Positive departure destinations",
            "n_positive_dest_return": "Positive return destinations",
        }
        col = mapping[selected_metric]
        return col, labels[col]

    return (
        centered_moving_average,
        corr_ignore_nan,
        geoms_by_ids,
        lag_array,
        load_units_without_geopandas,
        map_metric_column,
        numeric_columns,
        plot_boundaries,
        plot_polygons,
        representative_xy,
        set_equal_extent,
        zscore_array,
    )


@app.cell
def _(load_units_without_geopandas, units_path):
    # ------------------------------------------------------------------
    # Spatial units as Polars DataFrame + Shapely geometry list.
    # ------------------------------------------------------------------
    units_df, unit_geoms, unit_id_col, unit_name_lookup, unit_index_lookup, has_geometry = load_units_without_geopandas(units_path)
    unit_ids = units_df[unit_id_col].to_list()
    return (
        has_geometry,
        unit_geoms,
        unit_ids,
        unit_index_lookup,
        unit_name_lookup,
    )


@app.cell
def _(mobility_path, od_time_out, origin_time_out, pl, prox_path):
    # ------------------------------------------------------------------
    # Build base vector cubes if needed using Polars only.
    # ------------------------------------------------------------------
    if not od_time_out.exists():
        mob_lf = pl.scan_parquet(mobility_path)
        prox_lf = pl.scan_parquet(prox_path)
        (
            mob_lf.join(
                prox_lf,
                left_on=["norm_spatial_id_origin", "norm_spatial_id_destination"],
                right_on=["origin_id", "destination_id"],
                how="left",
            )
            .sink_parquet(od_time_out)
        )

    if not origin_time_out.exists():
        od_build = pl.scan_parquet(od_time_out).with_columns(pl.col("date").cast(pl.Date, strict=False))
        schema = od_build.collect_schema()
        has_migrants = "N_migrants" in schema

        agg_exprs = [
            pl.col("N_depart").sum().alias("total_depart"),
            pl.col("N_return").sum().alias("total_return"),
            pl.when(pl.col("N_depart") > 0).then(pl.col("norm_spatial_id_destination")).otherwise(None).n_unique().alias("n_positive_dest_depart"),
            pl.when(pl.col("N_return") > 0).then(pl.col("norm_spatial_id_destination")).otherwise(None).n_unique().alias("n_positive_dest_return"),
            ((pl.col("N_depart") * pl.col("centroid_distance_km")).sum() / pl.col("N_depart").sum()).alias("flow_weighted_distance_depart_km"),
            ((pl.col("N_return") * pl.col("centroid_distance_km")).sum() / pl.col("N_return").sum()).alias("flow_weighted_distance_return_km"),
            (pl.when(pl.col("is_top5_nearest") == True).then(pl.col("N_depart")).otherwise(0).sum() / pl.col("N_depart").sum()).alias("share_depart_top5_nearest"),
            (pl.when(pl.col("is_top5_nearest") == True).then(pl.col("N_return")).otherwise(0).sum() / pl.col("N_return").sum()).alias("share_return_top5_nearest"),
            (pl.when(pl.col("is_adjacent") == True).then(pl.col("N_depart")).otherwise(0).sum() / pl.col("N_depart").sum()).alias("share_depart_adjacent"),
            (pl.when(pl.col("is_adjacent") == True).then(pl.col("N_return")).otherwise(0).sum() / pl.col("N_return").sum()).alias("share_return_adjacent"),
        ]
        if has_migrants:
            agg_exprs.insert(2, pl.col("N_migrants").sum().alias("total_migrants"))

        group_cols = ["norm_spatial_id_origin", "origin_name", "origin_type", "date"]
        for c in ["subset_type", "days_span"]:
            if c in schema:
                group_cols.append(c)

        od_build.group_by(group_cols).agg(agg_exprs).sink_parquet(origin_time_out)
    return


@app.cell
def _(STRtree, contiguity_out, has_geometry, np, pl, unit_geoms, unit_ids):
    # ------------------------------------------------------------------
    # Queen contiguity table using Shapely STRtree only.
    # If the file already exists, it is reused.
    # ------------------------------------------------------------------
    if not contiguity_out.exists():
        if not has_geometry:
            pl.DataFrame({"origin_id": [], "neighbor_id": [], "queen_weight": []}).write_parquet(contiguity_out)
        else:
            valid_pairs = [(i, g) for i, g in enumerate(unit_geoms) if g is not None and not g.is_empty]
            valid_indices = [i for i, _ in valid_pairs]
            valid_geoms = [g for _, g in valid_pairs]
            tree = STRtree(valid_geoms)
            geom_id_to_valid_position = {id(g): k for k, g in enumerate(valid_geoms)}

            origins = []
            neighbors = []
            for local_i, geom in enumerate(valid_geoms):
                result = tree.query(geom, predicate="touches")
                for item in result:
                    if isinstance(item, (int, np.integer)):
                        local_j = int(item)
                    else:
                        local_j = geom_id_to_valid_position.get(id(item))
                    if local_j is None or local_i == local_j:
                        continue
                    i = valid_indices[local_i]
                    j = valid_indices[local_j]
                    origins.append(unit_ids[i])
                    neighbors.append(unit_ids[j])

            contig_df = pl.DataFrame({"origin_id": origins, "neighbor_id": neighbors})
            if contig_df.height > 0:
                contig_df = contig_df.unique().with_columns(pl.lit(1).alias("queen_weight"))
            else:
                contig_df = pl.DataFrame({"origin_id": [], "neighbor_id": [], "queen_weight": []})
            contig_df.write_parquet(contiguity_out)
    return


@app.cell
def _(
    climate_path,
    numeric_columns,
    od_climate_out,
    od_time_out,
    origin_climate_out,
    origin_time_out,
    pl,
):
    # ------------------------------------------------------------------
    # Optional climate-mobility cubes using Polars only.
    # ------------------------------------------------------------------
    climate_available = None

    if climate_available:
        clim_lf = pl.scan_parquet(climate_path).with_columns(pl.col("date").cast(pl.Date, strict=False))
        clim_schema = clim_lf.collect_schema()
        climate_unit_id_col = "norm_spatial_id" if "norm_spatial_id" in clim_schema else "norm_id"
        climate_vars_build = numeric_columns(clim_lf, exclude={"norm_spatial_id", "norm_id", "date"})

        if not origin_climate_out.exists():
            origin_lf_build = pl.scan_parquet(origin_time_out).with_columns(pl.col("date").cast(pl.Date, strict=False))
            (
                origin_lf_build.join(
                    clim_lf,
                    left_on=["norm_spatial_id_origin", "date"],
                    right_on=[climate_unit_id_col, "date"],
                    how="left",
                )
                .sink_parquet(origin_climate_out)
            )

        if not od_climate_out.exists():
            od_lf_build = pl.scan_parquet(od_time_out).with_columns(pl.col("date").cast(pl.Date, strict=False))
            origin_clim = clim_lf.select(
                [pl.col(climate_unit_id_col).alias("norm_spatial_id_origin"), pl.col("date")]
                + [pl.col(v).alias(f"origin_{v}") for v in climate_vars_build]
            )
            destination_clim = clim_lf.select(
                [pl.col(climate_unit_id_col).alias("norm_spatial_id_destination"), pl.col("date")]
                + [pl.col(v).alias(f"destination_{v}") for v in climate_vars_build]
            )
            (
                od_lf_build
                .join(origin_clim, on=["norm_spatial_id_origin", "date"], how="left")
                .join(destination_clim, on=["norm_spatial_id_destination", "date"], how="left")
                .with_columns([
                    (pl.col(f"destination_{v}") - pl.col(f"origin_{v}")).alias(f"delta_{v}")
                    for v in climate_vars_build
                ])
                .sink_parquet(od_climate_out)
            )
    return (climate_available,)


@app.cell
def _(
    climate_available,
    contiguity_out,
    od_climate_out,
    od_time_out,
    origin_climate_out,
    origin_time_out,
    pl,
):
    # ------------------------------------------------------------------
    # Lazy frames: climate cubes are used automatically when available.
    # ------------------------------------------------------------------
    origin_source_path = origin_climate_out if climate_available else origin_time_out
    od_source_path = od_climate_out if climate_available else od_time_out

    origin_time_lf = pl.scan_parquet(origin_source_path).with_columns(pl.col("date").cast(pl.Date, strict=False))
    od_lf = pl.scan_parquet(od_source_path).with_columns(pl.col("date").cast(pl.Date, strict=False))
    contig_lf = pl.scan_parquet(contiguity_out)
    return contig_lf, od_lf, origin_time_lf


@app.cell
def _(numeric_columns, origin_time_lf):
    # ------------------------------------------------------------------
    # Auto-detect future climate variables.
    # ------------------------------------------------------------------
    base_cols = {
        "norm_spatial_id_origin", "origin_name", "origin_type", "date", "subset_type", "days_span",
        "total_depart", "total_return", "total_migrants",
        "n_positive_dest_depart", "n_positive_dest_return",
        "flow_weighted_distance_depart_km", "flow_weighted_distance_return_km",
        "share_depart_top5_nearest", "share_return_top5_nearest",
        "share_depart_adjacent", "share_return_adjacent",
    }
    climate_vars = numeric_columns(origin_time_lf, exclude=base_cols)
    climate_var_options = climate_vars if climate_vars else ["No climate variables found"]
    return climate_var_options, climate_vars


@app.cell
def _(climate_var_options, mo, od_lf, origin_time_lf, pl):
    # ------------------------------------------------------------------
    # Native Marimo controls. IDs remain internal; labels show _names.
    # ------------------------------------------------------------------
    origin_rows = (
        origin_time_lf
        .select([pl.col("norm_spatial_id_origin").alias("unit_id"), pl.col("origin_name").alias("unit_name")])
        .unique()
        .sort("unit_name")
        .collect()
        .iter_rows(named=True)
    )
    origin_labels = {
        f"{(row['unit_name'] if row['unit_name'] is not None else row['unit_id'])} | {row['unit_id']}": row["unit_id"]
        for row in origin_rows
    }

    destination_rows = (
        od_lf
        .select([pl.col("norm_spatial_id_destination").alias("unit_id"), pl.col("destination_name").alias("unit_name")])
        .unique()
        .sort("unit_name")
        .collect()
        .iter_rows(named=True)
    )
    destination_labels = {
        f"{(row['unit_name'] if row['unit_name'] is not None else row['unit_id'])} | {row['unit_id']}": row["unit_id"]
        for row in destination_rows
    }

    date_options = (
        origin_time_lf.select(pl.col("date")).unique().sort("date").collect().to_series().to_list()
    )

    origin_select = mo.ui.dropdown(options=list(origin_labels.keys()), value=list(origin_labels.keys())[0], label="Origin")
    destination_select = mo.ui.dropdown(options=list(destination_labels.keys()), value=list(destination_labels.keys())[0], label="Destination")
    date_select = mo.ui.dropdown(options=date_options, value=date_options[0], label="Date")
    flow_select = mo.ui.dropdown(options=["Departures", "Returns"], value="Departures", label="Flow")
    metric_select = mo.ui.dropdown(
        options=["Total flow", "Flow-weighted distance", "Share to top 5 nearest", "Share to adjacent units", "Positive destinations"],
        value="Total flow",
        label="Mobility metric",
    )
    climate_var_select = mo.ui.dropdown(options=climate_var_options, value=climate_var_options[0], label="Climate variable")
    show_climate_switch = mo.ui.switch(value=False, label="Overlay climate")
    lag_select = mo.ui.slider(start=-6, stop=6, step=1, value=0, label="Climate lag / lead")
    standardize_switch = mo.ui.switch(value=True, label="Standardize time series")
    smooth_switch = mo.ui.switch(value=False, label="Smooth time series")
    smooth_window_slider = mo.ui.slider(start=3, stop=11, step=2, value=3, label="Smoothing _window")
    map_variable_select = mo.ui.dropdown(
        options=["Flow value", "Distance from origin", "Spatial rank", "Destination climate", "Origin climate", "Destination-origin climate difference"],
        value="Flow value",
        label="Flow map colour variable",
    )
    destination_mode_select = mo.ui.dropdown(options=["Top destinations", "Selected destination only"], value="Top destinations", label="Destination mode")
    top_n_select = mo.ui.slider(start=5, stop=100, step=5, value=30, label="Top destinations")
    min_flow_select = mo.ui.slider(start=0, stop=500, step=5, value=0, label="Minimum flow")
    color_ramp_select = mo.ui.dropdown(
        options=["viridis", "plasma", "magma", "cividis", "YlOrRd", "YlGnBu", "PuBuGn", "Blues", "Greens", "Oranges", "Reds", "RdBu_r", "coolwarm", "BrBG", "PiYG"],
        value="viridis",
        label="Colour ramp",
    )
    expand_plot = mo.ui.switch(value=False, label="Expand plots")
    save_plot = mo.ui.switch(value=False, label="Save current map plot")

    time_controls = mo.vstack([
        mo.md("### Time-series controls"), origin_select, destination_select, flow_select, metric_select,
        climate_var_select, show_climate_switch, lag_select, standardize_switch, smooth_switch, smooth_window_slider,
    ])
    map_controls = mo.vstack([
        mo.md("### Map controls"), origin_select, destination_select, date_select, flow_select, climate_var_select,
        map_variable_select, destination_mode_select, top_n_select, min_flow_select, color_ramp_select, save_plot,
    ])
    simple_controls = mo.vstack([
        mo.md("### Controls"), origin_select, destination_select, date_select, flow_select, metric_select, color_ramp_select, expand_plot,
    ])
    return (
        climate_var_select,
        color_ramp_select,
        date_select,
        destination_labels,
        destination_mode_select,
        destination_select,
        expand_plot,
        flow_select,
        lag_select,
        map_controls,
        map_variable_select,
        metric_select,
        min_flow_select,
        origin_labels,
        origin_select,
        save_plot,
        show_climate_switch,
        smooth_switch,
        smooth_window_slider,
        standardize_switch,
        time_controls,
        top_n_select,
    )


@app.cell
def _(
    climate_var_select,
    climate_vars,
    date_select,
    destination_labels,
    destination_select,
    flow_select,
    map_metric_column,
    metric_select,
    origin_labels,
    origin_select,
):
    selected_origin_label = origin_select.value
    selected_origin_id = origin_labels[selected_origin_label]
    selected_destination_label = destination_select.value
    selected_destination_id = destination_labels[selected_destination_label]
    selected_date = date_select.value
    selected_flow = flow_select.value
    selected_metric = metric_select.value
    flow_col = "N_depart" if selected_flow == "Departures" else "N_return"
    y_col, y_label = map_metric_column(selected_flow, selected_metric)
    selected_climate_var = climate_var_select.value
    has_climate = selected_climate_var in climate_vars
    return (
        flow_col,
        has_climate,
        selected_climate_var,
        selected_date,
        selected_destination_id,
        selected_destination_label,
        selected_flow,
        selected_metric,
        selected_origin_id,
        selected_origin_label,
        y_col,
        y_label,
    )


@app.cell
def _(origin_time_lf, pl, selected_origin_id, unit_name_lookup):
    unit_ts = (
        origin_time_lf
        .filter(pl.col("norm_spatial_id_origin") == selected_origin_id)
        .sort("date")
        .collect()
    )
    origin_plot_name = unit_name_lookup.get(selected_origin_id, selected_origin_id)
    return (unit_ts,)


@app.cell
def _(od_lf, pl, selected_destination_id, selected_origin_id):
    od_pair_ts = (
        od_lf
        .filter(
            (pl.col("norm_spatial_id_origin") == selected_origin_id)
            & (pl.col("norm_spatial_id_destination") == selected_destination_id)
        )
        .sort("date")
        .collect()
    )
    return (od_pair_ts,)


@app.cell
def _(
    centered_moving_average,
    has_climate,
    lag_array,
    lag_select,
    mo,
    plt,
    selected_climate_var,
    selected_metric,
    selected_origin_label,
    show_climate_switch,
    smooth_switch,
    smooth_window_slider,
    standardize_switch,
    unit_ts,
    y_col,
    y_label,
    zscore_array,
):
    _dates = unit_ts["date"].to_list() if unit_ts.height > 0 else []
    mobility_values = unit_ts[y_col].to_list() if y_col in unit_ts.columns else []

    _use_smoothing = bool(smooth_switch.value)
    _window = int(smooth_window_slider.value)
    mobility_plot = centered_moving_average(mobility_values, _window) if _use_smoothing else mobility_values

    _show_climate = bool(show_climate_switch.value) and has_climate and selected_climate_var in unit_ts.columns

    _fig, _ax = plt.subplots(figsize=(9.5, 4.8))

    if unit_ts.height == 0:
        _ax.text(0.5, 0.5, "No records for selected origin", ha="center", va="center")
        _ax.axis("off")
    elif _show_climate:
        climate_raw = unit_ts[selected_climate_var].to_list()
        climate_lagged = lag_array(climate_raw, int(lag_select.value))
        _climate_plot = centered_moving_average(climate_lagged, _window) if _use_smoothing else climate_lagged
        _lag = int(lag_select.value)
        climate_label = f"{selected_climate_var}, lag {_lag}" if _lag != 0 else f"{selected_climate_var}, same period"

        if bool(standardize_switch.value):
            _ax.plot(_dates, zscore_array(mobility_plot), marker="o", linewidth=1.8, label=selected_metric)
            _ax.plot(_dates, zscore_array(_climate_plot), marker="s", linewidth=1.8, label=climate_label)
            _ax.axhline(0, linewidth=1.0, alpha=0.4)
            _ax.set_ylabel("Standardized value")
            _ax.legend(loc="best")
        else:
            _ax.plot(_dates, mobility_plot, marker="o", linewidth=1.8, label=selected_metric)
            _ax.set_ylabel(y_label)
            _ax2 = _ax.twinx()
            _ax2.plot(_dates, _climate_plot, marker="s", linewidth=1.8, linestyle="--", label=climate_label)
            _ax2.set_ylabel(selected_climate_var)
            lines1, labels1 = _ax.get_legend_handles_labels()
            lines2, labels2 = _ax2.get_legend_handles_labels()
            _ax.legend(lines1 + lines2, labels1 + labels2, loc="best")
        _ax.set_title(f"{y_label}: {selected_origin_label if False else ''}")
    else:
        _ax.plot(_dates, mobility_plot, marker="o", linewidth=1.8)
        _ax.set_ylabel(y_label)

    if unit_ts.height > 0:
        _ax.set_title(y_label)
        _ax.set_xlabel("Date")
        _ax.grid(True, alpha=0.3)
        _fig.autofmt_xdate()
    _fig.tight_layout()
    time_series_plot = mo.ui.matplotlib(_ax)
    return (time_series_plot,)


@app.cell
def _(
    centered_moving_average,
    flow_col,
    has_climate,
    lag_array,
    lag_select,
    mo,
    od_pair_ts,
    plt,
    selected_climate_var,
    selected_destination_label,
    selected_flow,
    selected_origin_label,
    show_climate_switch,
    smooth_switch,
    smooth_window_slider,
    standardize_switch,
    zscore_array,
):
    _dates = od_pair_ts["date"].to_list() if od_pair_ts.height > 0 else []
    _fig, _ax = plt.subplots(figsize=(9.5, 4.8))

    if od_pair_ts.height == 0:
        _ax.text(0.5, 0.5, "No OD-pair records for this selection", ha="center", va="center")
        _ax.axis("off")
    else:
        _use_smoothing = bool(smooth_switch.value)
        _window = int(smooth_window_slider.value)
        _flow_values = od_pair_ts[flow_col].to_list()
        flow_plot = centered_moving_average(_flow_values, _window) if _use_smoothing else _flow_values

        _show_climate = bool(show_climate_switch.value) and has_climate
        origin_col = f"origin_{selected_climate_var}"
        dest_col = f"destination_{selected_climate_var}"
        delta_col = f"delta_{selected_climate_var}"
        climate_col = delta_col if delta_col in od_pair_ts.columns else dest_col if dest_col in od_pair_ts.columns else None

        if _show_climate and climate_col is not None:
            climate_values = lag_array(od_pair_ts[climate_col].to_list(), int(lag_select.value))
            _climate_plot = centered_moving_average(climate_values, _window) if _use_smoothing else climate_values
            if bool(standardize_switch.value):
                _ax.plot(_dates, zscore_array(flow_plot), marker="o", linewidth=1.8, label=selected_flow)
                _ax.plot(_dates, zscore_array(_climate_plot), marker="s", linewidth=1.8, label=climate_col)
                _ax.axhline(0, linewidth=1.0, alpha=0.4)
                _ax.set_ylabel("Standardized value")
                _ax.legend(loc="best")
            else:
                _ax.plot(_dates, flow_plot, marker="o", linewidth=1.8, label=selected_flow)
                _ax.set_ylabel(selected_flow)
                _ax2 = _ax.twinx()
                _ax2.plot(_dates, _climate_plot, marker="s", linewidth=1.8, linestyle="--", label=climate_col)
                _ax2.set_ylabel(climate_col)
        else:
            _ax.plot(_dates, flow_plot, marker="o", linewidth=1.8)
            _ax.set_ylabel(selected_flow)

        _ax.set_title(f"OD-pair {selected_flow}\n{selected_origin_label} → {selected_destination_label}")
        _ax.set_xlabel("Date")
        _ax.grid(True, alpha=0.3)
        _fig.autofmt_xdate()

    _fig.tight_layout()
    od_pair_time_series_plot = mo.ui.matplotlib(_ax)
    return (od_pair_time_series_plot,)


@app.cell
def _(
    corr_ignore_nan,
    has_climate,
    mo,
    plt,
    selected_climate_var,
    selected_metric,
    unit_ts,
    y_col,
):
    _fig, _ax = plt.subplots(figsize=(8.8, 4.3))
    if not has_climate or selected_climate_var not in unit_ts.columns:
        _ax.text(0.5, 0.5, "No climate variable available", ha="center", va="center")
        _ax.axis("off")
    else:
        mobility = unit_ts[y_col].to_list()
        climate = unit_ts[selected_climate_var].to_list()
        lags = list(range(-6, 7))
        corr = []
        for _lag in lags:
            # inline to avoid pandas: positive lag means climate before mobility
            import numpy as _np
            arr = _np.asarray([_np.nan if v is None else float(v) for v in climate], dtype=float)
            shifted = _np.full(len(arr), _np.nan, dtype=float)
            if _lag == 0:
                shifted = arr
            elif _lag > 0:
                shifted[_lag:] = arr[:-_lag]
            else:
                shifted[:_lag] = arr[-_lag:]
            corr.append(corr_ignore_nan(mobility, shifted))
        _ax.bar(lags, corr)
        _ax.axhline(0, linewidth=1.0)
        _ax.axvline(0, linestyle="--", linewidth=1.0)
        _ax.set_title(f"Lead-lag correlation: {selected_metric} vs {selected_climate_var}")
        _ax.set_xlabel("Climate lag: positive = climate before mobility")
        _ax.set_ylabel("Correlation")
        _ax.grid(True, axis="y", alpha=0.3)
    _fig.tight_layout()
    lag_correlation_plot = mo.ui.matplotlib(_ax)
    return (lag_correlation_plot,)


@app.cell
def _(origin_time_lf, pl, selected_date, y_col):
    map_metric_df = (
        origin_time_lf
        .filter(pl.col("date") == selected_date)
        .select([pl.col("norm_spatial_id_origin"), pl.col(y_col)])
        .collect()
    )
    map_values_by_id = dict(zip(map_metric_df["norm_spatial_id_origin"].to_list(), map_metric_df[y_col].to_list()))
    return (map_values_by_id,)


@app.cell
def _(
    Path,
    color_ramp_select,
    map_values_by_id,
    mo,
    plot_boundaries,
    plot_polygons,
    plt,
    save_plot,
    selected_date,
    selected_flow,
    selected_metric,
    selected_origin_id,
    set_equal_extent,
    unit_geoms,
    unit_ids,
    unit_index_lookup,
    y_label,
):
    _fig, _ax = plt.subplots(figsize=(8, 8))
    _values = [map_values_by_id.get(uid) for uid in unit_ids]
    plot_polygons(_ax, unit_geoms, values=_values, cmap=color_ramp_select.value, legend=True, legend_label=y_label)
    _origin_idx = unit_index_lookup.get(selected_origin_id)
    if _origin_idx is not None:
        plot_boundaries(_ax, [unit_geoms[_origin_idx]], color="black", linewidth=2.5)
    set_equal_extent(_ax, unit_geoms)
    _ax.set_title(f"{selected_metric} map, {selected_flow}, {selected_date}")
    _fig.tight_layout()
    if save_plot.value:
        plot_dir = Path("./plots")
        plot_dir.mkdir(parents=True, exist_ok=True)
        safe_metric = selected_metric.lower().replace(" ", "_").replace("-", "_")
        safe_flow = selected_flow.lower().replace(" ", "_")
        output_path = plot_dir / f"{safe_flow}_{safe_metric}_{str(selected_date).replace('-', '')}_{selected_origin_id}.png"
        _fig.savefig(output_path, dpi=300, bbox_inches="tight")
        print(f"Saved plot to {output_path}")
    metric_map = mo.ui.matplotlib(_ax)
    return (metric_map,)


@app.cell
def _(
    contig_lf,
    geoms_by_ids,
    mo,
    pl,
    plot_boundaries,
    plot_polygons,
    plt,
    selected_origin_id,
    set_equal_extent,
    unit_geoms,
    unit_index_lookup,
    unit_name_lookup,
):
    neighbor_table = contig_lf.filter(pl.col("origin_id") == selected_origin_id).collect()
    if neighbor_table.height > 0:
        _names = [unit_name_lookup.get(uid, uid) for uid in neighbor_table["neighbor_id"].to_list()]
        neighbor_table = neighbor_table.with_columns(pl.Series("neighbor_name", _names))
    neighbor_ids = neighbor_table["neighbor_id"].to_list() if neighbor_table.height > 0 else []
    neighbor_geoms = geoms_by_ids(neighbor_ids, unit_index_lookup, unit_geoms)
    _origin_idx = unit_index_lookup.get(selected_origin_id)

    _fig, _ax = plt.subplots(figsize=(8, 8))
    plot_polygons(_ax, unit_geoms, facecolor="lightgrey", edgecolor="white", linewidth=0.2)
    plot_polygons(_ax, neighbor_geoms, facecolor="0.45", edgecolor="black", linewidth=0.5)
    if _origin_idx is not None:
        plot_boundaries(_ax, [unit_geoms[_origin_idx]], color="black", linewidth=2.5)
    set_equal_extent(_ax, unit_geoms)
    _ax.set_title(f"Queen contiguity neighbours")
    _fig.tight_layout()
    weights_map = mo.ui.matplotlib(_ax)
    return neighbor_table, weights_map


@app.cell
def _(
    destination_mode_select,
    flow_col,
    has_climate,
    map_variable_select,
    min_flow_select,
    od_lf,
    pl,
    selected_climate_var,
    selected_date,
    selected_destination_id,
    selected_origin_id,
    top_n_select,
):
    schema_od = od_lf.collect_schema()
    origin_clim_col = f"origin_{selected_climate_var}"
    dest_clim_col = f"destination_{selected_climate_var}"
    delta_clim_col = f"delta_{selected_climate_var}"

    _dest_agg_exprs = [
        pl.col(flow_col).sum().alias("flow_value"),
        pl.col("centroid_distance_km").first().alias("centroid_distance_km"),
        pl.col("distance_band_km").first().alias("distance_band_km"),
        pl.col("origin_distance_rank").first().alias("origin_distance_rank"),
        pl.col("is_adjacent").first().alias("is_adjacent"),
        pl.col("is_top5_nearest").first().alias("is_top5_nearest"),
        (pl.col(origin_clim_col).first() if has_climate and origin_clim_col in schema_od else pl.lit(None)).alias("origin_climate"),
        (pl.col(dest_clim_col).first() if has_climate and dest_clim_col in schema_od else pl.lit(None)).alias("destination_climate"),
        (pl.col(delta_clim_col).first() if has_climate and delta_clim_col in schema_od else pl.lit(None)).alias("climate_difference"),
    ]

    base_filter = (
        (pl.col("norm_spatial_id_origin") == selected_origin_id)
        & (pl.col("date") == selected_date)
        & (pl.col(flow_col) > float(min_flow_select.value))
    )
    if destination_mode_select.value == "Selected destination only":
        base_filter = base_filter & (pl.col("norm_spatial_id_destination") == selected_destination_id)

    dest_query = (
        od_lf.filter(base_filter)
        .group_by(["norm_spatial_id_destination", "destination_name"])
        .agg(_dest_agg_exprs)
        .sort("flow_value", descending=True)
    )
    if destination_mode_select.value == "Top destinations":
        dest_query = dest_query.head(int(top_n_select.value))
    dest_flows = dest_query.collect()

    selected_map_variable = map_variable_select.value
    if selected_map_variable == "Flow value":
        color_col = "flow_value"
        color_label = "Flow value"
    elif selected_map_variable == "Distance from origin":
        color_col = "centroid_distance_km"
        color_label = "Distance from origin, km"
    elif selected_map_variable == "Spatial rank":
        color_col = "origin_distance_rank"
        color_label = "Spatial rank from origin"
    elif selected_map_variable == "Destination climate":
        color_col = "destination_climate"
        color_label = f"Destination {selected_climate_var}"
    elif selected_map_variable == "Origin climate":
        color_col = "origin_climate"
        color_label = f"Origin {selected_climate_var}"
    else:
        color_col = "climate_difference"
        color_label = f"Destination - origin {selected_climate_var}"

    if color_col in {"origin_climate", "destination_climate", "climate_difference"} and not has_climate:
        color_col = "flow_value"
        color_label = "Flow value"
    return color_col, color_label, dest_flows


@app.cell
def _(
    color_col,
    color_label,
    color_ramp_select,
    dest_flows,
    geoms_by_ids,
    mo,
    pl,
    plot_boundaries,
    plot_polygons,
    plt,
    representative_xy,
    selected_date,
    selected_destination_id,
    selected_flow,
    selected_origin_id,
    set_equal_extent,
    unit_geoms,
    unit_index_lookup,
    unit_name_lookup,
):
    dest_ids = dest_flows["norm_spatial_id_destination"].to_list() if dest_flows.height > 0 else []
    dest_geoms = geoms_by_ids(dest_ids, unit_index_lookup, unit_geoms)
    color_values = dest_flows[color_col].to_list() if dest_flows.height > 0 and color_col in dest_flows.columns else []
    _flow_values = dest_flows["flow_value"].to_list() if dest_flows.height > 0 else []
    _origin_idx = unit_index_lookup.get(selected_origin_id)
    _selected_dest_idx = unit_index_lookup.get(selected_destination_id)

    _fig, _ax = plt.subplots(figsize=(8, 8))
    plot_polygons(_ax, unit_geoms, facecolor="lightgrey", edgecolor="white", linewidth=0.2)
    if dest_geoms:
        plot_polygons(_ax, dest_geoms, values=color_values, cmap=color_ramp_select.value, legend=True, legend_label=color_label, edgecolor="black", linewidth=0.4)
    if _origin_idx is not None:
        plot_boundaries(_ax, [unit_geoms[_origin_idx]], color="black", linewidth=2.5)
    if _selected_dest_idx is not None:
        plot_boundaries(_ax, [unit_geoms[_selected_dest_idx]], color="black", linewidth=2.2, linestyle="--")

    if _origin_idx is not None and dest_geoms:
        origin_xy = representative_xy(unit_geoms[_origin_idx])
        max_flow = max([float(v) for v in _flow_values if v is not None], default=0)
        if origin_xy and max_flow > 0:
            for _dest_geom, flow in zip(dest_geoms, _flow_values):
                dest_xy = representative_xy(_dest_geom)
                if dest_xy is None or flow is None:
                    continue
                width = 0.5 + 4 * (float(flow) / max_flow)
                _ax.plot([origin_xy[0], dest_xy[0]], [origin_xy[1], dest_xy[1]], linewidth=width, alpha=0.55)

    set_equal_extent(_ax, unit_geoms)
    _ax.set_title(f"{selected_flow} flow map\nColour: {color_label}, date: {selected_date}")
    _fig.tight_layout()
    flow_map_native = mo.ui.matplotlib(_ax)

    if dest_flows.height > 0:
        _names = [unit_name_lookup.get(uid, uid) for uid in dest_flows["norm_spatial_id_destination"].to_list()]
        dest_flows_display = dest_flows.with_columns(pl.Series("destination_plot_name", _names))
    else:
        dest_flows_display = dest_flows
    return dest_flows_display, flow_map_native


@app.cell
def _(
    color_ramp_select,
    has_climate,
    mo,
    origin_time_lf,
    pl,
    plot_boundaries,
    plot_polygons,
    plt,
    selected_climate_var,
    selected_date,
    selected_origin_id,
    set_equal_extent,
    unit_geoms,
    unit_ids,
    unit_index_lookup,
):
    _fig, _ax = plt.subplots(figsize=(8, 8))
    if not has_climate:
        _ax.text(0.5, 0.5, "No climate variable available", ha="center", va="center")
        _ax.axis("off")
    else:
        climate_df = (
            origin_time_lf
            .filter(pl.col("date") == selected_date)
            .select([pl.col("norm_spatial_id_origin"), pl.col(selected_climate_var)])
            .collect()
        )
        clim_by_id = dict(zip(climate_df["norm_spatial_id_origin"].to_list(), climate_df[selected_climate_var].to_list()))
        _values = [clim_by_id.get(uid) for uid in unit_ids]
        plot_polygons(_ax, unit_geoms, values=_values, cmap=color_ramp_select.value, legend=True, legend_label=selected_climate_var)
        _origin_idx = unit_index_lookup.get(selected_origin_id)
        if _origin_idx is not None:
            plot_boundaries(_ax, [unit_geoms[_origin_idx]], color="black", linewidth=2.5)
        set_equal_extent(_ax, unit_geoms)
        _ax.set_title(f"{selected_climate_var}, {selected_date}")
    _fig.tight_layout()
    climate_map_plot = mo.ui.matplotlib(_ax)
    return (climate_map_plot,)


@app.cell
def _(
    LineCollection,
    contig_lf,
    mo,
    plot_polygons,
    plt,
    representative_xy,
    set_equal_extent,
    unit_geoms,
    unit_index_lookup,
):
    # ------------------------------------------------------------------
    # Static Queen-contiguity network map.
    # This is not controlled by the origin/date widgets; it is a fixed
    # diagnostic map of the full spatial weights graph.
    # ------------------------------------------------------------------
    _edges = contig_lf.collect()

    _segments = []
    if _edges.height > 0:
        for _row in _edges.iter_rows(named=True):
            _origin_idx = unit_index_lookup.get(_row["origin_id"])
            _neighbor_idx = unit_index_lookup.get(_row["neighbor_id"])
            if _origin_idx is None or _neighbor_idx is None:
                continue
            _origin_xy = representative_xy(unit_geoms[_origin_idx])
            _neighbor_xy = representative_xy(unit_geoms[_neighbor_idx])
            if _origin_xy is None or _neighbor_xy is None:
                continue
            _segments.append([_origin_xy, _neighbor_xy])

    _fig, _ax = plt.subplots(figsize=(8, 8))

    # Background polygons
    plot_polygons(
        _ax,
        unit_geoms,
        facecolor="none",
        edgecolor="0.85",
        linewidth=0.45,
    )

    # Contiguity graph edges
    if _segments:
        _line_collection = LineCollection(
            _segments,
            colors="0.10",
            linewidths=0.75,
            alpha=0.85,
        )
        _ax.add_collection(_line_collection)

    # Unit representative points / graph nodes
    _node_xy = [representative_xy(_geom) for _geom in unit_geoms]
    _node_xy = [_xy for _xy in _node_xy if _xy is not None]
    if _node_xy:
        _node_x = [_xy[0] for _xy in _node_xy]
        _node_y = [_xy[1] for _xy in _node_xy]
        _ax.scatter(
            _node_x,
            _node_y,
            s=14,
            facecolors="white",
            edgecolors="0.10",
            linewidths=0.7,
            zorder=3,
        )

    set_equal_extent(_ax, unit_geoms)
    _ax.set_title("Static Queen-contiguity spatial weights network")
    _fig.tight_layout()

    contiguity_network_plot = mo.ui.matplotlib(_ax)
    return (contiguity_network_plot,)


@app.cell
def _(
    climate_map_plot,
    contiguity_network_plot,
    dest_flows_display,
    expand_plot,
    flow_map_native,
    lag_correlation_plot,
    map_controls,
    metric_map,
    mo,
    neighbor_table,
    od_pair_time_series_plot,
    time_controls,
    time_series_plot,
    weights_map,
):
    def build_layout(plot_widget, left_widget):
        if expand_plot.value:
            return mo.vstack([left_widget, plot_widget])
        return mo.hstack([left_widget, plot_widget], widths=[1, 3])

    mo.ui.tabs({
        "Origin time series": build_layout(time_series_plot, time_controls),
        "OD-pair time series": build_layout(od_pair_time_series_plot, time_controls),
        "Lead-lag correlation": build_layout(lag_correlation_plot, time_controls),
        "Metric map": build_layout(metric_map, map_controls),
        "Climate map": build_layout(climate_map_plot, map_controls),
        "Contiguity weights": mo.hstack([mo.vstack([map_controls, mo.md("### Queen neighbours"), mo.ui.table(neighbor_table)]), weights_map], widths=[1, 3]),
        "Static contiguity network": contiguity_network_plot,
        "Flow map": mo.hstack([mo.vstack([map_controls, mo.md("### Destination flows"), mo.ui.table(dest_flows_display)]), flow_map_native], widths=[1, 3]),
    })
    return


if __name__ == "__main__":
    app.run()
