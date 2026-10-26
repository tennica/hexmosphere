#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Tile USGS historical topo maps (1930-1970) along a Demo Drive route, for the "1950s maps" layer.

    vintage-topo.py <topo-folder> <route.json> <work-folder> <tiles-folder>

<topo-folder> is what vintage-fetch.py topo leaves: sheets.json and tif/<scale>/*.tif. Each
sheet is cropped to its map edges (its corners are in NAD27 in sheets.json), dropping the
printed margin so neighbouring sheets meet, and reprojected to Web Mercator. Each sheet is
then clipped to the cells near it in that scale's chain of hexagons along the route
(chain-<scale>.geojson, from vintage-fetch.py: 17 km cells for 1:250,000, 6 km for
1:62,500, 2.4 km for 1:24,000), and the sheets of each scale are joined and cut into WebP tiles, each scale for the zooms it reads
best at: 1:250,000 for zooms 8 to 11, 1:62,500 for 12 and 13, 1:24,000 for 14 and 15.
USGS maps are public domain.
"""

import concurrent.futures
import json
import math
import os
import subprocess
import sys
import threading
import urllib.parse

from osgeo import gdal

gdal.UseExceptions()
ZOOMS = {250000: range(8, 12), 62500: range(12, 14), 24000: range(14, 16)}


def crop(tif, sheet, out):
    """The sheet inside its map edges, reprojected to Web Mercator, with the rest transparent.
    Written beside out and renamed when whole, so a stopped run leaves no half sheet."""
    cutline = out + ".edges.geojson"
    part = out + ".part"
    w, s, e, n = sheet["west"], sheet["south"], sheet["east"], sheet["north"]
    json.dump({"type": "FeatureCollection", "crs": {"type": "name", "properties": {"name": "EPSG:4267"}},
               "features": [{"type": "Feature", "properties": {},
                             "geometry": {"type": "Polygon", "coordinates": [[[w, s], [e, s], [e, n], [w, n], [w, s]]]}}]},
              open(cutline, "w"))
    try:
        subprocess.run(["gdalwarp", "-q", "-overwrite", "-of", "GTiff", "-t_srs", "EPSG:3857", "-r", "bilinear",
                        "-dstalpha", "-cutline", cutline, "-crop_to_cutline", "-co", "COMPRESS=DEFLATE",
                        "-co", "TILED=YES", "-wo", "NUM_THREADS=ALL_CPUS", tif, part], check=True)
        os.replace(part, out)
    finally:
        os.remove(cutline)
        if os.path.exists(part):
            os.remove(part)


def clip(cropped, cells, out):
    """A cropped sheet with everything outside the given hexagons transparent, written whole or not at all.
    Each sheet is clipped to only the cells near it: clipping the joined sheets to the whole chain makes a
    raster the size of the route's bounding box, nearly all of it empty, and took hours."""
    cutline = out + ".cells.geojson"
    part = out + ".part"
    json.dump({"type": "FeatureCollection", "features": cells}, open(cutline, "w"))
    try:
        subprocess.run(["gdalwarp", "-q", "-overwrite", "-of", "GTiff", "-cutline", cutline, "-dstalpha",
                        "-co", "COMPRESS=DEFLATE", "-co", "TILED=YES", "-wo", "NUM_THREADS=ALL_CPUS", "-multi",
                        cropped, part], check=True)
        os.replace(part, out)
    finally:
        os.remove(cutline)
        if os.path.exists(part):
            os.remove(part)


HALF = 20037508.342789244  # half the width of the Web Mercator world, in metres


def tile_xy(lng, lat, z):
    """The XYZ tile holding a point at zoom z."""
    n = 1 << z
    x = int((lng + 180) / 360 * n)
    y = int((1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * n)
    return min(max(x, 0), n - 1), min(max(y, 0), n - 1)


def tiles_over(chain, z):
    """Every tile at zoom z that a cell of the chain touches (by the cell's bounds)."""
    tiles = set()
    for cell in chain:
        ring = cell["geometry"]["coordinates"][0]
        x0, y0 = tile_xy(min(p[0] for p in ring), max(p[1] for p in ring), z)
        x1, y1 = tile_xy(max(p[0] for p in ring), min(p[1] for p in ring), z)
        tiles.update((x, y) for x in range(x0, x1 + 1) for y in range(y0, y1 + 1))
    return tiles


def tile(vrt, zooms, chain, folder):
    """Cuts the joined sheets into 256-pixel WebP tiles at each zoom, as gdal2tiles --xyz would, but only
    where the chain is and on every core: gdal2tiles visits every tile in the route's bounding box, nearly
    all of them empty, and here ran in one process. Fully transparent tiles aren't written."""
    local = threading.local()
    webp = gdal.GetDriverByName("WEBP")
    gdal.SetConfigOption("GDAL_PAM_ENABLED", "NO")  # no .aux.xml beside every tile

    def one(job):
        z, x, y = job
        if not hasattr(local, "source"):
            local.source = gdal.Open(vrt)
        size = 2 * HALF / (1 << z)
        west, north = -HALF + x * size, HALF - y * size
        try:
            image = gdal.Warp("", local.source, format="MEM", outputBounds=(west, north - size, west + size, north),
                              width=256, height=256, resampleAlg="average")
        except RuntimeError:
            return 0
        if image.RasterCount < 4 or not image.GetRasterBand(4).ReadAsArray().any():
            return 0
        os.makedirs(f"{folder}/{z}/{x}", exist_ok=True)
        webp.CreateCopy(f"{folder}/{z}/{x}/{y}.webp", image, options=["QUALITY=75"])
        return 1

    jobs = [(z, x, y) for z in zooms for x, y in sorted(tiles_over(chain, z))]
    with concurrent.futures.ThreadPoolExecutor(os.cpu_count()) as pool:
        written = sum(pool.map(one, jobs, chunksize=64))
    return len(jobs), written


def near(cell, sheet, pad=0.01):
    """Whether a cell's bounds overlap the sheet's (degrees; pad covers NAD27 against WGS84)."""
    ring = cell["geometry"]["coordinates"][0]
    xs, ys = [p[0] for p in ring], [p[1] for p in ring]
    return (min(xs) < sheet["east"] + pad and max(xs) > sheet["west"] - pad and
            min(ys) < sheet["north"] + pad and max(ys) > sheet["south"] - pad)


def main():
    topo, route, work, tiles = sys.argv[1:]
    os.makedirs(work, exist_ok=True)
    sheets = json.load(open(f"{topo}/sheets.json"))
    os.makedirs(tiles, exist_ok=True)
    for scale, zooms in ZOOMS.items():
        chain = json.load(open(f"{topo}/chain-{scale}.geojson"))["features"]
        clipped = []
        for sheet in (s for s in sheets if s["scale"] == scale):
            name = urllib.parse.unquote(os.path.basename(sheet["url"]))  # as vintage-fetch.py saved it
            tif = f"{topo}/tif/{scale}/{name}"
            cropped = f"{work}/{scale}/{name}"
            out = f"{work}/{scale}-chain/{name}"
            try:
                if not os.path.exists(cropped):
                    os.makedirs(os.path.dirname(cropped), exist_ok=True)
                    crop(tif, sheet, cropped)
                if not os.path.exists(out):
                    cells = [c for c in chain if near(c, sheet)]
                    if not cells:
                        continue
                    os.makedirs(os.path.dirname(out), exist_ok=True)
                    clip(cropped, cells, out)
            except subprocess.CalledProcessError:
                print(f"skipped {name}: could not crop or clip")
                continue
            clipped.append(out)
        # Sheets overlap only at their trimmed edges; the tiles are cut from the joined sheets in a VRT.
        vrt = f"{work}/{scale}-chain.vrt"
        gdal.BuildVRT(vrt, clipped, srcNodata=None)
        tried, written = tile(vrt, zooms, chain, tiles)
        print(f"1:{scale}: {len(clipped)} sheets, {written} of {tried} tiles written for zooms {zooms[0]}-{zooms[-1]}")
    # What the app shows for this layer (Basemap/vintage/<name>/layer.json). levels, each scale's
    # deepest zoom, lets the app draw each scale over the enlarged coarser ones.
    json.dump({"title": "1950s maps", "credit": "USGS topographic maps, 1930–70",
               "minZoom": 8, "maxZoom": 15, "levels": [zooms[-1] for zooms in ZOOMS.values()]},
              open(f"{tiles}/layer.json", "w"))
    count = sum(len(files) for _, _, files in os.walk(tiles))
    size = sum(os.path.getsize(os.path.join(d, f)) for d, _, files in os.walk(tiles) for f in files)
    print(f"{count} tiles, {size / 1e6:.0f} MB in {tiles}")


if __name__ == "__main__":
    main()
