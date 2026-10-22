#!/bin/bash
# Precompute the land as compacted H3 cells, for drawing the world as hexagons.
#
#   scripts/build-land-cells.sh [resolution]     # default 5
#
# Fills Natural Earth's 1:50m land polygons with H3 cells at <resolution> using
# the vendored H3 C library (polygonToCells), compacts them (groups of seven merge
# into their parent wherever possible), and writes Basemap/h3/land-r<res>.cells:
# little-endian uint64 cell indexes. Natural Earth is public domain.
set -euo pipefail
cd "$(dirname "$0")/.."
RES=${1:-5}
NE_VERSION=v5.1.2
CACHE=${HEXMOSPHERE_CACHE:-$HOME/Library/Caches/hexmosphere}/naturalearth/$NE_VERSION/50m
LAND=$CACHE/ne_50m_land.geojson
mkdir -p "$CACHE" Basemap/h3
if [ ! -s "$LAND" ]; then
  curl -fsSL -A "hexmosphere-basemap/0.1 (+https://github.com/tennica/hexmosphere)" \
    "https://raw.githubusercontent.com/nvkelso/natural-earth-vector/$NE_VERSION/geojson/ne_50m_land.geojson" -o "$LAND"
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
H3=Packages/CH3/Sources/CH3
clang -O2 -w -I"$H3/include" -I"$H3" "$H3"/*.c tools/landcells.c -o "$WORK/landcells"

# GeoJSON rings (lng, lat) → the tool's plain-text format (lat lng), dropping the
# closing point that repeats the first. Antarctica wraps all 360° of longitude
# and reaches the pole, which H3's polygon fill can't handle, so any polygon that
# spans the whole globe is clipped into 30° wedges along meridians, stopping just
# short of the pole.
python3 -I - "$LAND" > "$WORK/rings.txt" <<'PY'
import json, sys

def clip(points, keep, cross):
    """One Sutherland–Hodgman step against a half-plane."""
    out = []
    for i, current in enumerate(points):
        previous = points[i - 1]
        if keep(current):
            if not keep(previous):
                out.append(cross(previous, current))
            out.append(current)
        elif keep(previous):
            out.append(cross(previous, current))
    return out

def at_lng(x):
    def cross(a, b):
        t = (x - a[0]) / (b[0] - a[0])
        return (x, a[1] + t * (b[1] - a[1]))
    return cross

def emit(rings):
    print("P", len(rings))
    for ring in rings:
        print("R", len(ring))
        for lng, lat in ring:
            print(lat, lng)

for feature in json.load(open(sys.argv[1]))["features"]:
    geometry = feature["geometry"]
    polygons = geometry["coordinates"] if geometry["type"] == "MultiPolygon" else [geometry["coordinates"]]
    for rings in polygons:
        rings = [[tuple(p) for p in (r[:-1] if r[0] == r[-1] else r)] for r in rings]
        lngs = [p[0] for p in rings[0]]
        if max(lngs) - min(lngs) < 359:
            emit(rings)
            continue
        outer = [(lng, max(lat, -89.9)) for lng, lat in rings[0]]
        for west in range(-180, 180, 30):
            east = west + 30
            wedge = clip(outer, lambda p: p[0] >= west, at_lng(west))
            wedge = clip(wedge, lambda p: p[0] <= east, at_lng(east)) if wedge else []
            if len(wedge) >= 3:
                emit([wedge])
PY

"$WORK/landcells" "$RES" "Basemap/h3/land-r$RES.cells" < "$WORK/rings.txt"
ls -la "Basemap/h3/land-r$RES.cells" | awk '{print $5 " bytes"}'
