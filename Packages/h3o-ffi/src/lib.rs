// SPDX-License-Identifier: Apache-2.0
//! The three H3 operations Hexmosphere uses, exposed as C functions over h3o.
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

/// Average hexagon edge length in metres at `resolution`, or 0 if invalid.
#[no_mangle]
pub extern "C" fn h3o_edge_length_m(resolution: u8) -> f64 {
    Resolution::try_from(resolution).map_or(0.0, |res| res.edge_length_m())
}
