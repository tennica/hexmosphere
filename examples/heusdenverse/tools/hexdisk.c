// SPDX-License-Identifier: Apache-2.0
// The H3 cells within k rings of a point, with each one's local I/J around the point's cell
// and its centre, for ends.py.
//   hexdisk <resolution> <k> <lat> <lng>   ->   "h3 i j lat lng" lines (cells H3 can't place are skipped)
#include <stdio.h>
#include <stdlib.h>
#include "h3api.h"

int main(int argc, char **argv) {
    if (argc != 5) { fprintf(stderr, "usage: hexdisk <resolution> <k> <lat> <lng>\n"); return 2; }
    int res = atoi(argv[1]), k = atoi(argv[2]);
    LatLng g = {degsToRads(atof(argv[3])), degsToRads(atof(argv[4]))};
    H3Index origin;
    if (latLngToCell(&g, res, &origin)) return 1;
    int64_t n;
    maxGridDiskSize(k, &n);
    H3Index *cells = calloc(n, sizeof(H3Index));
    if (gridDisk(origin, k, cells)) return 1;
    for (int64_t x = 0; x < n; x++) {
        CoordIJ ij;
        LatLng c;
        if (!cells[x] || cellToLocalIj(origin, cells[x], 0, &ij) || cellToLatLng(cells[x], &c)) continue;
        printf("%llx %d %d %.7f %.7f\n", (unsigned long long)cells[x], ij.i, ij.j, radsToDegs(c.lat), radsToDegs(c.lng));
    }
    return 0;
}
