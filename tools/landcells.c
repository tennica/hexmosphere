// SPDX-License-Identifier: Apache-2.0
// Fill land polygons with H3 cells and compact them, using the vendored H3 C library.
//
// Input (stdin): one polygon per block. A block is a line "P <rings>", then for each
// ring a line "R <points>" followed by that many "lat lng" lines in degrees. The first
// ring is the outer boundary and the rest are holes.
// Output (argv[2]): the compacted cells as little-endian uint64s; a summary on stderr.
//
//   landcells <resolution> <output.cells> < rings.txt

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "h3api.h"

static int compare(const void *a, const void *b) {
    H3Index x = *(const H3Index *)a, y = *(const H3Index *)b;
    return x < y ? -1 : x > y;
}

static int readRing(GeoLoop *loop) {
    int points;
    if (scanf(" R %d", &points) != 1) return 0;
    loop->numVerts = points;
    loop->verts = calloc(points, sizeof(LatLng));
    for (int i = 0; i < points; i++) {
        double lat, lng;
        if (scanf(" %lf %lf", &lat, &lng) != 2) return 0;
        loop->verts[i].lat = degsToRads(lat);
        loop->verts[i].lng = degsToRads(lng);
    }
    return 1;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: landcells <resolution> <output.cells> < rings.txt\n");
        return 2;
    }
    int res = atoi(argv[1]);
    size_t capacity = 1 << 20, count = 0;
    H3Index *all = malloc(capacity * sizeof(H3Index));
    int polygons = 0, rings;
    while (scanf(" P %d", &rings) == 1) {
        GeoPolygon polygon = {0};
        if (!readRing(&polygon.geoloop)) return 1;
        polygon.numHoles = rings - 1;
        polygon.holes = calloc(rings > 1 ? rings - 1 : 1, sizeof(GeoLoop));
        for (int h = 0; h < rings - 1; h++) {
            if (!readRing(&polygon.holes[h])) return 1;
        }
        int64_t max = 0;
        if (maxPolygonToCellsSize(&polygon, res, 0, &max) != E_SUCCESS) {
            fprintf(stderr, "polygon %d: size estimate failed, skipped\n", polygons);
        } else {
            H3Index *cells = calloc(max, sizeof(H3Index));
            if (polygonToCells(&polygon, res, 0, cells) != E_SUCCESS) {
                fprintf(stderr, "polygon %d: polygonToCells failed, skipped\n", polygons);
            } else {
                for (int64_t i = 0; i < max; i++) {
                    if (!cells[i]) continue;
                    if (count == capacity) {
                        capacity *= 2;
                        all = realloc(all, capacity * sizeof(H3Index));
                    }
                    all[count++] = cells[i];
                }
            }
            free(cells);
        }
        free(polygon.geoloop.verts);
        for (int h = 0; h < rings - 1; h++) free(polygon.holes[h].verts);
        free(polygon.holes);
        polygons++;
    }

    // Neighbouring polygons can share a cell; compactCells needs each cell once.
    qsort(all, count, sizeof(H3Index), compare);
    size_t unique = 0;
    for (size_t i = 0; i < count; i++) {
        if (unique == 0 || all[i] != all[unique - 1]) all[unique++] = all[i];
    }
    H3Index *compacted = calloc(unique, sizeof(H3Index));
    if (compactCells(all, compacted, (int64_t)unique) != E_SUCCESS) {
        fprintf(stderr, "compactCells failed\n");
        return 1;
    }
    size_t kept = 0;
    int byRes[16] = {0};
    FILE *out = fopen(argv[2], "wb");
    for (size_t i = 0; i < unique; i++) {
        if (!compacted[i]) continue;
        fwrite(&compacted[i], sizeof(H3Index), 1, out);  // little-endian on Apple silicon
        byRes[getResolution(compacted[i])]++;
        kept++;
    }
    fclose(out);
    fprintf(stderr, "%d polygons → %zu cells at res %d → %zu after compacting:", polygons, unique, res, kept);
    for (int r = 0; r <= res; r++) if (byRes[r]) fprintf(stderr, " res%d %d", r, byRes[r]);
    fprintf(stderr, "\n");
    return 0;
}
