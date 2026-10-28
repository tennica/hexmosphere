// SPDX-License-Identifier: Apache-2.0
// "lat lng" lines in, the H3 cell at a resolution out, one per line (0 if none): for strip.py.
//   cells <resolution> < points.txt
#include <stdio.h>
#include <stdlib.h>
#include "h3api.h"
int main(int argc, char **argv) {
    int res = argc > 1 ? atoi(argv[1]) : 3;
    double lat, lng;
    while (scanf("%lf %lf", &lat, &lng) == 2) {
        LatLng g = {degsToRads(lat), degsToRads(lng)};
        H3Index c = 0;
        latLngToCell(&g, res, &c);
        printf("%llx\n", (unsigned long long)c);
    }
}
