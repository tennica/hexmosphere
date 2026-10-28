# SPDX-License-Identifier: Apache-2.0
"""The HeusDenVerSe bridge: the great circle from Heusden to Denver, as a route.
  python3 -I bridge.py      writes map/bridge.geojson
Hexmosphere's Open Tiled draws a route as the chain of H3 cells it crosses at the app's
cell size, so the bridge grows and shrinks with the size picker. Its one segment runs along
the great circle, so the two ends are all it needs."""
import json, math
from pathlib import Path

HERE = Path(__file__).resolve().parent
ENDS = {"Heusden": (51.735, 5.139), "Denver": (39.739, -104.990)}  # town centres, public


def vector(lat, lng):
    lat, lng = math.radians(lat), math.radians(lng)
    return (math.cos(lat) * math.cos(lng), math.cos(lat) * math.sin(lng), math.sin(lat))


def midpoint():
    """Halfway along the great circle, where the island sits (make.py)."""
    a, b = (vector(*ENDS[name]) for name in ("Heusden", "Denver"))
    m = [x + y for x, y in zip(a, b)]
    return math.degrees(math.atan2(m[2], math.hypot(m[0], m[1]))), math.degrees(math.atan2(m[1], m[0]))


if __name__ == "__main__":
    a, b = (vector(*ENDS[name]) for name in ("Heusden", "Denver"))
    km = math.acos(sum(x * y for x, y in zip(a, b))) * 6371
    route = {"type": "FeatureCollection", "name": "The HeusDenVerSe bridge", "features": [{
        "type": "Feature",
        "properties": {"name": "The HeusDenVerSe bridge", "fill": "#c8553d"},
        "geometry": {"type": "LineString",
                     "coordinates": [[lng, lat] for lat, lng in (ENDS["Heusden"], ENDS["Denver"])]},
    }]}
    (HERE / "map/bridge.geojson").write_text(json.dumps(route, indent=1) + "\n")
    lat, lng = midpoint()
    print(f"{km:.0f} km; midpoint {lat:.2f}, {lng:.2f}")
