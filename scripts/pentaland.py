# SPDX-License-Identifier: Apache-2.0
"""Which of H3's twelve pentagons touch land at each resolution, and how many rings out from
each resolution 3 pentagon the nearest land is (out to 29, tmj-to-inform's limit). Backs the
land claims in docs/mentagon.md.

    python3 -I scripts/pentaland.py NE_DIR

NE_DIR holds ne_10m_land.geojson and ne_10m_minor_islands.geojson from Natural Earth 1:10m
(public domain; github.com/nvkelso/natural-earth-vector, geojson/). They aren't in this
repository and the script downloads nothing. Needs h3 4.5.0 and shapely.

A cell counts as land when its whole polygon intersects land or a minor island, not just its
centre. The minor-islands layer misses the smallest islets and reefs: before choosing a
pentagon, check its rings against a finer coastline too.
"""
import json
import math
import sys
from pathlib import Path

import h3
from shapely import affinity
from shapely.geometry import Polygon, shape
from shapely.ops import unary_union
from shapely.prepared import prep

ne = Path(sys.argv[1])
geoms = []
for name in ("ne_10m_land", "ne_10m_minor_islands"):
    geoms += [shape(f["geometry"]) for f in json.loads((ne / f"{name}.geojson").read_text())["features"]]
land = unary_union(geoms)
# Two copies a full turn apart, for cells drawn across the antimeridian.
shifted = prep(unary_union([land, affinity.translate(land, xoff=360)]))
land_p = prep(land)


def poly(cell):
    pts = [(lng, lat) for lat, lng in h3.cell_to_boundary(cell)]
    lngs = [p[0] for p in pts]
    if max(lngs) - min(lngs) > 180:
        return Polygon([(lng + 360 if lng < 0 else lng, lat) for lng, lat in pts]), True
    return Polygon(pts), False


def has_land(cell):
    p, wrapped = poly(cell)
    return (shifted if wrapped else land_p).intersects(p)


def km(a, b):
    (la1, lo1), (la2, lo2) = (map(math.radians, x) for x in (a, b))
    h = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
    return 2 * 6371.0088 * math.asin(math.sqrt(h))


print("res  pentagons touching land or islands (base cells)")
for res in range(16):
    hits = [p for p in sorted(h3.get_pentagons(res)) if has_land(p)]
    print(f"{res:3}  {len(hits):2} of 12" + (f": {', '.join(str(h3.get_base_cell_number(p)) for p in hits)}" if hits else ""))

print("\nres 3 pentagon (base cell): centre lat,lng; nearest land, in rings (to 29)")
for p in sorted(h3.get_pentagons(3), key=h3.get_base_cell_number):
    lat, lng = h3.cell_to_latlng(p)
    near = next((k for k in range(30) if any(has_land(c) for c in h3.grid_ring(p, k))), None)
    print(f"  {h3.get_base_cell_number(p):3}  {p}  {lat:7.2f},{lng:8.2f}  "
          + (f"land at ring {near}" if near is not None else "no land within 29 rings"))

pitcairn, ducie = (-25.066, -130.101), (-24.672, -124.786)
print(f"\nPitcairn to Ducie: {km(pitcairn, ducie):.0f} km")
p72 = h3.cell_to_center_child("8091fffffffffff", 3)
for name, ll in (("Ducie", ducie), ("Pitcairn", pitcairn)):
    c = h3.latlng_to_cell(*ll, 3)
    print(f"{name}: {h3.grid_distance(p72, c)} rings from base 72's res 3 pentagon "
          f"({km(h3.cell_to_latlng(p72), ll):.0f} km from its centre)")
