#!/bin/bash
# Fetch data for Hexmosphere's offline base map.
#
#   scripts/fetch-basemap.sh
#       Re-download the small committed set: a few Natural Earth 1:50m layers,
#       the 1:10m world cities, and OpenStreetMap places for Colorado.
#
#   scripts/fetch-basemap.sh naturalearth <110m|50m|10m>
#       Cache every Natural Earth GeoJSON layer at that scale (about 19 MB,
#       57 MB or 1 GB) in ~/Library/Caches/hexmosphere, then clone them into
#       Basemap/naturalearth-extra (gitignored), which local builds bundle.
#       The app uses the finest scale it finds for each layer it knows how to draw.
#
#   scripts/fetch-basemap.sh places <name> <south> <west> <north> <east>
#       Add OpenStreetMap place names for a region (one Overpass API query).
#
#   scripts/fetch-basemap.sh roads
#       Cache Natural Earth's 1:10m roads (about 50 MB, 56,600 roads) and write
#       every road to Basemap/roads/roads.bin (gitignored), keeping only its kind,
#       the zoom level Natural Earth suggests showing it from, and its line.
#
# Natural Earth is public domain; OpenStreetMap data is ODbL (Basemap/osm/LICENSE.md).
# Downloads happen here, at build time; the app never asks anyone for map data
# unless its Apple map is switched on.
set -euo pipefail
cd "$(dirname "$0")/.."

NE_VERSION=v5.1.2
NE_RAW=https://raw.githubusercontent.com/nvkelso/natural-earth-vector/$NE_VERSION/geojson
NE=Basemap/naturalearth
OSM=Basemap/osm
UA="hexmosphere-basemap/0.1 (+https://github.com/tennica/hexmosphere)"

# Keep only what the app draws from a populated-places layer: name, population, rank.
slim_places() {
  python3 -I - "$1" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
features = [{
    "type": "Feature",
    "geometry": {"type": "Point", "coordinates": [round(c, 4) for c in f["geometry"]["coordinates"]]},
    "properties": {"name": f["properties"].get("name") or f["properties"].get("NAME"),
                   "population": int(f["properties"].get("pop_max") or f["properties"].get("POP_MAX") or 0),
                   "rank": int(f["properties"].get("scalerank") or f["properties"].get("SCALERANK") or 10)},
} for f in data["features"] if f.get("geometry")]
json.dump({"type": "FeatureCollection", "features": features}, open(path, "w"), separators=(",", ":"))
PY
}

# roads.bin, little-endian: a uint32 road count, then for each road a uint8 kind
# (0 major highway, 1 secondary highway, 2 other road, 3 ferry), a uint8 minimum
# zoom × 10, a uint16 part count, and for each part a uint32 point count followed
# by that many float32 (longitude, latitude) pairs.
fetch_roads() {
  local cache=${HEXMOSPHERE_CACHE:-$HOME/Library/Caches/hexmosphere}/naturalearth/$NE_VERSION/10m
  mkdir -p "$cache" Basemap/roads
  if [ ! -s "$cache/ne_10m_roads.geojson" ]; then
    curl -fsSL -A "$UA" "$NE_RAW/ne_10m_roads.geojson" -o "$cache/ne_10m_roads.geojson.part"
    mv "$cache/ne_10m_roads.geojson.part" "$cache/ne_10m_roads.geojson"
  fi
  python3 -I - "$cache/ne_10m_roads.geojson" Basemap/roads/roads.bin <<'PY'
import json, struct, sys
kinds = {"Major Highway": 0, "Beltway": 0, "Bypass": 0, "Secondary Highway": 1,
         "Ferry Route": 3, "Ferry, seasonal": 3}
roads = [r for r in json.load(open(sys.argv[1]))["features"] if r.get("geometry")]
points = 0
with open(sys.argv[2], "wb") as out:
    out.write(struct.pack("<I", len(roads)))
    for road in roads:
        properties, geometry = road["properties"], road["geometry"]
        parts = geometry["coordinates"] if geometry["type"] == "MultiLineString" else [geometry["coordinates"]]
        out.write(struct.pack("<BBH", kinds.get(properties.get("type"), 2),
                              round(float(properties.get("min_zoom") or 0) * 10), len(parts)))
        for part in parts:
            out.write(struct.pack("<I", len(part)))
            out.write(struct.pack(f"<{len(part) * 2}f", *(c for point in part for c in point[:2])))
            points += len(part)
print(f"roads: {len(roads)} roads, {points} points")
PY
  du -h Basemap/roads/roads.bin
}

fetch_places() {
  local name=$1 south=$2 west=$3 north=$4 east=$5
  mkdir -p "$OSM"
  local query="[out:json][timeout:180];node[\"place\"~\"^(city|town|suburb|village)$\"][\"name\"]($south,$west,$north,$east);out body;"
  local raw
  raw=$(mktemp)
  # The public server asks busy clients to back off and retry.
  for wait in 0 30 60 120 240; do
    sleep "$wait"
    if curl -fsSL --max-time 300 -A "$UA" --data-urlencode "data=$query" \
         https://overpass-api.de/api/interpreter -o "$raw"; then
      break
    fi
    echo "Overpass busy; retrying after a longer wait" >&2
  done
  python3 -I -c '
import json, sys
nodes = json.load(sys.stdin)["elements"]
features = []
for n in nodes:
    tags = n.get("tags", {})
    try:
        population = int(str(tags.get("population", "0")).replace(",", "").split(";")[0] or 0)
    except ValueError:
        population = 0
    features.append({
        "type": "Feature",
        "geometry": {"type": "Point", "coordinates": [round(n["lon"], 5), round(n["lat"], 5)]},
        "properties": {"name": tags["name"], "place": tags["place"], "population": population},
    })
json.dump({"type": "FeatureCollection", "features": features}, sys.stdout, separators=(",", ":"))
' < "$raw" > "$OSM/places-$name.geojson"
  rm -f "$raw"
  echo "places-$name: $(python3 -I -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["features"]))' "$OSM/places-$name.geojson") places"
}

fetch_scale() {
  local scale=$1
  case "$scale" in 110m|50m|10m) ;; *) echo "scale must be 110m, 50m or 10m" >&2; exit 2 ;; esac
  local cache=${HEXMOSPHERE_CACHE:-$HOME/Library/Caches/hexmosphere}/naturalearth/$NE_VERSION/$scale
  local extra=Basemap/naturalearth-extra
  mkdir -p "$cache" "$extra"
  # The layer list for this scale, from the repository tree at the pinned version.
  local layers
  layers=$(curl -fsSL -A "$UA" "https://api.github.com/repos/nvkelso/natural-earth-vector/git/trees/$NE_VERSION?recursive=1" |
    python3 -I -c 'import json,sys; s=sys.argv[1]; print("\n".join(t["path"].split("/")[-1] for t in json.load(sys.stdin)["tree"] if t["path"].startswith("geojson/ne_"+s+"_") and t["path"].endswith(".geojson")))' "$scale")
  local count=0
  for file in $layers; do
    if [ ! -s "$cache/$file" ]; then
      curl -fsSL -A "$UA" "$NE_RAW/$file" -o "$cache/$file.part" && mv "$cache/$file.part" "$cache/$file"
    fi
    # An APFS clone where possible, so the copy costs no extra space.
    rm -f "$extra/$file"
    cp -c "$cache/$file" "$extra/$file" 2>/dev/null || cp "$cache/$file" "$extra/$file"
    case "$file" in *populated_places*) slim_places "$extra/$file" ;; esac
    count=$((count + 1))
  done
  echo "naturalearth $scale: $count layers cached in $cache"
  du -sh "$cache" "$extra"
}

case "${1:-}" in
  "")
    mkdir -p "$NE"
    for layer in ne_50m_coastline ne_50m_admin_0_boundary_lines_land \
                 ne_50m_admin_1_states_provinces_lines ne_50m_lakes \
                 ne_10m_populated_places_simple; do
      curl -fsSL -A "$UA" "$NE_RAW/$layer.geojson" -o "$NE/$layer.geojson"
    done
    slim_places "$NE/ne_10m_populated_places_simple.geojson"
    fetch_places colorado 36.99 -109.06 41.01 -102.04
    du -sh "$NE" "$OSM"
    ;;
  naturalearth) fetch_scale "${2:?scale: 110m, 50m or 10m}" ;;
  places) shift; fetch_places "$@" ;;
  roads) fetch_roads ;;
  *) echo "usage: $0 [naturalearth <110m|50m|10m> | places <name> <south> <west> <north> <east> | roads]" >&2; exit 2 ;;
esac
