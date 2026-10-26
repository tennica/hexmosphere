#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Fetch vintage imagery along a Demo Drive route, for the app's vintage layers.

    vintage-fetch.py topo    <route.json> <cache>   # USGS historical topo maps, 1930-1970
    vintage-fetch.py landsat <route.json> <cache>   # Landsat 1 scenes, 1972-1978 (in practice 1972-75)

Both are US government work, so public domain, and come from public servers that need no
account: the USGS Historical Topographic Map Collection index and its GeoTIFFs on
prd-tnm.s3.amazonaws.com, and Landsat Collection 1 on Google's public bucket. Downloads go
to <cache>/topo and <cache>/landsat1; files already there are skipped, so a run picks up
where the last one stopped.

topo keeps, for each map sheet that touches the route's chain of hexagons at that scale
(CHAINS: the H3 cells the route passes through and one ring round them, made by
tools/hexchain.c and saved as <cache>/topo/chain-<scale>.geojson, which vintage-topo.py clips
to), the edition dated closest to 1955 between 1930 and 1970.

landsat keeps one scene per orbit slot (WRS path and row) over the route: terrain-corrected
(L1TP), under 10% cloud, preferring summer (June to September) so that neighbouring scenes
look alike, and early in the mission (1972-73, then 1974-75), when the scanner's detectors
were still sound. Each scene is checked for scan-line striping once downloaded (rows that
differ from their neighbours far more than columns do), and a striped one gives way to the
slot's next choice. Landsat 1's scanner wore through 1975, so late scenes stripe most.
"""

import csv
import gzip
import io
import json
import os
import subprocess
import sys
import urllib.parse
import urllib.request
import zipfile

UA = "hexmosphere-basemap/0.1 (+https://github.com/tennica/hexmosphere)"
# Each topo scale's chain of hexagons: (H3 resolution, rings round the route's cells).
# Resolution 5 cells are about 17 km across, 6 about 6 km, 7 about 2.4 km.
CHAINS = {250000: (5, 1), 62500: (6, 1), 24000: (7, 1)}
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOPO_INDEX = "https://thor-f5.er.usgs.gov/ngtoc/metadata/misc/topomaps_all.zip"
LANDSAT_INDEX = "https://storage.googleapis.com/gcp-public-data-landsat/index.csv.gz"


def fetch(url, out):
    """Download url to out unless it's already there, through a .part file."""
    if os.path.exists(out) and os.path.getsize(out) > 0:
        return
    os.makedirs(os.path.dirname(out), exist_ok=True)
    subprocess.run(["curl", "-fsSL", "--retry", "3", "-A", UA, url, "-o", out + ".part"], check=True)
    os.replace(out + ".part", out)


def near(points, west, east, south, north, pad):
    return any(west - pad <= x <= east + pad and south - pad <= y <= north + pad for x, y in points)


def hexchain(points, resolution, rings, out):
    """The route's chain of H3 cells as GeoJSON at out, from tools/hexchain.c (built here,
    against the vendored H3, the first time); returns each cell's bounds (w, s, e, n)."""
    tool = f"{ROOT}/build/hexchain"
    if not os.path.exists(tool):
        h3 = f"{ROOT}/Packages/CH3/Sources/CH3"
        sources = sorted(os.path.join(h3, f) for f in os.listdir(h3) if f.endswith(".c"))
        os.makedirs(os.path.dirname(tool), exist_ok=True)
        subprocess.run(["clang", "-O2", "-w", f"-I{h3}/include", f"-I{h3}", *sources,
                        f"{ROOT}/tools/hexchain.c", "-o", tool], check=True)
    # About every 500 m, so no cell along the way is skipped.
    dense = []
    for (x0, y0), (x1, y1) in zip(points, points[1:]):
        steps = max(1, int(max(abs(x1 - x0), abs(y1 - y0)) / 0.005))
        dense += [(x0 + (x1 - x0) * i / steps, y0 + (y1 - y0) * i / steps) for i in range(steps)]
    dense.append(points[-1])
    with open(out, "w") as chain:
        subprocess.run([tool, str(resolution), str(rings)], input="\n".join(f"{x} {y}" for x, y in dense),
                       text=True, stdout=chain, check=True)
    bounds = []
    for cell in json.load(open(out))["features"]:
        ring = cell["geometry"]["coordinates"][0]
        xs, ys = [p[0] for p in ring], [p[1] for p in ring]
        bounds.append((min(xs), min(ys), max(xs), max(ys)))
    return bounds


def topo(points, cache):
    folder = f"{cache}/topo"
    if not os.path.exists(f"{folder}/historicaltopo.csv"):
        fetch(TOPO_INDEX, f"{folder}/topomaps_all.zip")
        with zipfile.ZipFile(f"{folder}/topomaps_all.zip") as outer:
            with zipfile.ZipFile(io.BytesIO(outer.read("historicaltopo.zip"))) as inner:
                inner.extract("historicaltopo.csv", folder)
    chains = {scale: hexchain(points, *CHAINS[scale], f"{folder}/chain-{scale}.geojson") for scale in CHAINS}
    pad = 0.5  # degrees: sheets this far from every route point can't touch a chain
    csv.field_size_limit(10**9)
    best = {}
    for row in csv.DictReader(open(f"{folder}/historicaltopo.csv", newline="")):
        try:
            year, scale = int(row["date_on_map"] or 0), int(row["map_scale"] or 0)
            west, east, north, south = (float(row[k]) for k in ("westbc", "eastbc", "northbc", "southbc"))
        except ValueError:
            continue
        if not (1930 <= year <= 1970) or scale not in CHAINS or not row["geotiff_url"]:
            continue
        key = (scale, round(west, 3), round(south, 3), round(east, 3), round(north, 3))
        if key in best:
            if abs(int(best[key]["date_on_map"]) - 1955) <= abs(year - 1955):
                continue
        elif not near(points, west, east, south, north, pad) or not any(
                w < east and e > west and s < north and n > south for w, s, e, n in chains[scale]):
            continue
        best[key] = row
    sheets = [{"scale": k[0], "west": k[1], "south": k[2], "east": k[3], "north": k[4],
               "year": int(r["date_on_map"]), "name": r["map_name"], "url": r["geotiff_url"]}
              for k, r in sorted(best.items())]
    json.dump(sheets, open(f"{folder}/sheets.json", "w"), indent=0)
    for i, sheet in enumerate(sheets):
        name = urllib.parse.unquote(os.path.basename(sheet["url"]))
        fetch(sheet["url"], f"{folder}/tif/{sheet['scale']}/{name}")
    print(f"topo: {len(sheets)} sheets in {folder}/tif")


def landsat(points, cache):
    folder = f"{cache}/landsat1"
    index = f"{folder}/lm01-index.csv"
    if not os.path.exists(index):
        os.makedirs(folder, exist_ok=True)
        request = urllib.request.Request(LANDSAT_INDEX, headers={"User-Agent": UA})
        with urllib.request.urlopen(request) as response, open(index + ".part", "w") as out:
            lines = io.TextIOWrapper(gzip.GzipFile(fileobj=response))
            out.write(next(lines))
            for line in lines:
                if ",LM01_" in line:
                    out.write(line)
        os.replace(index + ".part", index)

    def score(row):
        """Lower is better: summer 1972-73, summer 1974-75, anything else; then less cloud."""
        year, month = int(row["DATE_ACQUIRED"][:4]), int(row["DATE_ACQUIRED"][5:7])
        summer = 6 <= month <= 9
        return (0 if summer and year <= 1973 else 1 if summer and year <= 1975 else 2,
                float(row["CLOUD_COVER"]))

    candidates = {}
    for row in csv.DictReader(open(index)):
        if row["DATA_TYPE"] != "L1TP" or not (0 <= float(row["CLOUD_COVER"] or 100) < 10):
            continue
        key = (int(row["WRS_PATH"]), int(row["WRS_ROW"]))
        west, east = float(row["WEST_LON"]), float(row["EAST_LON"])
        south, north = float(row["SOUTH_LAT"]), float(row["NORTH_LAT"])
        if key in candidates or near(points, west, east, south, north, 0):
            candidates.setdefault(key, []).append(row)
    scenes = []
    for key in sorted(candidates):
        tries = sorted(candidates[key], key=score)[:TRIES]
        chosen = None
        for row in tries:
            folder_of_scene = download_scene(row, folder)
            stripes = striping(folder_of_scene)
            if stripes <= STRIPED:
                chosen = row
                break
            print(f"landsat: {row['DATE_ACQUIRED']} at {key} is striped ({stripes:.2f}); trying the next")
        scenes.append(chosen or tries[0])
    json.dump([{"path": int(r["WRS_PATH"]), "row": int(r["WRS_ROW"]), "date": r["DATE_ACQUIRED"],
                "cloud": float(r["CLOUD_COVER"]), "url": r["BASE_URL"]} for r in scenes],
              open(f"{folder}/scenes.json", "w"), indent=0)
    # Only the chosen scenes stay in scenes/; the ones passed over move to rejected/.
    chosen = {r["BASE_URL"].rsplit("/", 1)[1] for r in scenes}
    for name in os.listdir(f"{folder}/scenes"):
        if name not in chosen:
            os.makedirs(f"{folder}/rejected", exist_ok=True)
            os.replace(f"{folder}/scenes/{name}", f"{folder}/rejected/{name}")
    early = sum(1 for r in scenes if score(r)[0] == 0)
    print(f"landsat: {len(scenes)} scenes ({early} from summer 1972-73) in {folder}/scenes")


TRIES = 4     # scenes tried for each orbit slot before keeping the least bad
STRIPED = 1.4  # row-to-row change over column-to-column change; most clean scenes are near 1


def download_scene(row, folder):
    product = row["BASE_URL"].rsplit("/", 1)[1]
    base = "https://storage.googleapis.com/" + row["BASE_URL"][len("gs://"):]
    # A scene passed over on an earlier run comes back from rejected/ rather than downloading again.
    if os.path.isdir(f"{folder}/rejected/{product}") and not os.path.isdir(f"{folder}/scenes/{product}"):
        os.replace(f"{folder}/rejected/{product}", f"{folder}/scenes/{product}")
    # Bands 4, 5 and 7 make the false colour (vintage-landsat.py); band 6 isn't used.
    for part in ("B4.TIF", "B5.TIF", "B7.TIF", "MTL.txt"):
        fetch(f"{base}/{product}_{part}", f"{folder}/scenes/{product}/{product}_{part}")
    return f"{folder}/scenes/{product}"


def striping(scene):
    """How much more rows differ from their neighbours than columns do, in the scene's
    middle, for the worst of bands 4, 5 and 7."""
    import glob
    import numpy
    from osgeo import gdal
    gdal.UseExceptions()
    worst = 0
    for band in ("B4", "B5", "B7"):
        source = gdal.Open(glob.glob(f"{scene}/*_{band}.TIF")[0])
        a = source.GetRasterBand(1).ReadAsArray().astype(numpy.float32)
        h, w = a.shape
        a = a[h // 4:3 * h // 4, w // 4:3 * w // 4]
        rows, cols = numpy.abs(numpy.diff(a, axis=0)).mean(), numpy.abs(numpy.diff(a, axis=1)).mean()
        worst = max(worst, rows / max(cols, 1e-6))
    return float(worst)


def main():
    kind, route, cache = sys.argv[1:]
    points = json.load(open(route))["points"]
    {"topo": topo, "landsat": landsat}[kind](points, os.path.expanduser(cache))


if __name__ == "__main__":
    main()
