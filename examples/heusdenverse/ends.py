# SPDX-License-Identifier: Apache-2.0
"""The HeusDenVerSe's two real ends, Heusden and Denver, as Tiled maps at H3 resolution 8
(hexes about 0.9 km across), placed where they really are.
  python3 -I ends.py [--refetch]     writes map/heusden.tmj and map/denver.tmj (ODbL: see README)
The terrain comes from OpenStreetMap (ODbL; credit: (c) OpenStreetMap contributors): water,
rivers, land use and woods for one box around each town, fetched once from the public
Overpass API into osm/ and reused after that. Each hex takes the terrain at its centre.
Built-up land also comes from Natural Earth's urban areas (public domain, bundled with
Hexmosphere), since OSM's land use is patchy in places. Hand fixes on top: the landmarks and
their descriptions, and the Front Range, which land use doesn't show.

Cells are laid out as Hexmosphere lays them out (TiledLayout.swift, pointy-topped, north up
within 30 degrees), and each map records origin_cell, origin_column and origin_row, so
Hexmosphere's Open Tiled puts every hex back on exactly its cell."""
import json, math, subprocess, sys, urllib.parse, urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
HEXDISK = HERE / "build/hexdisk"
# Fetched into the repo by scripts/fetch-basemap.sh.
URBAN = HERE.parents[1] / "Basemap/naturalearth-extra/ne_50m_urban_areas.geojson"
RES = 8
TW, TH, SIDE = 28, 32, 16
WATER, POLDER, CITY, PLAINS, FOOTHILLS, MOUNTAINS, SNOW, WOODS, FORT, CASTLE = 2, 3, 9, 8, 10, 11, 12, 14, 5, 6

ENDS = {
    "heusden": {
        "title": "Land van Heusden en Altena",
        "centre": (51.735, 5.06), "box": (51.665, 4.90, 51.805, 5.22),  # s, w, n, e
        "ground": POLDER,
        "urban_fallback": False,  # OSM's land use is close to complete in the Netherlands
        "rivers": ("Bergsche Maas", "Afgedamde Maas", "Maas"),
        "landmarks": [
            ("Heusden", (51.7347, 5.1386), FORT,
             "A star-shaped fortress town on the Maas. Ramparts are better than regrets. "
             "The bridge to Denver starts here."),
            ("Kasteel Dussen", None, CASTLE,  # found in the OSM data
             "A moated castle on the river flats. Its moat is easy to explain, so it may be a good castle."),
            ("The Maas", (51.758, 5.06), None,
             "The river, held between its dikes. Water should never pass silently, unless explicitly pumped."),
        ],
    },
    "denver": {
        "title": "Denver and the Front Range",
        "centre": (39.735, -105.07), "box": (39.62, -105.30, 39.85, -104.86),
        "ground": PLAINS,
        "urban_fallback": True,
        "rivers": ("South Platte River", "Clear Creek", "Bear Creek"),
        "landmarks": [
            ("Denver", (39.7393, -104.9848), None,
             "The Den and the Ver of the HeusDenVerSe, a mile up. The bridge to Heusden ends here."),
            ("The Front Range", (39.70, -105.25), None, "Mountains to the west of Denver, where they belong."),
            ("The South Platte", None, None,  # found in the OSM data
             "The river out of the mountains and across the plains. Flat is better than nested."),
        ],
    },
}


def overpass(name, box, refetch):
    """The end's water, rivers, land use and woods from OpenStreetMap, cached in osm/."""
    cache = HERE / "osm" / f"{name}.json"
    if cache.exists() and not refetch:
        return json.loads(cache.read_text())
    s, w, n, e = box
    bbox = f"{s},{w},{n},{e}"
    query = f"""[out:json][timeout:180];
(
  way["natural"~"^(water|wood|wetland)$"]({bbox});
  relation["natural"~"^(water|wood)$"]({bbox});
  way["waterway"~"^(river|riverbank|canal)$"]({bbox});
  relation["waterway"="river"]({bbox});
  way["landuse"~"^(residential|commercial|industrial|retail|forest|farmland|meadow|grass|orchard|reservoir|basin)$"]({bbox});
  relation["landuse"~"^(residential|commercial|industrial|retail|forest)$"]({bbox});
  nwr["historic"~"^(castle|fort)$"]({bbox});
);
out geom qt;"""
    request = urllib.request.Request("https://overpass-api.de/api/interpreter",
                                     data=urllib.parse.urlencode({"data": query}).encode(),
                                     headers={"User-Agent": "hexmosphere-draft-map/0.1"})
    with urllib.request.urlopen(request, timeout=240) as response:
        data = json.loads(response.read())
    cache.parent.mkdir(exist_ok=True)
    cache.write_text(json.dumps(data))
    return data


def shapes(data):
    """(kind, tags, rings or lines) for each element: polygons as closed rings, rivers as lines."""
    out = []
    for el in data["elements"]:
        tags = el.get("tags", {})
        if el["type"] == "way" and "geometry" in el:
            pts = [(g["lat"], g["lon"]) for g in el["geometry"]]
            closed = len(pts) > 3 and pts[0] == pts[-1]
            if tags.get("waterway") in ("river", "canal"):
                # Only rivers paint hexes; canals and side channels are too thin at this scale.
                if tags["waterway"] == "river":
                    out.append(("line", tags, pts))
            elif closed:
                out.append(("ring", tags, pts))
        elif el["type"] == "relation":
            outers = []
            for m in el.get("members", []):
                if "geometry" not in m:
                    continue
                pts = [(g["lat"], g["lon"]) for g in m["geometry"] if g]
                if tags.get("waterway") == "river":
                    out.append(("line", tags, pts))
                elif m.get("role") == "outer" and len(pts) > 1:
                    outers.append(pts)
            out += [("ring", tags, ring) for ring in rings(outers)]
        elif el["type"] == "node":
            out.append(("point", tags, [(el["lat"], el["lon"])]))
    return out


def rings(pieces):
    """Joins a multipolygon's outer ways end to end into closed rings (big river areas are
    split across many ways)."""
    pieces = [list(p) for p in pieces]
    done = []
    while pieces:
        ring = pieces.pop()
        while ring[0] != ring[-1]:
            for k, piece in enumerate(pieces):
                if piece[0] == ring[-1]:
                    ring += piece[1:]
                elif piece[-1] == ring[-1]:
                    ring += piece[-2::-1]
                elif piece[-1] == ring[0]:
                    ring = piece[:-1] + ring
                elif piece[0] == ring[0]:
                    ring = piece[:0:-1] + ring
                else:
                    continue
                pieces.pop(k)
                break
            else:
                break  # an open end: the rest of the ring lies outside the fetched box
        if len(ring) > 3:
            done.append(ring if ring[0] == ring[-1] else ring + ring[:1])
    return done


def inside(pt, ring):
    lat, lon = pt
    hit = False
    for (a1, o1), (a2, o2) in zip(ring, ring[1:]):
        if (a1 > lat) != (a2 > lat) and lon < o1 + (lat - a1) * (o2 - o1) / (a2 - a1):
            hit = not hit
    return hit


def km_to_line(pt, line):
    """Rough distance in km from a point to a polyline, on a local flat projection."""
    lat0 = math.radians(pt[0])
    def xy(p):
        return (math.radians(p[1]) * math.cos(lat0) * 6371, math.radians(p[0]) * 6371)
    px, py = xy(pt)
    best = float("inf")
    for a, b in zip(line, line[1:]):
        (ax, ay), (bx, by) = xy(a), xy(b)
        dx, dy = bx - ax, by - ay
        t = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy or 1)))
        best = min(best, math.hypot(px - ax - t * dx, py - ay - t * dy))
    return best


def classify(pt, found, ground, rivers):
    """The terrain at a hex centre, water first, then built-up, then woods, then farmland."""
    kinds = set()
    for kind, tags, pts, bounds in found:
        s, w, n, e = bounds
        if kind == "line":
            # The named main rivers, as unbroken chains: any hex they pass within its inner circle
            # (about 0.46 km at resolution 8). Narrower than a hex, they'd miss most centres.
            if tags.get("name") in rivers and s - 0.01 <= pt[0] <= n + 0.01 and w - 0.015 <= pt[1] <= e + 0.015 \
                    and km_to_line(pt, pts) < 0.46:
                kinds.add("water")
        elif kind == "ring" and s <= pt[0] <= n and w <= pt[1] <= e and inside(pt, pts):
            use = tags.get("landuse") or tags.get("natural") or tags.get("waterway")
            kinds.add({"water": "water", "riverbank": "water", "reservoir": "water", "basin": "water",
                       "wetland": "farm", "wood": "woods", "forest": "woods", "residential": "city",
                       "commercial": "city", "industrial": "city", "retail": "city",
                       "urban": "city"}.get(use, "farm"))
    for kind, tile in (("water", WATER), ("city", CITY), ("woods", WOODS), ("farm", ground)):
        if kind in kinds:
            return tile
    return ground


# --- TiledLayout.swift, pointy-topped, in Python -----------------------------------------
def swift_round(x):
    return math.floor(x + 0.5) if x >= 0 else -math.floor(-x + 0.5)


def fit(axial, world):
    grid = [(q + r / 2, r * math.sqrt(3) / 2) for q, r in axial]
    def centred(pts):
        mx, my = sum(p[0] for p in pts) / len(pts), sum(p[1] for p in pts) / len(pts)
        return [(x - mx, y - my) for x, y in pts]
    g, w = centred(grid), centred(world)
    dot = sum(a[0] * b[0] + a[1] * b[1] for a, b in zip(g, w))
    cross = sum(a[0] * b[1] - a[1] * b[0] for a, b in zip(g, w))
    gg, ww = sum(a[0] ** 2 + a[1] ** 2 for a in g), sum(b[0] ** 2 + b[1] ** 2 for b in w)
    return math.degrees(math.atan2(cross, dot)), math.hypot(dot, cross) / math.sqrt(gg * ww)


def layout(cells):
    """Each cell's (column, layout row, shifted), as TiledLayout(cells:kind: .pointy) gives them."""
    axial = [(i - j, j) for _, i, j, _, _ in cells]
    # MKMapPoint's x and -y: longitude and Mercator, in the same units.
    world = [(math.radians(lng), math.log(math.tan(math.pi / 4 + math.radians(lat) / 2))) for *_, lat, lng in cells]
    plain, flipped = fit(axial, world), fit([(q + r, -r) for q, r in axial], world)
    mirrored = flipped[1] > plain[1]
    if mirrored:
        axial = [(q + r, -r) for q, r in axial]
    theta = flipped[0] if mirrored else plain[0]
    steps = swift_round(theta / 60)
    for _ in range(steps % 6):
        axial = [(-r, q + r) for q, r in axial]
    r_max = max(r for _, r in axial)
    return [((2 * q + r) // 2, r_max - r, r % 2 == 1) for q, r in axial], theta - 60 * steps


def build(name, end, refetch):
    s, w, n, e = end["box"]
    lat0, lng0 = end["centre"]
    out = subprocess.run([str(HEXDISK), str(RES), "40", str(lat0), str(lng0)], capture_output=True, text=True,
                         check=True).stdout.split("\n")
    cells = [(h, int(i), int(j), float(lat), float(lng))
             for h, i, j, lat, lng in (line.split() for line in out if line)]
    origin = cells[0][0]  # gridDisk lists the origin first
    tiles, turned = layout(cells)
    keep = [(c, t) for c, t in zip(cells, tiles) if s <= c[3] <= n and w <= c[4] <= e]
    col0, row0 = min(t[0] for _, t in keep), min(t[1] for _, t in keep)
    width, height = max(t[0] for _, t in keep) - col0 + 1, max(t[1] for _, t in keep) - row0 + 1
    at = {c[0]: (t[0] - col0, t[1] - row0, t[2]) for c, t in keep}
    oc, orow, oshift = at[origin]
    stagger_odd = oshift == (orow % 2 == 1)

    data = overpass(name, end["box"], refetch)
    found = []
    urban = json.loads(URBAN.read_text())["features"]
    urban_rings = [[(lat, lng) for lng, lat in f["geometry"]["coordinates"][0]] for f in urban
                   if f["geometry"]["type"] == "Polygon"]
    for ring in urban_rings if end["urban_fallback"] else []:
        if any(s <= lat <= n and w <= lng <= e for lat, lng in ring) or inside(end["centre"], ring):
            found.append(("ring", {"landuse": "urban"}, ring,
                          (min(p[0] for p in ring), min(p[1] for p in ring), max(p[0] for p in ring), max(p[1] for p in ring))))
    for kind, tags, pts in shapes(data):
        lats, lngs = [p[0] for p in pts], [p[1] for p in pts]
        found.append((kind, tags, pts, (min(lats), min(lngs), max(lats), max(lngs))))
    grid = [0] * (width * height)
    for (h, _, _, lat, lng), _ in keep:
        col, row, _ = at[h]
        tile = classify((lat, lng), found, end["ground"], end["rivers"])
        if name == "denver" and tile != WATER:  # hand fix: the foothills and the Front Range, over the suburbs too
            tile = MOUNTAINS if lng < -105.215 else FOOTHILLS if lng < -105.17 else tile
            if tile == MOUNTAINS and (int(h, 16) >> 20) % 5 == 0:
                tile = SNOW
        grid[row * width + col] = tile

    def cell_at(lat, lng):
        return min(keep, key=lambda kt: (kt[0][3] - lat) ** 2 + ((kt[0][4] - lng) * math.cos(math.radians(lat))) ** 2)[0]

    def pixel(col, row):
        shifted = (row % 2 == 1) == stagger_odd
        return col * TW + TW / 2 + (TW / 2 if shifted else 0), row * (TH + SIDE) / 2 + TH / 2

    objects = []
    for title, where, tile, text in end["landmarks"]:
        if where is None:  # found in the OSM data
            if title.startswith("Kasteel"):
                pts = [p for k, tags, ps, _ in found if "Dussen" in tags.get("name", "") and tags.get("historic") for p in ps]
            else:
                pts = [p for k, tags, ps, _ in found if tags.get("name", "").startswith("South Platte") for p in ps]
                pts = [p for p in pts if s <= p[0] <= n and w <= p[1] <= e]
                pts = pts[len(pts) // 2:len(pts) // 2 + 1]
            if not pts:
                print(f"  {title}: not in the OSM data, left out")
                continue
            where = (sum(p[0] for p in pts) / len(pts), sum(p[1] for p in pts) / len(pts))
        cell = cell_at(*where)
        if title.startswith("The Maas"):  # hand fix: onto the nearest river hex
            cell = min((kt[0] for kt in keep if grid[at[kt[0][0]][1] * width + at[kt[0][0]][0]] == WATER),
                       key=lambda c: (c[3] - where[0]) ** 2 + (c[4] - where[1]) ** 2)
        col, row, _ = at[cell[0]]
        if tile:
            grid[row * width + col] = tile
        x, y = pixel(col, row)
        objects.append({"id": len(objects) + 1, "name": title, "type": "place", "point": True, "x": x, "y": y,
                        "width": 0, "height": 0, "rotation": 0, "visible": True,
                        "properties": [{"name": "description", "type": "string", "value": text},
                                       {"name": "h3", "type": "string", "value": cell[0]}]})
    labels = [{"id": len(objects) + 1 + k, "name": o["name"], "type": "label", "x": o["x"] - 60, "y": o["y"] + 8,
               "width": 120, "height": 18, "rotation": 0, "visible": True,
               "text": {"text": o["name"], "pixelsize": 11, "bold": True, "halign": "center", "wrap": False,
                        "color": "#1c1c24"}} for k, o in enumerate(objects)]

    tileset = json.loads((HERE / "flat-island.tmj").read_text())["tilesets"]
    tileset = [{**t, "image": "tiles.png"} for t in tileset]  # beside the maps in map/
    tmj = {
        "type": "map", "version": "1.10", "tiledversion": "1.12.2", "orientation": "hexagonal",
        "renderorder": "right-down", "staggeraxis": "y", "staggerindex": "odd" if stagger_odd else "even",
        "hexsidelength": SIDE, "width": width, "height": height, "tilewidth": TW, "tileheight": TH,
        "infinite": False, "backgroundcolor": "#f4efe2", "nextlayerid": 4,
        "nextobjectid": len(objects) + len(labels) + 1,
        "properties": [
            {"name": "title", "type": "string", "value": end["title"]},
            {"name": "origin_cell", "type": "string", "value": origin},
            {"name": "origin_column", "type": "int", "value": oc},
            {"name": "origin_row", "type": "int", "value": orow},
            {"name": "h3_resolution", "type": "int", "value": RES},
            {"name": "turned_from_north_degrees", "type": "float", "value": round(turned, 1)},
            {"name": "credit", "type": "string", "value": "terrain: (c) OpenStreetMap contributors (ODbL)"},
        ],
        "tilesets": tileset,
        "layers": [
            {"id": 1, "name": "land", "type": "tilelayer", "width": width, "height": height, "x": 0, "y": 0,
             "opacity": 1, "visible": True, "data": grid},
            {"id": 2, "name": "places", "type": "objectgroup", "draworder": "topdown", "x": 0, "y": 0,
             "opacity": 1, "visible": True, "objects": objects},
            {"id": 3, "name": "labels", "type": "objectgroup", "draworder": "topdown", "x": 0, "y": 0,
             "opacity": 1, "visible": True, "objects": labels},
        ],
    }
    (HERE / "map" / f"{name}.tmj").write_text(json.dumps(tmj, indent=1) + "\n")
    counts = {t: grid.count(t) for t in sorted(set(grid)) if t}
    print(f"{name}.tmj: {width} x {height}, {len(keep)} hexes, turned {turned:.1f} deg, "
          f"{len(data['elements'])} OSM elements, tiles {counts}, landmarks {[o['name'] for o in objects]}")


if __name__ == "__main__":
    for name, end in ENDS.items():
        build(name, end, "--refetch" in sys.argv)
