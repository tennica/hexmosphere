#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Tile USGS historical topo maps (1930-1970) along a Demo Drive route, for the "1950s maps" layer.

    vintage-topo.py <topo-folder> <route.json> <work-folder> <tiles-folder>

<topo-folder> is what vintage-fetch.py topo leaves: sheets.json and tif/<scale>/*.tif. Each
sheet is cropped to its map edges (its corners are in NAD27 in sheets.json), dropping the
printed margin so neighbouring sheets meet, and reprojected to Web Mercator. The sheets of
each scale are joined, clipped to that scale's chain of hexagons along the route
(chain-<scale>.geojson, from vintage-fetch.py: 17 km cells for 1:250,000, 6 km for
1:62,500, 2.4 km for 1:24,000), and cut into WebP tiles, each scale for the zooms it reads
best at: 1:250,000 for zooms 8 to 11, 1:62,500 for 12 and 13, 1:24,000 for 14 and 15.
USGS maps are public domain.
"""

import json
import os
import subprocess
import sys
import urllib.parse

from osgeo import gdal

gdal.UseExceptions()
ZOOMS = {250000: "8-11", 62500: "12-13", 24000: "14-15"}


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


def main():
    topo, route, work, tiles = sys.argv[1:]
    os.makedirs(work, exist_ok=True)
    sheets = json.load(open(f"{topo}/sheets.json"))
    os.makedirs(tiles, exist_ok=True)
    for scale, zooms in ZOOMS.items():
        cropped = []
        for sheet in (s for s in sheets if s["scale"] == scale):
            name = urllib.parse.unquote(os.path.basename(sheet["url"]))  # as vintage-fetch.py saved it
            tif = f"{topo}/tif/{scale}/{name}"
            out = f"{work}/{scale}/{name}"
            if not os.path.exists(out):
                os.makedirs(os.path.dirname(out), exist_ok=True)
                try:
                    crop(tif, sheet, out)
                except subprocess.CalledProcessError:
                    print(f"skipped {name}: could not crop")
                    continue
            cropped.append(out)
        # Later (closer to 1955) sheets were chosen per cell; overlaps only at the trimmed edges.
        vrt = f"{work}/{scale}.vrt"
        gdal.BuildVRT(vrt, cropped, srcNodata=None)
        clipped = f"{work}/{scale}-chain.tif"
        subprocess.run(["gdalwarp", "-q", "-overwrite", "-cutline", f"{topo}/chain-{scale}.geojson", "-crop_to_cutline",
                        "-dstalpha", "-co", "COMPRESS=DEFLATE", "-co", "TILED=YES", "-co", "BIGTIFF=YES",
                        "-wo", "NUM_THREADS=ALL_CPUS", "-multi", vrt, clipped], check=True)
        subprocess.run(["gdal2tiles.py", "--xyz", "-z", zooms, "-w", "none", "-r", "average", "--tiledriver=WEBP",
                        f"--processes={os.cpu_count()}", clipped, tiles], check=True)
        print(f"1:{scale}: {len(cropped)} sheets tiled for zooms {zooms}")
    # What the app shows for this layer (Basemap/vintage/<name>/layer.json).
    json.dump({"title": "1950s maps", "credit": "USGS topographic maps, 1930–70",
               "minZoom": 8, "maxZoom": 15}, open(f"{tiles}/layer.json", "w"))
    count = sum(len(files) for _, _, files in os.walk(tiles))
    size = sum(os.path.getsize(os.path.join(d, f)) for d, _, files in os.walk(tiles) for f in files)
    print(f"{count} tiles, {size / 1e6:.0f} MB in {tiles}")


if __name__ == "__main__":
    main()
