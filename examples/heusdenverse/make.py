# SPDX-License-Identifier: Apache-2.0
"""The HeusDenVerSe: Heusden and Denver on one Tiled hex map, turned to match the real directions.
  python3 -I make.py      writes flat-island.tmj beside it and map/tiles.png
Hand-drawn and made up; it sits on open water halfway along the bridge, Heusden to the east,
as the Netherlands is, and the Rockies to the west. Drawn in name order, then mirrored."""
import json, struct, zlib
from pathlib import Path

HERE = Path(__file__).resolve().parent
W, H = 36, 13            # map size in hexes
TW, TH, SIDE = 28, 32, 16  # pointy-topped hexes, as in Hexmosphere's exports

# gid: (name, fill, edge, mark)
TILES = {
    1: ("deep water", (36, 78, 140), (28, 62, 112), None),
    2: ("river or moat", (78, 140, 200), (60, 116, 170), None),
    3: ("polder", (128, 186, 92), (104, 156, 74), None),
    4: ("dike", (150, 132, 96), (120, 104, 74), "bar"),
    5: ("star fort", (176, 168, 156), (110, 100, 92), "star"),
    6: ("castle", (168, 120, 96), (110, 74, 60), "tower"),
    7: ("windmill", (128, 186, 92), (104, 156, 74), "mill"),
    8: ("plains", (214, 194, 132), (184, 164, 108), None),
    9: ("city", (150, 150, 162), (96, 96, 110), "blocks"),
    10: ("foothills", (164, 150, 102), (132, 118, 80), "hill"),
    11: ("mountains", (120, 108, 100), (88, 78, 72), "peak"),
    12: ("snow", (236, 240, 246), (186, 192, 204), "peak"),
    13: ("beach", (232, 216, 160), (200, 184, 130), None),
    14: ("woods", (74, 130, 76), (58, 106, 60), None),  # for the real ends (ends.py)
}
DARK = (40, 36, 34)


def inside_hex(x, y, inset=0.0):
    """Is pixel centre (x, y) inside the pointy hex filling a TW x TH tile?"""
    cx, cy, hw = TW / 2, TH / 2, TW / 2 - inset
    dx, dy = abs(x - cx), abs(y - cy)
    return dx <= hw and dy <= (TH / 2 - inset) - dx * (TH - SIDE) / TW


def mark(kind, x, y):
    cx, cy = TW / 2, TH / 2
    dx, dy = x - cx, y - cy
    if kind == "bar":
        return abs(dy) < 2
    if kind == "star":  # a five-pointed bastion outline, roughly
        import math
        r, a = math.hypot(dx, dy), math.atan2(dy, dx)
        edge = 5 + 3.5 * abs(math.cos(2.5 * a))
        return edge - 1.5 < r < edge + 0.5
    if kind == "tower":
        return (abs(dx) < 4 and -6 < dy < 6) or (abs(dx) < 6 and -8 < dy < -5 and int(dx + 6) % 3 != 1)
    if kind == "mill":
        return abs(abs(dx) - abs(dy)) < 1.2 and abs(dx) < 7
    if kind == "blocks":
        return any(abs(dx - bx) < 2 and dy > by for bx, by in ((-6, 0), (-2, -6), (2, -3), (6, 1)) ) and dy < 7
    if kind == "hill":
        return abs((dy + 2) - 0.15 * dx * dx) < 1.2 and abs(dx) < 8
    if kind == "peak":
        return abs(dy + 6 - 1.6 * abs(dx)) < 1.4 and dy < 7
    return False


def tileset_png():
    w = TW * len(TILES)
    rows = []
    for y in range(TH):
        row = bytearray([0])
        for gid in sorted(TILES):
            _, fill, edge, kind = TILES[gid]
            for x in range(TW):
                px, py = x + 0.5, y + 0.5
                if not inside_hex(px, py):
                    row += bytes(4)
                elif kind and mark(kind, px, py):
                    row += bytes((*DARK, 255))
                elif inside_hex(px, py, 1.5):
                    row += bytes((*fill, 255))
                else:
                    row += bytes((*edge, 255))
        rows.append(bytes(row))
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, TH, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(b"".join(rows), 9)) + chunk(b"IEND", b"")), w


def terrain(c, r):
    """The made-up land, column by column, west (Heusden) to east (the Rockies)."""
    river = 6                          # the Maas, then the South Platte
    if c <= 9:                          # the Land van Heusden en Altena
        if r == river:
            return 2
        if r in (river - 1, river + 1) and c >= 1:
            return 4                    # dikes along the Maas
        return 7 if (c, r) in ((1, 2), (6, 10), (8, 3), (8, 11)) else 3
    if c <= 10:
        return 13
    if c <= 17:                         # a very short Atlantic
        return 1
    if c == 18:
        return 13
    if c <= 27:                         # the plains
        return 2 if r == river and c >= 21 else 8
    if c <= 29:
        return 9 if 4 <= r <= 8 else (2 if r == river else 8)
    if c == 30:
        return 10
    if c <= 33:
        return 11 if (r + c) % 4 else 12
    return 12


data = [terrain(c, r) for r in range(H) for c in range(W)]
# Heusden's star fort in its moat, and Kasteel Dussen in its own.
for (c, r), gid in {(5, 3): 5, (4, 3): 2, (6, 3): 2, (5, 2): 2, (4, 2): 2, (5, 4): 2, (4, 4): 2,
                    (3, 10): 6, (2, 10): 2, (4, 10): 2, (3, 9): 2, (2, 9): 2}.items():
    data[r * W + c] = gid
# Turn it to match the real directions: Heusden east, the Front Range west.
data = [data[r * W + (W - 1 - c)] for r in range(H) for c in range(W)]


def centre(c, r):
    """Pixel centre of hex (c, r) for staggeraxis y, staggerindex odd."""
    return c * TW + TW / 2 + (TW / 2 if r % 2 else 0), r * (TH + SIDE) / 2 + TH / 2


places = [
    ("Heusden", 5, 3, "A star-shaped fortress town on the Maas. Ramparts are better than regrets."),
    ("Kasteel Dussen", 3, 10, "A moated castle on the river flats. Its moat is easy to explain, so it may be a good castle."),
    ("The Maas", 2, 6, "The river, held between its dikes. Water should never pass silently, unless explicitly pumped."),
    ("A Very Short Atlantic", 14, 6, "Folded small so the two ends can see each other."),
    ("The Plains", 23, 3, "Flat is better than nested, and the plains agree with the polder."),
    ("Denver", 28, 6, "The Den and the Ver of the HeusDenVerSe, a mile up."),
    ("The Front Range", 32, 5, "Mountains to the west of Denver, where they belong."),
]
places = [(name, W - 1 - c, r, text) for name, c, r, text in places]  # mirrored, as the land is
objects = []
for i, (name, c, r, text) in enumerate(places, 1):
    x, y = centre(c, r)
    objects.append({"id": i, "name": name, "type": "place", "point": True, "x": x, "y": y,
                    "width": 0, "height": 0, "rotation": 0, "visible": True,
                    "properties": [{"name": "description", "type": "string", "value": text}]})
title = {"id": len(objects) + 1, "name": "title", "type": "label", "x": centre(18, 1)[0], "y": centre(18, 1)[1] - 14, "width": 260,
         "height": 30, "rotation": 0, "visible": True,
         "text": {"text": "The HeusDenVerSe", "pixelsize": 22, "bold": True, "wrap": False, "color": "#f4efe2"}}
labels = []
for i, (name, c, r, _) in enumerate(places, len(objects) + 2):
    x, y = centre(c, r)
    labels.append({"id": i, "name": name, "type": "label", "x": x - 60, "y": y + 8, "width": 120, "height": 18,
                   "rotation": 0, "visible": True,
                   "text": {"text": name, "pixelsize": 11, "bold": True, "halign": "center", "wrap": False,
                            "color": "#1c1c24"}})

png, png_w = tileset_png()
(HERE / "map").mkdir(exist_ok=True)
(HERE / "map/tiles.png").write_bytes(png)
tmj = {
    "type": "map", "version": "1.10", "tiledversion": "1.12.2", "orientation": "hexagonal",
    "renderorder": "right-down", "staggeraxis": "y", "staggerindex": "odd", "hexsidelength": SIDE,
    "width": W, "height": H, "tilewidth": TW, "tileheight": TH, "infinite": False,
    "backgroundcolor": "#f4efe2", "nextlayerid": 4, "nextobjectid": len(objects) + len(labels) + 2,
    # Where Hexmosphere's Open Tiled puts it: on the bridge, 60% of the way from Heusden to Denver
    # (bridge.py's great circle), where H3's local grid can place every hex at resolution 3, Hexmosphere's biggest size
    # (hexes about 119 km across), so the made-up map is as big as the bridge, not a speck beside it.
    "properties": [{"name": "motto", "type": "string", "value": "Hexes are one honking great idea"},
                   {"name": "centre_latitude", "type": "float", "value": 58.07},
                   {"name": "centre_longitude", "type": "float", "value": -71.61},
                   {"name": "h3_resolution", "type": "int", "value": 3}],
    "tilesets": [{"firstgid": 1, "name": "heusdenverse", "image": "map/tiles.png", "imagewidth": png_w,
                  "imageheight": TH, "tilewidth": TW, "tileheight": TH, "tilecount": len(TILES),
                  "columns": len(TILES), "margin": 0, "spacing": 0,
                  "tiles": [{"id": g - 1, "type": TILES[g][0]} for g in sorted(TILES)]}],
    "layers": [
        {"id": 1, "name": "land", "type": "tilelayer", "width": W, "height": H, "x": 0, "y": 0,
         "opacity": 1, "visible": True, "data": data},
        {"id": 2, "name": "places", "type": "objectgroup", "draworder": "topdown", "x": 0, "y": 0,
         "opacity": 1, "visible": True, "objects": objects},
        {"id": 3, "name": "labels", "type": "objectgroup", "draworder": "topdown", "x": 0, "y": 0,
         "opacity": 1, "visible": True, "objects": [title] + labels},
    ],
}
(HERE / "flat-island.tmj").write_text(json.dumps(tmj, indent=1) + "\n")
print(f"wrote {HERE / 'flat-island.tmj'} ({W} x {H} hexes, {len(places)} places)")
