#!/bin/bash
# Fetch the offline base map: Natural Earth outlines (public domain) and
# OpenStreetMap place names for one or more regions (ODbL).
#
#   scripts/fetch-basemap.sh                       # Natural Earth + Colorado
#   scripts/fetch-basemap.sh <name> <south> <west> <north> <east>   # add a region
#
# Writes Basemap/naturalearth/*.geojson and Basemap/osm/places-<name>.geojson.
# The OSM query goes to the public Overpass API once, at build time; the app
# itself never asks anyone for map data unless the Apple map is switched on.
set -euo pipefail
cd "$(dirname "$0")/.."

NE=Basemap/naturalearth
OSM=Basemap/osm
mkdir -p "$NE" "$OSM"

if [ $# -eq 0 ]; then
  base=https://raw.githubusercontent.com/nvkelso/natural-earth-vector/v5.1.2/geojson
  for layer in ne_50m_coastline ne_50m_admin_0_boundary_lines_land \
               ne_50m_admin_1_states_provinces_lines ne_50m_lakes \
               ne_10m_populated_places_simple; do
    curl -fsSL "$base/$layer.geojson" -o "$NE/$layer.geojson"
  done
  # Keep only what the app draws from the world cities: name, population, rank.
  python3 -I - "$NE/ne_10m_populated_places_simple.geojson" <<'PY'
import json, sys
path = sys.argv[1]
data = json.load(open(path))
features = [{
    "type": "Feature",
    "geometry": {"type": "Point", "coordinates": [round(c, 4) for c in f["geometry"]["coordinates"]]},
    "properties": {"name": f["properties"]["name"], "population": int(f["properties"].get("pop_max") or 0),
                   "rank": int(f["properties"].get("scalerank") or 10)},
} for f in data["features"]]
json.dump({"type": "FeatureCollection", "features": features}, open(path, "w"), separators=(",", ":"))
PY
  set -- colorado 36.99 -109.06 41.01 -102.04
fi

name=$1 south=$2 west=$3 north=$4 east=$5
query="[out:json][timeout:180];node[\"place\"~\"^(city|town|suburb|village)$\"][\"name\"]($south,$west,$north,$east);out body;"
# The public server asks busy clients to back off and retry.
raw=$(mktemp)
for wait in 0 30 60 120 240; do
  sleep "$wait"
  if curl -fsSL --max-time 300 -A "hexmosphere-basemap/0.1 (+https://github.com/tennica/hexmosphere)" \
       --data-urlencode "data=$query" https://overpass-api.de/api/interpreter -o "$raw"; then
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
du -sh "$NE" "$OSM"
