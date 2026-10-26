#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Make a Demo Drive route from the streets fetched for the base map.

    demo-route.py <overpass-folder | osmium.geojsonseq> <out.json> --title T --speed M/S --times N
                  (--name NAME… | --ref REF [--also REF]) --from LAT,LON [--via LAT,LON…] --to LAT,LON
                  [--connect] [--gap METRES] [--note TEXT]

Takes the OpenStreetMap ways named any of the NAMEs (repeat --name for a route that turns
from street to street), or whose ref list includes REF (e.g. "CA 1" also matches
"US 101;CA 1"), joins them into a graph at shared points, and keeps the shortest path from
the point nearest --from, through the points nearest each --via in turn, to --to. Ways with the --also ref
count three times their length, so the path takes them only where the main ref has no
road of its own (Highway 1 shares US 101 between Ventura and Gaviota). Where the ways don't join
up (a stretch tagged only with another ref), dead ends within --gap of each other (3 km
unless given; keep it small in a city, where dead ends abound) are joined by a straight
line counted at three times its length. With --connect, every other street is in the graph
too at five times its length, so a route through a city keeps to its named streets and
takes another only for a short link between them. --from, --via and --to snap to the
named or ref'd ways, never to a connecting street. The path is simplified to about 5 m and written as JSON for the app:
{"title", "speed" (metres a second in real life), "times" (how much faster the demo runs),
"note", "points": [[lon, lat], …]}.
"""

import argparse
import glob
import heapq
import json
import math
import os

TOLERANCE = 0.00005  # degrees, about 5 m


def ways(source):
    """(tags, [(lon, lat), …]) for each street."""
    if os.path.isdir(source):
        seen = set()
        for path in sorted(glob.glob(f"{source}/*.json")):
            for element in json.load(open(path))["elements"]:
                if element.get("type") == "way" and element.get("geometry") and element["id"] not in seen:
                    seen.add(element["id"])
                    yield element.get("tags", {}), [(p["lon"], p["lat"]) for p in element["geometry"]]
    else:
        for record in open(source):
            feature = json.loads(record.lstrip("\x1e"))
            if feature["geometry"]["type"] == "LineString":
                yield feature["properties"], [tuple(c[:2]) for c in feature["geometry"]["coordinates"]]


def metres(a, b):
    """Distance between two (lon, lat) points, on a sphere."""
    lon1, lat1, lon2, lat2 = map(math.radians, (*a, *b))
    h = math.sin((lat2 - lat1) / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin((lon2 - lon1) / 2) ** 2
    return 2 * 6371000 * math.asin(math.sqrt(h))


def simplify(line, tolerance):
    """Douglas–Peucker, iteratively, in degrees."""
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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("source")
    parser.add_argument("out")
    parser.add_argument("--title", required=True)
    parser.add_argument("--speed", type=float, required=True)
    parser.add_argument("--times", type=float, required=True)
    parser.add_argument("--name", action="append")
    parser.add_argument("--via", action="append", default=[])
    parser.add_argument("--ref")
    parser.add_argument("--also")
    parser.add_argument("--from", dest="start", required=True)
    parser.add_argument("--to", dest="end", required=True)
    parser.add_argument("--gap", type=float, default=3000)
    parser.add_argument("--connect", action="store_true")
    parser.add_argument("--note", default="")
    args = parser.parse_args()

    def cost(tags):
        """How much a metre of this way counts, or None to leave it out."""
        if args.name:
            return 1 if tags.get("name") in args.name else None
        refs = [r.strip() for r in tags.get("ref", "").split(";")]
        return 1 if args.ref in refs else 3 if args.also and args.also in refs else None

    graph = {}
    named = set()   # points on the named or ref'd ways themselves
    for tags, line in ways(args.source):
        weight = cost(tags)
        if weight is None:
            if not args.connect:
                continue
            weight = 5
        elif weight == 1:
            named.update(line)
        for a, b in zip(line, line[1:]):
            d = metres(a, b) * weight
            if d < graph.get(a, {}).get(b, math.inf):
                graph.setdefault(a, {})[b] = d
                graph.setdefault(b, {})[a] = d
    if not named:
        raise SystemExit("no ways matched")

    # Join dead ends that nearly meet, so a stretch tagged differently doesn't break the route.
    ends = [p for p, links in graph.items() if len(links) == 1 and p in named]
    joined = 0
    for i, a in enumerate(ends):
        for b in ends[i + 1:]:
            d = metres(a, b)
            if d <= args.gap and b not in graph[a]:
                graph[a][b] = graph[b][a] = d * 3
                joined += 1

    def nearest(text):
        lat, lon = map(float, text.split(","))
        return min(named, key=lambda p: metres(p, (lon, lat)))

    def shortest(start, end):
        distance, previous = {start: 0.0}, {}
        queue = [(0.0, start)]
        while queue:
            d, here = heapq.heappop(queue)
            if here == end:
                break
            if d > distance[here]:
                continue
            for there, step in graph[here].items():
                if d + step < distance.get(there, math.inf):
                    distance[there] = d + step
                    previous[there] = here
                    heapq.heappush(queue, (d + step, there))
        if end not in distance:
            raise SystemExit(f"no path from {start[1]:.4f},{start[0]:.4f} to {end[1]:.4f},{end[0]:.4f}")
        leg = [end]
        while leg[-1] != start:
            leg.append(previous[leg[-1]])
        return leg[::-1]

    stops = [nearest(p) for p in [args.start, *args.via, args.end]]
    path = [stops[0]]
    for a, b in zip(stops, stops[1:]):
        path += shortest(a, b)[1:]
    points = simplify(path, TOLERANCE)
    json.dump({"title": args.title, "speed": args.speed, "times": args.times, "note": args.note,
               "points": [[round(x, 6), round(y, 6)] for x, y in points]},
              open(args.out, "w"), separators=(",", ":"))
    length = sum(metres(a, b) for a, b in zip(path, path[1:]))
    print(f"{args.title}: {length / 1000:.1f} km, {len(points)} points "
          f"({len(path)} before simplifying), {joined} gaps joined")


if __name__ == "__main__":
    main()
