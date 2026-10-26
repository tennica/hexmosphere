// SPDX-License-Identifier: Apache-2.0
// The chain of H3 cells along a route, using the vendored H3 C library: every cell at a
// resolution that a route passes through, plus the cells within k rings of those. The
// vintage layers clip old maps to it, so a corridor shows as hexagons, not a smooth band.
//
// Input (stdin): "lng lat" lines in degrees, close enough together that no cell along the
// way is skipped (scripts/vintage-fetch.py densifies the route first).
// Output (stdout): the cells as a GeoJSON FeatureCollection of polygons, each with its
// index as the property "h3"; a count on stderr.
//
//   hexchain <resolution> <k> < points.txt > chain.geojson

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include "h3api.h"

static int compare(const void *a, const void *b) {
    H3Index x = *(const H3Index *)a, y = *(const H3Index *)b;
    return x < y ? -1 : x > y;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: hexchain <resolution> <k> < points.txt\n");
        return 2;
    }
    int res = atoi(argv[1]), k = atoi(argv[2]);
    int64_t ring_size;
    maxGridDiskSize(k, &ring_size);
    size_t count = 0, capacity = 1024;
    H3Index *cells = malloc(capacity * sizeof(H3Index));
    H3Index *ring = malloc(ring_size * sizeof(H3Index));
    H3Index last = 0;
    double lng, lat;
    while (scanf("%lf %lf", &lng, &lat) == 2) {
        LatLng point = {degsToRads(lat), degsToRads(lng)};
        H3Index cell;
        if (latLngToCell(&point, res, &cell) != E_SUCCESS || cell == last) continue;
        last = cell;
        gridDisk(cell, k, ring);
        for (int64_t i = 0; i < ring_size; i++) {
            if (!ring[i]) continue;
            if (count == capacity) cells = realloc(cells, (capacity *= 2) * sizeof(H3Index));
            cells[count++] = ring[i];
        }
    }
    // Sort and keep each cell once.
    qsort(cells, count, sizeof(H3Index), compare);
    size_t unique = 0;
    for (size_t i = 0; i < count; i++)
        if (unique == 0 || cells[i] != cells[unique - 1]) cells[unique++] = cells[i];

    printf("{\"type\":\"FeatureCollection\",\"features\":[");
    for (size_t i = 0; i < unique; i++) {
        CellBoundary boundary;
        cellToBoundary(cells[i], &boundary);
        printf("%s{\"type\":\"Feature\",\"properties\":{\"h3\":\"%llx\"},\"geometry\":{\"type\":\"Polygon\",\"coordinates\":[[",
               i ? "," : "", (unsigned long long)cells[i]);
        for (int v = 0; v <= boundary.numVerts; v++) {
            LatLng p = boundary.verts[v % boundary.numVerts];
            printf("%s[%.6f,%.6f]", v ? "," : "", radsToDegs(p.lng), radsToDegs(p.lat));
        }
        printf("]]}}");
    }
    printf("]}\n");
    fprintf(stderr, "hexchain: %zu cells at resolution %d within %d rings\n", unique, res, k);
    free(cells);
    free(ring);
    return 0;
}
