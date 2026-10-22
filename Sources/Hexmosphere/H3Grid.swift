// SPDX-License-Identifier: Apache-2.0
// Thin Swift wrappers over an H3 implementation, and the binning of samples into cells.
// Two backends, chosen at build time: the h3o Rust library through
// Packages/h3o-ffi (the default; HEX_BACKEND=h3o sets the H3O compilation
// condition) or Uber's H3 C library (HEX_BACKEND=h3c). They give identical cells
// and outlines, but H3 C 4.1.0's average edge lengths are about 13% smaller,
// which changes the size labels and the accuracy cut-off.

#if H3O
import CH3O
#else
import CH3
#endif
import CoreLocation
import Foundation

/// Which H3 implementation this build uses, shown in the summary line.
#if H3O
let h3Backend = "h3o (Rust)"
#else
let h3Backend = "H3 (C)"
#endif

/// Odd resolutions only, each about 7x finer across (49x in area) than the last:
/// 7 (about 2.4 km, town scale), 9 (about 350 m, neighbourhood, the default) and
/// 11 (about 50 m, building scale). In solstone's tests (solstone-journal #397)
/// 11 was borderline against the 50 m place rule and 12 broke down.
enum CellSize: Int, CaseIterable, Identifiable {
    case r7 = 7, r9 = 9, r11 = 11

    var id: Int { rawValue }

    /// Average edge length in metres, from H3 itself.
    var edgeMetres: Double {
        #if H3O
        return h3o_edge_length_m(UInt8(rawValue))
        #else
        var out = 0.0
        _ = getHexagonEdgeLengthAvgM(Int32(rawValue), &out)
        return out
        #endif
    }

    /// Distance across a hexagon between flat sides (edge × √3), as in solstone's labels.
    var label: String {
        let across = edgeMetres * 3.0.squareRoot()
        let text = across >= 1000
            ? String(format: "%.1f km", across / 1000)
            : "\(Int((across / 10).rounded() * 10)) m"
        return "about \(text) (res \(rawValue))"
    }
}

typealias CellID = UInt64

func cellFor(_ coordinate: CLLocationCoordinate2D, size: CellSize) -> CellID? {
    #if H3O
    let cell = h3o_cell_for(coordinate.latitude, coordinate.longitude, UInt8(size.rawValue))
    return cell == 0 ? nil : cell
    #else
    var point = LatLng(lat: degsToRads(coordinate.latitude), lng: degsToRads(coordinate.longitude))
    var cell: H3Index = 0
    guard latLngToCell(&point, Int32(size.rawValue), &cell) == 0 else { return nil }
    return cell
    #endif
}

/// The cell's outline as coordinates, ready for a map polygon.
func outline(of cell: CellID) -> [CLLocationCoordinate2D] {
    #if H3O
    var latitudes = [Double](repeating: 0, count: 10)
    var longitudes = [Double](repeating: 0, count: 10)
    let count = h3o_cell_outline(cell, &latitudes, &longitudes, 10)
    return (0..<count).map { CLLocationCoordinate2D(latitude: latitudes[$0], longitude: longitudes[$0]) }
    #else
    var boundary = CellBoundary()
    guard cellToBoundary(cell, &boundary) == 0 else { return [] }
    let count = Int(boundary.numVerts)
    return withUnsafeBytes(of: &boundary.verts) { raw in
        let vertices = raw.bindMemory(to: LatLng.self)
        return (0..<count).map {
            CLLocationCoordinate2D(latitude: radsToDegs(vertices[$0].lat), longitude: radsToDegs(vertices[$0].lng))
        }
    }
    #endif
}

func cellName(_ cell: CellID) -> String {
    String(cell, radix: 16)
}

struct Sample {
    let coordinate: CLLocationCoordinate2D
    let date: Date
    /// Reported horizontal accuracy in metres, when the source gives one.
    let accuracy: Double?
}

struct CellSummary: Identifiable {
    let id: CellID
    var samples = 0
    var days = Set<DateComponents>()
    var first = Date.distantFuture
    var last = Date.distantPast
}

enum Shading: String, CaseIterable, Identifiable {
    case days = "days with a photo"
    case samples = "photos"
    var id: String { rawValue }
}

struct Binned {
    var cells: [CellID: CellSummary] = [:]
    /// Samples whose reported accuracy is coarser than the cell, so they would
    /// land in a cell more or less at random (the same rule as solstone's map).
    var tooCoarse = 0

    func value(_ cell: CellSummary, _ shading: Shading) -> Int {
        shading == .days ? cell.days.count : cell.samples
    }
}

func bin(_ samples: [Sample], size: CellSize, calendar: Calendar = .current) -> Binned {
    var result = Binned()
    let edge = size.edgeMetres
    for sample in samples {
        if let accuracy = sample.accuracy, accuracy > edge {
            result.tooCoarse += 1
            continue
        }
        guard let cell = cellFor(sample.coordinate, size: size) else { continue }
        var summary = result.cells[cell] ?? CellSummary(id: cell)
        summary.samples += 1
        summary.days.insert(calendar.dateComponents([.year, .month, .day], from: sample.date))
        summary.first = min(summary.first, sample.date)
        summary.last = max(summary.last, sample.date)
        result.cells[cell] = summary
    }
    return result
}
