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
#   scripts/fetch-basemap.sh streets <name> <south> <west> <north> <east>
#       Fetch every OpenStreetMap street in a region, from motorways down to
#       residential streets (no service roads, tracks or paths), in 1° squares
#       from the Overpass API, cached in ~/Library/Caches/hexmosphere/osm. Writes
#       Basemap/streets/streets-<name>.tiles (gitignored), cut into 1° squares the
#       app reads as it needs them (format in scripts/write-streets.py).
#
#   scripts/fetch-basemap.sh extract <name> <geofabrik-region>
#       The same streets, plus place names, for a whole region from one Geofabrik
#       extract (e.g. extract california north-america/us/california), filtered
#       locally with osmium. Kinder to the public servers than one Overpass query
#       per square for a big region. The extract is cached in
#       ~/Library/Caches/hexmosphere/geofabrik; writes streets-<name>.tiles and
#       Basemap/osm/places-<name>.geojson.
#
#   scripts/fetch-basemap.sh roads
#       Cache Natural Earth's 1:10m roads (about 50 MB, 56,600 roads) and write
#       every road to Basemap/roads/roads.bin (gitignored), keeping only its kind,
#       the zoom level Natural Earth suggests showing it from, and its line.
#
# Natural Earth is public domain; OpenStreetMap data is ODbL (Basemap/osm/LICENSE.md).
# Downloads happen here, at build time; the app never asks anyone for map data.
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

# One Overpass query, retried with longer waits when the public server is busy.
overpass() {
  local query=$1 out=$2
  for wait in 0 30 60 120 240; do
    sleep "$wait"
    if curl -fsSL --max-time 400 -A "$UA" --data-urlencode "data=$query" \
         https://overpass-api.de/api/interpreter -o "$out.part"; then
      mv "$out.part" "$out"
      return 0
    fi
    echo "Overpass busy; retrying after a longer wait" >&2
  done
  return 1
}

fetch_streets() {
  local name=$1 south=$2 west=$3 north=$4 east=$5
  local cache=${HEXMOSPHERE_CACHE:-$HOME/Library/Caches/hexmosphere}/osm/streets-$name
  mkdir -p "$cache" Basemap/streets
  local classes="motorway|trunk|primary|secondary|tertiary|motorway_link|trunk_link|primary_link|secondary_link|tertiary_link|unclassified|residential|living_street|pedestrian"
  local squares
  squares=$(python3 -I -c '
import math, sys
s, w, n, e = map(float, sys.argv[1:])
for lat in range(math.floor(s), math.ceil(n)):
    for lng in range(math.floor(w), math.ceil(e)):
        print(max(s, lat), max(w, lng), min(n, lat + 1), min(e, lng + 1))
' "$south" "$west" "$north" "$east")
  while read -r s w n e; do
    local file="$cache/$s,$w.json"
    [ -s "$file" ] && continue
    echo "streets $name: $s,$w" >&2
    overpass "[out:json][timeout:300];way[\"highway\"~\"^($classes)\$\"]($s,$w,$n,$e);out geom;" "$file"
  done <<< "$squares"
  write_streets "$cache" "Basemap/streets/streets-$name.tiles"
}

# The street classes fetched, as an Overpass regex and as an osmium filter.
STREET_CLASSES=motorway,trunk,primary,secondary,tertiary,motorway_link,trunk_link,primary_link,secondary_link,tertiary_link,unclassified,residential,living_street,pedestrian

# Writes a streets .tiles file (format in scripts/write-streets.py) from either a folder
# of Overpass answers or a GeoJSON sequence of lines exported by osmium.
write_streets() {
  python3 -I scripts/write-streets.py "$1" "$2"
  du -h "$2"
}

# Streets and places for a whole region from one Geofabrik extract, filtered here
# with osmium (brew install osmium-tool): one download instead of an Overpass query
# per 1° square. <region> is Geofabrik's path, e.g. north-america/us/california.
fetch_extract() {
  local name=$1 region=$2
  command -v osmium >/dev/null || { echo "needs osmium: brew install osmium-tool" >&2; exit 1; }
  local cache=${HEXMOSPHERE_CACHE:-$HOME/Library/Caches/hexmosphere}/geofabrik
  local pbf=$cache/$(basename "$region")-latest.osm.pbf
  local url=https://download.geofabrik.de/$region-latest.osm.pbf
  mkdir -p "$cache" Basemap/streets "$OSM"
  if [ ! -s "$pbf" ]; then
    curl -fsSL -A "$UA" "$url.md5" -o "$pbf.md5"
    curl -fSL -A "$UA" "$url" -o "$pbf.part"
    [ "$(md5 -q "$pbf.part")" = "$(cut -d' ' -f1 "$pbf.md5")" ] || { echo "checksum mismatch: $url" >&2; exit 1; }
    mv "$pbf.part" "$pbf"
  fi
  osmium tags-filter --overwrite "$pbf" "w/highway=$STREET_CLASSES" -o "$cache/streets-$name.osm.pbf"
  osmium export --overwrite -f geojsonseq --geometry-types=linestring \
    "$cache/streets-$name.osm.pbf" -o "$cache/streets-$name.geojsonseq"
  write_streets "$cache/streets-$name.geojsonseq" "Basemap/streets/streets-$name.tiles"
  osmium tags-filter --overwrite "$pbf" "n/place=city,town,suburb,village" -o "$cache/places-$name.osm.pbf"
  osmium export --overwrite -f geojsonseq --geometry-types=point \
    "$cache/places-$name.osm.pbf" -o "$cache/places-$name.geojsonseq"
  python3 -I - "$cache/places-$name.geojsonseq" "$OSM/places-$name.geojson" <<'PY'
import json, sys
features = []
for record in open(sys.argv[1]):
    feature = json.loads(record.lstrip("\x1e"))
    tags = feature["properties"]
    if not tags.get("name"):
        continue
    try:
        population = int(str(tags.get("population", "0")).replace(",", "").split(";")[0] or 0)
    except ValueError:
        population = 0
    lon, lat = feature["geometry"]["coordinates"]
    features.append({
        "type": "Feature",
        "geometry": {"type": "Point", "coordinates": [round(lon, 5), round(lat, 5)]},
        "properties": {"name": tags["name"], "place": tags["place"], "population": population},
    })
json.dump({"type": "FeatureCollection", "features": features}, open(sys.argv[2], "w"), separators=(",", ":"))
print(f"places-{sys.argv[2].rsplit('places-', 1)[1].removesuffix('.geojson')}: {len(features)} places")
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
  roads) fetch_roads ;;
  streets) shift; fetch_streets "$@" ;;
  extract) shift; fetch_extract "${1:?name}" "${2:?Geofabrik region, e.g. north-america/us/california}" ;;
  *) echo "usage: $0 [naturalearth <110m|50m|10m> | places|streets <name> <south> <west> <north> <east> | extract <name> <geofabrik-region> | roads]" >&2; exit 2 ;;
esac
