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
  *) echo "usage: $0 [naturalearth <110m|50m|10m> | places <name> <south> <west> <north> <east>]" >&2; exit 2 ;;
esac
