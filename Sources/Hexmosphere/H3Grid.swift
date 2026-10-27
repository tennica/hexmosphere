// SPDX-License-Identifier: Apache-2.0
// Thin Swift wrappers over two H3 implementations, and the binning of samples into cells.
// Both are built in and chosen at runtime: the h3o Rust library (Packages/h3o-ffi)
// or Uber's H3 C library 4.5.0 (Packages/CH3), the reference implementation.
// They agree on cells, outlines and edge lengths; the switch is there to compare
// an independent implementation with the reference. The backend is always passed
// explicitly, so background binning can't mix the two.

import CH3
import CH3O
import CoreLocation
import Foundation

enum H3Backend: String, CaseIterable, Identifiable {
    case h3o = "h3o"
    case h3c = "H3 C"

    var id: String { rawValue }

    /// For the summary line.
    var name: String { self == .h3o ? "h3o (Rust)" : "H3 (C)" }
}

/// Odd resolutions only, each about 7x finer across (49x in area) than the last:
/// 3 (about 120 km, region), 5 (about 17 km, metro area), 7 (about 2.4 km, town, the default),
/// 9 (about 350 m, neighbourhood) and 11 (about 50 m, building).
/// The coarse sizes keep a library spread across continents visible when zoomed
/// out. In solstone's tests (solstone-journal #397) 11 was borderline against
/// the 50 m place rule and 12 broke down.
enum CellSize: Int, CaseIterable, Identifiable {
    case r3 = 3, r5 = 5, r7 = 7, r9 = 9, r11 = 11

    var id: Int { rawValue }

    /// Average edge length in metres, as the chosen backend reports it.
    func edgeMetres(_ backend: H3Backend) -> Double {
        switch backend {
        case .h3o:
            return h3o_edge_length_m(UInt8(rawValue))
        case .h3c:
            var out = 0.0
            _ = getHexagonEdgeLengthAvgM(Int32(rawValue), &out)
            return out
        }
    }

    /// Distance across a hexagon between flat sides (edge × √3), as in solstone's labels.
    func label(_ backend: H3Backend) -> String {
        "about \(across(backend)) (res \(rawValue))"
    }

    /// Just the distance, for the size buttons, where space is tight on iPad.
    func across(_ backend: H3Backend) -> String {
        let metres = edgeMetres(backend) * 3.0.squareRoot()
        return metres >= 10_000
            ? "\(Int((metres / 1000).rounded())) km"
            : metres >= 1000
            ? String(format: "%.1f km", metres / 1000)
            : "\(Int((metres / 10).rounded() * 10)) m"
    }
}

typealias CellID = UInt64

func cellFor(_ coordinate: CLLocationCoordinate2D, size: CellSize, backend: H3Backend) -> CellID? {
    switch backend {
    case .h3o:
        let cell = h3o_cell_for(coordinate.latitude, coordinate.longitude, UInt8(size.rawValue))
        return cell == 0 ? nil : cell
    case .h3c:
        var point = LatLng(lat: degsToRads(coordinate.latitude), lng: degsToRads(coordinate.longitude))
        var cell: H3Index = 0
        guard latLngToCell(&point, Int32(size.rawValue), &cell) == 0 else { return nil }
        return cell
    }
}

/// The cell's outline as coordinates, ready for a map polygon.
func outline(of cell: CellID, backend: H3Backend) -> [CLLocationCoordinate2D] {
    switch backend {
    case .h3o:
        var latitudes = [Double](repeating: 0, count: 10)
        var longitudes = [Double](repeating: 0, count: 10)
        let count = h3o_cell_outline(cell, &latitudes, &longitudes, 10)
        return (0..<count).map { CLLocationCoordinate2D(latitude: latitudes[$0], longitude: longitudes[$0]) }
    case .h3c:
        var boundary = CellBoundary()
        guard cellToBoundary(cell, &boundary) == 0 else { return [] }
        let count = Int(boundary.numVerts)
        return withUnsafeBytes(of: &boundary.verts) { raw in
            let vertices = raw.bindMemory(to: LatLng.self)
            return (0..<count).map {
                CLLocationCoordinate2D(latitude: radsToDegs(vertices[$0].lat), longitude: radsToDegs(vertices[$0].lng))
            }
        }
    }
}

/// `cell`'s position on H3's local I/J grid around `origin` (same resolution),
/// or nil when H3 can't place it (too far away, or across pentagon distortion).
func localIJ(of cell: CellID, origin: CellID, backend: H3Backend) -> (i: Int, j: Int)? {
    switch backend {
    case .h3o:
        var i: Int32 = 0, j: Int32 = 0
        guard h3o_cell_to_local_ij(origin, cell, &i, &j) else { return nil }
        return (Int(i), Int(j))
    case .h3c:
        var coord = CoordIJ()
        guard cellToLocalIj(origin, cell, 0, &coord) == 0 else { return nil }
        return (Int(coord.i), Int(coord.j))
    }
}

// Cell ids are the same in both backends, so these use the C library either way.

/// Whether `cell` is one of the twelve pentagons H3 has at every resolution.
func isPentagonCell(_ cell: CellID) -> Bool {
    isPentagon(cell) != 0
}

func resolution(of cell: CellID) -> Int {
    Int(getResolution(cell))
}

/// `cell`'s parent at a coarser `resolution`, or nil if there's none.
func parent(of cell: CellID, at resolution: Int) -> CellID? {
    var out: H3Index = 0
    return cellToParent(cell, Int32(resolution), &out) == 0 ? out : nil
}

/// `cell`'s children at a finer `resolution`: seven per level for a hexagon, six for a pentagon.
func children(of cell: CellID, at resolution: Int) -> [CellID] {
    var count: Int64 = 0
    guard cellToChildrenSize(cell, Int32(resolution), &count) == 0 else { return [] }
    var out = [H3Index](repeating: 0, count: Int(count))
    guard cellToChildren(cell, Int32(resolution), &out) == 0 else { return [] }
    return out.filter { $0 != 0 }
}

/// The child at `cell`'s centre at a finer `resolution` (a pentagon's is a pentagon).
func centreChild(of cell: CellID, at resolution: Int) -> CellID? {
    var out: H3Index = 0
    return cellToCenterChild(cell, Int32(resolution), &out) == 0 ? out : nil
}

func cellName(_ cell: CellID) -> String {
    String(cell, radix: 16)
}

struct Sample {
    let coordinate: CLLocationCoordinate2D
    let date: Date
    /// Reported horizontal accuracy in metres, when the source gives one.
    let accuracy: Double?
    /// The Photos library's identifier for the item, for showing its thumbnail.
    let assetID: String
}

struct CellSummary: Identifiable {
    let id: CellID
    var samples = 0
    var days = Set<DateComponents>()
    var first = Date.distantFuture
    var last = Date.distantPast
    /// Every photo in the cell, for thumbnails: (date taken, Photos identifier).
    var photos: [(date: Date, assetID: String)] = []
}

struct Binned {
    /// New for every binning, so the map can tell when its cells need rebuilding.
    var id = UUID()
    /// The backend these cells were made with, used again to draw and look them up.
    var backend = H3Backend.h3o
    /// The cell size they were made at.
    var size = CellSize.r7
    var cells: [CellID: CellSummary] = [:]
    /// Samples whose reported accuracy is coarser than the cell, so they would
    /// land in a cell more or less at random (the same rule as solstone's map).
    var tooCoarse = 0

    /// What a cell is shaded by: how many photos fell in it.
    func value(_ cell: CellSummary) -> Int {
        cell.samples
    }
}

func bin(_ samples: [Sample], size: CellSize, backend: H3Backend, calendar: Calendar = .current) -> Binned {
    var result = Binned(backend: backend, size: size)
    let edge = size.edgeMetres(backend)
    for sample in samples {
        if let accuracy = sample.accuracy, accuracy > edge {
            result.tooCoarse += 1
            continue
        }
        guard let cell = cellFor(sample.coordinate, size: size, backend: backend) else { continue }
        var summary = result.cells[cell] ?? CellSummary(id: cell)
        summary.samples += 1
        summary.days.insert(calendar.dateComponents([.year, .month, .day], from: sample.date))
        summary.first = min(summary.first, sample.date)
        summary.last = max(summary.last, sample.date)
        summary.photos.append((sample.date, sample.assetID))
        result.cells[cell] = summary
    }
    return result
}
