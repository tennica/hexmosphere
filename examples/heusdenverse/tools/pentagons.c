// SPDX-License-Identifier: Apache-2.0
// The twelve H3 pentagons at a resolution: index, centre, for checking what a map passes near.
#include <stdio.h>
#include <stdlib.h>
#include "h3api.h"
int main(int argc, char **argv) {
    int res = argc > 1 ? atoi(argv[1]) : 0;
    H3Index out[12];
    if (getPentagons(res, out)) return 1;
    for (int i = 0; i < 12; i++) { LatLng c; cellToLatLng(out[i], &c);
        printf("%llx %.2f %.2f\n", (unsigned long long)out[i], radsToDegs(c.lat), radsToDegs(c.lng)); }
}
