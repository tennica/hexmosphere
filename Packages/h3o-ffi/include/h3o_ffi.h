// SPDX-License-Identifier: Apache-2.0
// C functions over the h3o Rust library (see src/lib.rs). Degrees in and out.
#ifndef H3O_FFI_H
#define H3O_FFI_H

#include <stddef.h>
#include <stdint.h>

/// The cell at `resolution` containing a point, or 0 if invalid.
uint64_t h3o_cell_for(double latitude, double longitude, uint8_t resolution);

/// Writes up to `capacity` outline vertices (degrees) and returns how many; 0 if invalid.
size_t h3o_cell_outline(uint64_t cell, double *latitudes, double *longitudes, size_t capacity);

/// Average hexagon edge length in metres at `resolution`, or 0 if invalid.
double h3o_edge_length_m(uint8_t resolution);

#endif
