// SPDX-License-Identifier: Apache-2.0
// Natural Earth's 1:10m roads, all of them, from Basemap/roads/roads.bin
// (scripts/fetch-basemap.sh roads). Each road carries the zoom level Natural
// Earth suggests showing it from, and a tile draws only the roads worth seeing
// at its zoom. Load and draw times are kept in RoadStats for the summary line.

import Foundation
import MapKit
import Observation

/// A short piece of one road. Roads are cut into pieces of at most 16 points,
/// so a tile draws only the pieces it touches, not whole highways.
struct Road {
    enum Kind: UInt8 { case major = 0, secondary, other, ferry }
    let kind: Kind
    /// Web map zoom level (0 = whole world in one 256-point tile) to draw it from.
    let minZoom: Double
    let rect: MKMapRect
    let points: [MKMapPoint]

    static let pieceLength = 16
}

/// The roads in one region of the world, so a tile only looks at nearby roads.
final class Roads: NSObject, MKOverlay {
    let roads: [Road]
    let boundingMapRect: MKMapRect

    init(_ roads: [Road]) {
        self.roads = roads
        boundingMapRect = roads.reduce(MKMapRect.null) { $0.union($1.rect) }
    }

    var coordinate: CLLocationCoordinate2D { MKMapPoint(x: boundingMapRect.midX, y: boundingMapRect.midY).coordinate }

    /// Reads roads.bin (format in scripts/fetch-basemap.sh) and groups the roads
    /// on a 16×16 grid over the world.
    static func load(_ url: URL) -> [Roads] {
        let clock = ContinuousClock()
        var pieces: [Road] = []
        var roadCount = 0
        var points = 0
        let took = clock.measure {
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
            data.withUnsafeBytes { raw in
                var at = 0
                func read<T: FixedWidthInteger>(_: T.Type) -> T {
                    defer { at += MemoryLayout<T>.size }
                    return T(littleEndian: raw.loadUnaligned(fromByteOffset: at, as: T.self))
                }
                func readFloat() -> Double {
                    Double(Float(bitPattern: read(UInt32.self)))
                }
                guard raw.count >= 4 else { return }
                let count = Int(read(UInt32.self))
                for _ in 0..<count {
                    let kind = Road.Kind(rawValue: read(UInt8.self)) ?? .other
                    let minZoom = Double(read(UInt8.self)) / 10
                    let partCount = Int(read(UInt16.self))
                    for _ in 0..<partCount {
                        let pointCount = Int(read(UInt32.self))
                        var part: [MKMapPoint] = []
                        part.reserveCapacity(pointCount)
                        for _ in 0..<pointCount {
                            let longitude = readFloat(), latitude = readFloat()
                            part.append(MKMapPoint(CLLocationCoordinate2D(latitude: latitude, longitude: longitude)))
                        }
                        points += pointCount
                        // Neighbouring pieces share an end point, so the line stays joined.
                        var start = 0
                        while start < pointCount - 1 {
                            let end = min(start + Road.pieceLength, pointCount)
                            let piece = Array(part[start..<end])
                            let xs = piece.map(\.x), ys = piece.map(\.y)
                            // At least one map point across, so straight north–south or east–west
                            // pieces still count as touching a tile.
                            let rect = MKMapRect(x: xs.min()!, y: ys.min()!,
                                                 width: max(1, xs.max()! - xs.min()!), height: max(1, ys.max()! - ys.min()!))
                            pieces.append(Road(kind: kind, minZoom: minZoom, rect: rect, points: piece))
                            start = end - 1
                        }
                    }
                    roadCount += 1
                }
            }
        }
        RoadStats.shared.loaded(roads: roadCount, points: points, took: took)

        let side = 16.0
        let world = MKMapRect.world
        var groups: [Int: [Road]] = [:]
        for road in pieces {
            let column = min(Int(side) - 1, max(0, Int((road.rect.midX - world.minX) / world.width * side)))
            let row = min(Int(side) - 1, max(0, Int((road.rect.midY - world.minY) / world.height * side)))
            groups[row * Int(side) + column, default: []].append(road)
        }
        return groups.values.map(Roads.init)
    }
}

final class RoadsRenderer: MKOverlayRenderer {
    private let roads: Roads

    init(_ roads: Roads) {
        self.roads = roads
        super.init(overlay: roads)
    }

    /// Colour (grey level or ferry blue) and width in screen points, by kind.
    private static let styles: [Road.Kind: (CGColor, CGFloat)] = [
        .major: (CGColor(red: 0.52, green: 0.50, blue: 0.48, alpha: 1), 1.2),
        .secondary: (CGColor(red: 0.64, green: 0.62, blue: 0.60, alpha: 1), 0.8),
        .other: (CGColor(red: 0.74, green: 0.72, blue: 0.70, alpha: 1), 0.6),
        .ferry: (CGColor(red: 0.55, green: 0.68, blue: 0.82, alpha: 1), 0.6),
    ]

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let started = ContinuousClock.now
        let zoom = log2(Double(zoomScale) * MKMapRect.world.width / 256)
        // Widen the tile a little so lines along its edge aren't cut off.
        let area = mapRect.insetBy(dx: -4 / Double(zoomScale), dy: -4 / Double(zoomScale))
        var paths: [Road.Kind: CGMutablePath] = [:]
        var drawn = 0
        for road in roads.roads where road.minZoom <= zoom && road.rect.intersects(area) {
            let path = paths[road.kind] ?? CGMutablePath()
            path.addLines(between: road.points.map { point(for: $0) })
            paths[road.kind] = path
            drawn += 1
        }
        context.setLineJoin(.round)
        context.setLineCap(.round)
        // Lesser roads first, so highways draw over them.
        for kind in [Road.Kind.other, .ferry, .secondary, .major] {
            guard let path = paths[kind], let (color, width) = Self.styles[kind] else { continue }
            context.addPath(path)
            context.setStrokeColor(color)
            context.setLineWidth(width / zoomScale)
            context.setLineDash(phase: 0, lengths: kind == .ferry ? [3 / zoomScale, 3 / zoomScale] : [])
            context.strokePath()
        }
        RoadStats.shared.drew(roads: drawn, took: ContinuousClock.now - started)
    }
}

/// How long the roads took to load and draw, shown in the summary line so the
/// cost of drawing every road can be judged on each device.
@Observable final class RoadStats {
    static let shared = RoadStats()

    private(set) var roads = 0
    private(set) var points = 0
    private(set) var loadTime: Duration?
    private(set) var tiles = 0
    private(set) var slowestTile: Duration = .zero
    /// The most road pieces any one tile drew.
    private(set) var busiestTile = 0

    private let lock = NSLock()
    private var pendingTiles = 0
    private var pendingSlowest: Duration = .zero
    private var pendingBusiest = 0
    private var publishScheduled = false

    func loaded(roads: Int, points: Int, took: Duration) {
        DispatchQueue.main.async {
            self.roads = roads
            self.points = points
            self.loadTime = took
        }
    }

    /// Called from MapKit's drawing threads; publishes on the main thread at most
    /// a few times a second.
    func drew(roads: Int, took: Duration) {
        lock.lock()
        pendingTiles += 1
        pendingSlowest = max(pendingSlowest, took)
        pendingBusiest = max(pendingBusiest, roads)
        let schedule = !publishScheduled
        publishScheduled = true
        lock.unlock()
        guard schedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.lock.lock()
            let (tiles, slowest, busiest) = (self.pendingTiles, self.pendingSlowest, self.pendingBusiest)
            self.publishScheduled = false
            self.lock.unlock()
            self.tiles = tiles
            self.slowestTile = slowest
            self.busiestTile = busiest
        }
    }
}
