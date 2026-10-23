// SPDX-License-Identifier: Apache-2.0
//! The four H3 operations Hexmosphere uses, exposed as C functions over h3o.
//! Degrees in, degrees out; a cell index of 0 means "no cell".

// The crate itself uses std (for its allocator); h3o is still built without
// its `std` feature, which is what keeps ahash and its CC0 dependency out.
use h3o::{CellIndex, LatLng, Resolution};

/// The cell at `resolution` containing a point, or 0 if the point or
/// resolution is invalid.
#[no_mangle]
pub extern "C" fn h3o_cell_for(latitude: f64, longitude: f64, resolution: u8) -> u64 {
    let (Ok(point), Ok(res)) = (LatLng::new(latitude, longitude), Resolution::try_from(resolution)) else {
        return 0;
    };
    u64::from(point.to_cell(res))
}

/// Writes up to `capacity` outline vertices of `cell` into `latitudes` and
/// `longitudes` (degrees) and returns how many were written; 0 for an
/// invalid cell. Ten is always enough.
///
/// # Safety
/// Both buffers must hold at least `capacity` values.
#[no_mangle]
pub unsafe extern "C" fn h3o_cell_outline(
    cell: u64,
    latitudes: *mut f64,
    longitudes: *mut f64,
    capacity: usize,
) -> usize {
    let Ok(index) = CellIndex::try_from(cell) else {
        return 0;
    };
    let mut written = 0;
    for vertex in index.boundary().iter().take(capacity) {
        *latitudes.add(written) = vertex.lat();
        *longitudes.add(written) = vertex.lng();
        written += 1;
    }
    written
}

/// Writes `cell`'s local I and J coordinates relative to `origin` (same
/// resolution, not too far away) and returns true, or returns false when H3
/// can't place it, as across pentagon distortion. Matches H3 C's cellToLocalIj.
///
/// # Safety
/// `i` and `j` must be valid pointers.
#[no_mangle]
pub unsafe extern "C" fn h3o_cell_to_local_ij(origin: u64, cell: u64, i: *mut i32, j: *mut i32) -> bool {
    let (Ok(origin), Ok(cell)) = (CellIndex::try_from(origin), CellIndex::try_from(cell)) else {
        return false;
    };
    let Ok(local) = cell.to_local_ij(origin) else {
        return false;
    };
    *i = local.coord.i;
    *j = local.coord.j;
    true
}

/// Average hexagon edge length in metres at `resolution`, or 0 if invalid.
#[no_mangle]
pub extern "C" fn h3o_edge_length_m(resolution: u8) -> f64 {
    Resolution::try_from(resolution).map_or(0.0, |res| res.edge_length_m())
}
