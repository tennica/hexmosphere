# SPDX-License-Identifier: Apache-2.0
"""The HeusDenVerSe island laid along the bridge, so its Heusden end sits on Heusden and its
Denver end on Denver.
  python3 -I strip.py      writes map/island.geojson from flat-island.tmj (make.py)
A flat Tiled grid is pinned at one point and can't reach both towns, 7,810 km apart on a
curved great circle. So the island is painted onto the H3 cells along the route instead:
each column of make.py's map goes to its place on the great circle (the Heusden column on
Heusden, the Denver column on Denver, the rest spaced between and beyond), each row to its
distance beside the route, and every cell takes the terrain most of its samples land on.
Hexmosphere's Open Tiled draws the cells (features with "h3" and "fill") and shows the
landmarks (points with "h3", "name" and "description")."""
import collections, json, math, subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
RES = 3  # Hexmosphere's biggest size, about 119 km across
ROW_KM = 103.5  # rows of pointy hexes are 3/4 of a hex apart: about 0.866 x 119.5 km
STEP_KM = 25  # sample spacing, well under a cell, so none is skipped

tmj = json.loads((HERE / "flat-island.tmj").read_text())
W, H, data = tmj["width"], tmj["height"], tmj["layers"][0]["data"]
TW, TH, SIDE = tmj["tilewidth"], tmj["tileheight"], tmj["hexsidelength"]
odd = tmj["staggerindex"] == "odd"
colours = {}  # gid -> #rrggbb, from make.py's table
src = (HERE / "make.py").read_text()
table = src[src.index("TILES = {"):src.index("}\n", src.index("TILES = {")) + 1]
for gid, (name, fill, edge, mark) in eval(table.split("=", 1)[1]).items():
    colours[gid] = "#%02x%02x%02x" % fill


def tile_of(x, y):
    row = round((y - TH / 2) / ((TH + SIDE) / 2))
    shifted = (row % 2 == 1) == odd
    return round((x - TW / 2 - (TW / 2 if shifted else 0)) / TW), row


places = {o["name"]: (tile_of(o["x"], o["y"]), next(p["value"] for p in o["properties"] if p["name"] == "description"))
          for o in tmj["layers"][1]["objects"]}
(hc, hr), (dc, dr) = places["Heusden"][0], places["Denver"][0]


def vector(lat, lng):
    lat, lng = math.radians(lat), math.radians(lng)
    return (math.cos(lat) * math.cos(lng), math.cos(lat) * math.sin(lng), math.sin(lat))


def norm(v):
    n = math.sqrt(sum(x * x for x in v))
    return tuple(x / n for x in v)


A, B = vector(51.735, 5.139), vector(39.739, -104.990)  # Heusden, Denver: bridge.py's ends
ANGLE = math.acos(sum(x * y for x, y in zip(A, B)))
POLE = norm((A[1] * B[2] - A[2] * B[1], A[2] * B[0] - A[0] * B[2], A[0] * B[1] - A[1] * B[0]))
NORTH = 1 if POLE[2] > 0 else -1  # which side of the route is north: row 0 is the map's top


def point(u, km_north):
    """u = 0 at Heusden, 1 at Denver (beyond either end along the same great circle);
    then km_north to the north side of the route."""
    a = u * ANGLE
    p = tuple((math.sin(ANGLE - a) * x + math.sin(a) * y) / math.sin(ANGLE) for x, y in zip(A, B))
    d = NORTH * km_north / 6371
    q = tuple(math.cos(d) * x + math.sin(d) * n for x, n in zip(p, POLE))
    return math.degrees(math.asin(q[2])), math.degrees(math.atan2(q[1], q[0]))


def u_of(col):  # the Heusden column at 0, the Denver column at 1
    return (hc - col) / (hc - dc)


def centre_row(col):  # the route runs through Heusden's row at one end and Denver's at the other
    return hr + (dr - hr) * u_of(col)


# Sample the whole map: along the route by column, beside it by row.
samples, owners = [], []
cols = [c / 4 for c in range(-2, 4 * W + 2)]  # quarter columns, a little past both edges
for col in cols:
    for rr in range(-2, 4 * H + 2):
        row = rr / 4
        c, r = round(col), round(row)
        if not (0 <= c < W and 0 <= r < H) or data[r * W + c] == 0:
            continue
        samples.append(point(u_of(col), (centre_row(col) - row) * ROW_KM))
        owners.append(data[r * W + c])
# Thin the along-route spacing check: a column is (7,810 km / columns between the towns) wide.
col_km = ANGLE * 6371 / abs(hc - dc)
out = subprocess.run([str(HERE / "build/cells"), str(RES)], capture_output=True, text=True, check=True,
                     input="".join(f"{lat:.6f} {lng:.6f}\n" for lat, lng in samples)).stdout.split()
votes = collections.defaultdict(collections.Counter)
for cell, gid in zip(out, owners):
    votes[cell][gid] += 1
features = [{"type": "Feature", "properties": {"h3": cell, "fill": colours[tally.most_common(1)[0][0]]},
             "geometry": None} for cell, tally in sorted(votes.items())]

# Landmarks at their tiles' places along the route.
points = [(name, point(u_of(c), (centre_row(c) - r) * ROW_KM), text) for name, ((c, r), text) in places.items()]
cells = subprocess.run([str(HERE / "build/cells"), str(RES)], capture_output=True, text=True, check=True,
                       input="".join(f"{lat:.6f} {lng:.6f}\n" for _, (lat, lng), _ in points)).stdout.split()
for (name, (lat, lng), text), cell in zip(points, cells):
    features.append({"type": "Feature", "properties": {"h3": cell, "name": name, "description": text, "landmark": True},
                     "geometry": {"type": "Point", "coordinates": [round(lng, 5), round(lat, 5)]}})

(HERE / "map/island.geojson").write_text(json.dumps({"type": "FeatureCollection", "name": "The HeusDenVerSe island, along the bridge",
                                                 "features": features}) + "\n")
print(f"{len(votes)} cells at resolution {RES}; a column is about {col_km:.0f} km along the route; "
      f"landmarks: {[(n, round(lat, 1), round(lng, 1)) for n, (lat, lng), _ in points]}")
