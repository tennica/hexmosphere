#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Tile Landsat 1 imagery (1972–78; the Route 66 scenes are 1972–75) along a Demo Drive route, for the "1970s satellite" layer.

    vintage-landsat.py <scenes-folder> <work-folder> <tiles-folder>

<scenes-folder> holds one folder per scene with its MSS bands (…_B4.TIF to …_B7.TIF), as
vintage-fetch.py landsat chose and fetched them for the route. Each scene becomes a false-colour image in the
style Landsat pictures were printed in the 1970s (near infrared, red and green as red, green
and blue, so vegetation shows red). Each band is stretched between its 2nd and 98th
percentiles over all the scenes together, so neighbouring scenes match. Each scene's
ragged edge is trimmed by EDGE pixels, so no half-empty border pixels show where scenes
meet. The whole scenes are joined (a swath about 185 km wide along the route, so the drive
crosses a landscape rather than a strip), reprojected to Web Mercator, and cut into WebP
tiles for zooms 5 to 11 (MSS pixels are about 60 m, so nothing more shows past zoom 11).
Landsat imagery is public domain (USGS).
"""

import glob
import json
import os
import subprocess
import sys

import numpy
from osgeo import gdal

gdal.UseExceptions()
EDGE = 4  # pixels trimmed from each scene's edge
ZOOMS = "5-11"


BANDS = ("B7", "B5", "B4")


def limits(scenes):
    """Each band's 2nd and 98th percentiles over every scene, from every 8th pixel."""
    samples = [[] for _ in BANDS]
    for scene in scenes:
        data = []
        for b in BANDS:
            source = gdal.Open(glob.glob(f"{scene}/*_{b}.TIF")[0])
            data.append(source.GetRasterBand(1).ReadAsArray()[::8, ::8])
        valid = numpy.logical_and.reduce([a > 0 for a in data])
        for i, a in enumerate(data):
            samples[i].append(a[valid])
    return [tuple(numpy.percentile(numpy.concatenate(s), (2, 98))) for s in samples]


def false_colour(scene, out, limits):
    """One scene's bands 7, 5 and 4 as an 8-bit RGB GeoTIFF, 0 meaning no data."""
    bands = [glob.glob(f"{scene}/*_{b}.TIF")[0] for b in BANDS]
    first = gdal.Open(bands[0])
    rgb = gdal.GetDriverByName("GTiff").Create(out, first.RasterXSize, first.RasterYSize, 3, gdal.GDT_Byte,
                                               ["COMPRESS=DEFLATE", "TILED=YES"])
    rgb.SetGeoTransform(first.GetGeoTransform())
    rgb.SetProjection(first.GetProjection())
    valid = None
    data = []
    for path in bands:
        source = gdal.Open(path)   # kept, or the band outlives its dataset
        a = source.GetRasterBand(1).ReadAsArray().astype(numpy.float32)
        valid = (a > 0) if valid is None else valid & (a > 0)
        data.append(a)
    # Trim the edge: a pixel stays only if everything within EDGE pixels has data too.
    for _ in range(EDGE):
        valid = valid & numpy.roll(valid, 1, 0) & numpy.roll(valid, -1, 0) & numpy.roll(valid, 1, 1) & numpy.roll(valid, -1, 1)
    for i, a in enumerate(data):
        low, high = limits[i]
        scaled = numpy.clip((a - low) / max(high - low, 1) * 254 + 1, 1, 255)
        band = rgb.GetRasterBand(i + 1)
        band.WriteArray(numpy.where(valid, scaled, 0).astype(numpy.uint8))
        band.SetNoDataValue(0)
    rgb = None


def main():
    scenes, work, tiles = sys.argv[1:]
    os.makedirs(work, exist_ok=True)
    folders = sorted(glob.glob(f"{scenes}/*/"))
    stretch = limits(folders)
    print("stretch, band by band:", [(round(low), round(high)) for low, high in stretch])
    coloured = []
    for scene in folders:
        out = f"{work}/{os.path.basename(scene.rstrip('/'))}_rgb.tif"
        false_colour(scene, out, stretch)
        coloured.append(out)
    print(f"{len(coloured)} scenes in false colour")
    mosaic = f"{work}/mosaic-3857.tif"
    subprocess.run(["gdalwarp", "-overwrite", "-t_srs", "EPSG:3857", "-tr", "60", "60", "-r", "bilinear",
                    "-srcnodata", "0", "-dstalpha",
                    "-co", "COMPRESS=DEFLATE", "-co", "TILED=YES", "-co", "BIGTIFF=YES",
                    "-wo", "NUM_THREADS=ALL_CPUS", "-multi", *coloured, mosaic], check=True)
    os.makedirs(tiles, exist_ok=True)   # gdal2tiles makes only the last folder
    subprocess.run(["gdal2tiles.py", "--xyz", "-z", ZOOMS, "-w", "none", "-r", "average", "--tiledriver=WEBP",
                    f"--processes={os.cpu_count()}", mosaic, tiles], check=True)
    # What the app shows for this layer (Basemap/vintage/<name>/layer.json), dated by the
    # scenes used: a product id's fourth part is the day it was taken (LM01_L1TP_023031_19730609_…).
    years = sorted(os.path.basename(s.rstrip("/")).split("_")[3][:4] for s in folders)
    dates = years[0] if years[0] == years[-1] else f"{years[0]}–{years[-1][2:]}"
    json.dump({"title": "1970s satellite", "credit": f"Landsat 1, {dates} (NASA/USGS)",
               "minZoom": 5, "maxZoom": 11}, open(f"{tiles}/layer.json", "w"))
    count = sum(len(files) for _, _, files in os.walk(tiles))
    size = sum(os.path.getsize(os.path.join(d, f)) for d, _, files in os.walk(tiles) for f in files)
    print(f"{count} tiles, {size / 1e6:.0f} MB in {tiles}")


if __name__ == "__main__":
    main()
