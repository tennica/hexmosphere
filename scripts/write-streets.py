#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Write a region's OpenStreetMap streets as a .tiles file the app reads a piece at a time.

    write-streets.py <overpass-folder | osmium.geojsonseq> <out.tiles>

The input is either a folder of Overpass answers (fetch-basemap.sh streets) or a GeoJSON
sequence of lines exported by osmium (fetch-basemap.sh extract).

Streets are cut into 1° squares ("chunks") at four levels, so the app only reads what a
map tile needs: level 3 is the motorways and trunk roads, simplified to about 1 km, for the
widest views (zooms 5 to 7); level 0 is an overview of the main roads, simplified to about
100 m, for zooms 7 to 10; level 1 is every street shown before zoom 14, at full detail;
level 2 is the residential streets, from zoom 14. A street crossing a square's edge is cut
there, the two parts sharing the point where it crosses.

OpenStreetMap splits a road into a new way at every bridge, junction and change of lanes,
so for levels 3 and 0 the ways of each class are first joined end to end into long lines.
Zoomed out, a tile then strokes a few thousand long lines instead of a hundred thousand
fragments of two or three points.

The file, little-endian:
    header   "HXST", uint16 version (1), uint16 0, uint32 chunk count,
             uint32 street count and uint32 point count (levels 1 and 2: the full detail)
    index    per chunk: int16 south, int16 west (the square's corner in degrees), uint8 level,
             uint8 0, uint16 0, uint64 offset, uint32 length, uint32 part count, and float32
             west, south, east, north (the parts' bounds, which reach a little past the square)
    chunks   per part: uint8 kind (as in roads.bin), uint8 minimum zoom × 10, uint16 point
             count, then that many uint16 (x, y) pairs: degrees east and north of the square's
             corner less PAD, in steps of SPAN / 65535 (about 2 m)
"""

import glob
import json
import math
import os
import struct
import sys
from collections import defaultdict, deque

PAD = 0.25    # how far a part may reach past its square, in degrees
SPAN = 1 + 2 * PAD
STEP = SPAN / 65535
LONGEST = 0.2  # longer segments get extra points, so a part never reaches past PAD
OVERVIEW_ZOOM = 9  # classes shown before this zoom (or at it) go in the overview
OVERVIEW_TOLERANCE = 0.001  # degrees, about 100 m: half a screen point at zoom 9
DETAIL_ZOOM = 14  # classes shown from here are level 2
WIDE_ZOOM = 6  # classes shown from this zoom or before go in level 3, the widest views
WIDE_TOLERANCE = 0.01  # degrees, about 1 km: under a screen point at zoom 7

# Kind (as in roads.bin) and the zoom level to show each class from.
classes = {
    "motorway": (0, 5), "trunk": (0, 6), "motorway_link": (0, 11), "trunk_link": (0, 11),
    "primary": (1, 8), "primary_link": (1, 12), "secondary": (1, 9), "secondary_link": (1, 12),
    "tertiary": (2, 11), "tertiary_link": (2, 13), "unclassified": (2, 12),
    "residential": (2, 14), "living_street": (2, 14), "pedestrian": (2, 14),
}


def lines(source):
    """(highway class, [(lon, lat), …]) for each street."""
    if os.path.isdir(source):
        ways = {}
        for path in sorted(glob.glob(f"{source}/*.json")):
            for element in json.load(open(path))["elements"]:
                if element.get("type") == "way" and element.get("geometry"):
                    ways[element["id"]] = element   # a way crossing squares comes back in each
        for way in ways.values():
            yield way["tags"].get("highway"), [(p["lon"], p["lat"]) for p in way["geometry"]]
    else:
        for record in open(source):
            feature = json.loads(record.lstrip("\x1e"))
            if feature["geometry"]["type"] == "LineString":
                yield feature["properties"].get("highway"), [tuple(c[:2]) for c in feature["geometry"]["coordinates"]]


def densify(line):
    """The line with extra points wherever a segment is longer than LONGEST."""
    out = [line[0]]
    for (x0, y0), (x1, y1) in zip(line, line[1:]):
        steps = math.ceil(max(abs(x1 - x0), abs(y1 - y0)) / LONGEST)
        for i in range(1, steps):
            out.append((x0 + (x1 - x0) * i / steps, y0 + (y1 - y0) * i / steps))
        out.append((x1, y1))
    return out


def simplify(line, tolerance):
    """Douglas–Peucker, iteratively, in degrees."""
    if len(line) < 3:
        return line
    keep = [False] * len(line)
    keep[0] = keep[-1] = True
    stack = [(0, len(line) - 1)]
    while stack:
        first, last = stack.pop()
        (x0, y0), (x1, y1) = line[first], line[last]
        dx, dy = x1 - x0, y1 - y0
        length = math.hypot(dx, dy)
        worst, at = 0.0, None
        for i in range(first + 1, last):
            x, y = line[i]
            d = abs(dy * (x - x0) - dx * (y - y0)) / length if length else math.hypot(x - x0, y - y0)
            if d > worst:
                worst, at = d, i
        if at is not None and worst > tolerance:
            keep[at] = True
            stack += [(first, at), (at, last)]
    return [p for p, k in zip(line, keep) if k]


def square(point):
    return math.floor(point[1]), math.floor(point[0])


def parts(line):
    """(square, part) pieces of the line, cut where it leaves each square."""
    part, here = [line[0]], square(line[0])
    for point in line[1:]:
        part.append(point)
        there = square(point)
        if there != here or len(part) == 65535:
            yield here, part
            part, here = [point], there
    if len(part) >= 2:
        yield here, part


def join(lines):
    """The lines joined end to end where one ends at another's start or end. A line
    meeting two others at a junction carries on into either; the rest start lines of
    their own."""
    ends = defaultdict(list)
    for i, line in enumerate(lines):
        ends[line[0]].append(i)
        ends[line[-1]].append(i)
    used = [False] * len(lines)
    for i, first in enumerate(lines):
        if used[i]:
            continue
        used[i] = True
        line = deque(first)
        for forward in (True, False):
            while True:
                tip = line[-1] if forward else line[0]
                j = next((j for j in ends[tip] if not used[j]), None)
                if j is None:
                    break
                used[j] = True
                more = lines[j]
                if forward:
                    line.extend((more if more[0] == tip else more[::-1])[1:])
                else:
                    line.extendleft(reversed((more if more[-1] == tip else more[::-1])[:-1]))
        yield list(line)


class Chunk:
    """One square at one level, packed as it fills, so a whole country fits in memory."""

    def __init__(self, south, west):
        self.x0, self.y0 = west - PAD, south - PAD
        self.body = bytearray()
        self.count = 0
        self.bounds = [math.inf, math.inf, -math.inf, -math.inf]

    def add(self, kind, zoom, part):
        self.body += struct.pack("<BBH", kind, zoom * 10, len(part))
        self.body += struct.pack(f"<{len(part) * 2}H", *(
            v for x, y in part for v in (round((x - self.x0) / STEP), round((y - self.y0) / STEP))))
        self.count += 1
        xs, ys = [x for x, _ in part], [y for _, y in part]
        b = self.bounds
        b[:] = min(b[0], min(xs)), min(b[1], min(ys)), max(b[2], max(xs)), max(b[3], max(ys))


def main():
    source, target = sys.argv[1:]
    chunks = {}   # (level, south, west) -> Chunk
    streets = points = 0

    def add(level, line, kind, zoom):
        for (south, west), part in parts(densify(line)):
            key = (level, south, west)
            if key not in chunks:
                chunks[key] = Chunk(south, west)
            chunks[key].add(kind, zoom, part)

    overview = defaultdict(list)   # (kind, zoom) -> simplified lines, joined at the end
    for highway, line in lines(source):
        if len(line) < 2:
            continue
        kind, zoom = classes.get(highway, (2, DETAIL_ZOOM))
        streets += 1
        points += len(line)
        add(2 if zoom >= DETAIL_ZOOM else 1, line, kind, zoom)
        if zoom <= OVERVIEW_ZOOM:
            overview[(kind, zoom)].append(tuple(simplify(line, OVERVIEW_TOLERANCE)))

    # Simplifying keeps each way's end points, so joined ways meet exactly.
    joined = 0
    for (kind, zoom), group in overview.items():
        for line in join(group):
            joined += 1
            add(0, simplify(line, OVERVIEW_TOLERANCE), kind, zoom)
            if zoom <= WIDE_ZOOM:
                add(3, simplify(line, WIDE_TOLERANCE), kind, zoom)
    overview_ways = sum(len(group) for group in overview.values())

    entry = struct.Struct("<hhBBHQIIffff")
    keys = sorted(chunks)
    offset = 20 + entry.size * len(keys)
    with open(target, "wb") as out:
        out.write(b"HXST" + struct.pack("<HHIII", 1, 0, len(keys), streets, points))
        for level, south, west in keys:
            chunk = chunks[(level, south, west)]
            out.write(entry.pack(south, west, level, 0, 0, offset, len(chunk.body), chunk.count, *chunk.bounds))
            offset += len(chunk.body)
        for key in keys:
            out.write(chunks[key].body)
    levels = [sum(1 for (l, _, _) in chunks if l == level) for level in range(4)]
    print(f"streets: {streets} streets, {points} points; {len(keys)} chunks "
          f"({levels[3]} wide, {levels[0]} overview, {levels[1]} main, {levels[2]} residential); "
          f"{overview_ways} main-road ways joined into {joined} lines")


if __name__ == "__main__":
    main()
