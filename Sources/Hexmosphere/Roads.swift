// SPDX-License-Identifier: Apache-2.0
// Roads: Natural Earth's 1:10m roads from Basemap/roads/roads.bin (scripts/fetch-basemap.sh
// roads), loaded whole. OpenStreetMap streets come in chunks instead (Streets.swift) but are
// drawn the same way. Each road carries the zoom level to show it from, and a tile draws
// only the roads worth seeing at its zoom. Where detailed streets exist, the coarse Natural
// Earth roads give way to them once zoomed in. Load and draw times are kept in RoadStats for
// the summary line.

import Foundation
import MapKit
import Observation

/// A short piece of one road. Roads are cut into pieces of at most 16 points,
/// so a tile draws only the pieces it touches, not whole highways. The points
/// live in their overlay's one shared array; a piece is a range of it.
struct Road {
    enum Kind: UInt8 { case major = 0, secondary, other, ferry }
    let kind: Kind
    /// Web map zoom level (0 = whole world in one 256-point tile) to draw it from.
    let minZoom: Double
    let rect: MKMapRect
    let points: Range<Int>

    static let pieceLength = 16
}

/// The roads in one region of the world, so a tile only looks at nearby roads.
final class Roads: NSObject, MKOverlay {
    let roads: [Road]
    /// Every piece's points, back to back.
    let points: [MKMapPoint]
    let boundingMapRect: MKMapRect
    /// Regions with detailed streets, where these roads aren't drawn from
    /// `hiddenFromZoom` in (set on Natural Earth's roads only).
    var hiddenBy: [StreetTiles] = []
    static let hiddenFromZoom = 10.0

    init(roads: [Road], points: [MKMapPoint]) {
        self.roads = roads
        self.points = points
        boundingMapRect = roads.reduce(MKMapRect.null) { $0.union($1.rect) }
    }

    /// Copies the given pieces' points out of `source` into this overlay's own array.
    convenience init(_ pieces: [Road], from source: [MKMapPoint]) {
        var points: [MKMapPoint] = []
        points.reserveCapacity(pieces.reduce(0) { $0 + $1.points.count })
        let roads = pieces.map { piece in
            let start = points.count
            points.append(contentsOf: source[piece.points])
            return Road(kind: piece.kind, minZoom: piece.minZoom, rect: piece.rect, points: start..<points.count)
        }
        self.init(roads: roads, points: points)
    }

    /// Cuts the line `all[first...]` into pieces of at most `Road.pieceLength` points.
    /// Neighbouring pieces share an end point, so the line stays joined.
    static func cut(_ all: [MKMapPoint], from first: Int, kind: Road.Kind, minZoom: Double, into pieces: inout [Road]) {
        var start = first
        while start < all.count - 1 {
            let end = min(start + Road.pieceLength, all.count)
            var low = all[start], high = all[start]
            for point in all[start + 1..<end] {
                low = MKMapPoint(x: min(low.x, point.x), y: min(low.y, point.y))
                high = MKMapPoint(x: max(high.x, point.x), y: max(high.y, point.y))
            }
            // At least one map point across, so straight north–south or east–west
            // pieces still count as touching a tile.
            let rect = MKMapRect(x: low.x, y: low.y, width: max(1, high.x - low.x), height: max(1, high.y - low.y))
            pieces.append(Road(kind: kind, minZoom: minZoom, rect: rect, points: start..<end))
            start = end - 1
        }
    }

    /// Adds the pieces worth drawing at this zoom within `area` to `lines`, by kind, and
    /// returns how many were added. Points closer than `step` map points to the last one
    /// kept are skipped: zoomed out, most of a street's points fall within one pixel.
    func addLines(to lines: inout [Road.Kind: RoadLines], area: MKMapRect, zoom: Double, step: Double,
                  point: (MKMapPoint) -> CGPoint) -> Int {
        var drawn = 0
        for road in roads where road.minZoom <= zoom && road.rect.intersects(area) {
            // Appended in place: a copy of the kind's lines per piece would make this quadratic.
            var last = points[road.points.lowerBound]
            lines[road.kind, default: RoadLines()].points.append(point(last))
            for index in road.points.dropFirst() {
                let next = points[index]
                guard index == road.points.upperBound - 1
                        || abs(next.x - last.x) >= step || abs(next.y - last.y) >= step else { continue }
                lines[road.kind, default: RoadLines()].points.append(point(next))
                last = next
            }
            lines[road.kind, default: RoadLines()].ends.append(lines[road.kind]!.points.count)
            drawn += 1
        }
        return drawn
    }

    var coordinate: CLLocationCoordinate2D { MKMapPoint(x: boundingMapRect.midX, y: boundingMapRect.midY).coordinate }

    /// Reads a roads file (format in scripts/fetch-basemap.sh) and groups the
    /// pieces on a grid over the world, `side` squares each way.
    static func load(_ url: URL, side: Int) -> [Roads] {
        let clock = ContinuousClock()
        var pieces: [Road] = []
        var all: [MKMapPoint] = []
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
                        let first = all.count
                        for _ in 0..<pointCount {
                            let longitude = readFloat(), latitude = readFloat()
                            all.append(MKMapPoint(CLLocationCoordinate2D(latitude: latitude, longitude: longitude)))
                        }
                        points += pointCount
                        cut(all, from: first, kind: kind, minZoom: minZoom, into: &pieces)
                    }
                    roadCount += 1
                }
            }
        }
        RoadStats.shared.loaded(roads: roadCount, points: points, took: took)

        let world = MKMapRect.world
        var groups: [Int: [Road]] = [:]
        for road in pieces {
            let column = min(side - 1, max(0, Int((road.rect.midX - world.minX) / world.width * Double(side))))
            let row = min(side - 1, max(0, Int((road.rect.midY - world.minY) / world.height * Double(side))))
            groups[row * side + column, default: []].append(road)
        }
        return groups.values.map { Roads($0, from: all) }
    }
}

/// Pieces of road to draw, as screen points back to back with where each piece ends.
struct RoadLines {
    var points: [CGPoint] = []
    var ends: [Int] = []
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
        let zoom = Self.zoom(zoomScale)
        if zoom >= Roads.hiddenFromZoom, roads.hiddenBy.contains(where: { $0.covers(mapRect) }) { return }
        var lines: [Road.Kind: RoadLines] = [:]
        let drawn = roads.addLines(to: &lines, area: Self.area(mapRect, zoomScale), zoom: zoom,
                                   step: Self.step(zoomScale)) { point(for: $0) }
        Self.stroke(lines, in: context, zoomScale: zoomScale)
        RoadStats.shared.drew(roads: drawn, took: ContinuousClock.now - started)
    }

    /// Web map zoom level for MapKit's zoom scale.
    static func zoom(_ zoomScale: MKZoomScale) -> Double {
        log2(Double(zoomScale) * MKMapRect.world.width / 256)
    }

    /// Half a screen point, in map points: the closest two drawn points need be.
    static func step(_ zoomScale: MKZoomScale) -> Double { 0.5 / Double(zoomScale) }

    /// The tile, widened a little so lines along its edge aren't cut off.
    static func area(_ mapRect: MKMapRect, _ zoomScale: MKZoomScale) -> MKMapRect {
        mapRect.insetBy(dx: -4 / Double(zoomScale), dy: -4 / Double(zoomScale))
    }

    /// Strokes each piece on its own. CoreGraphics takes far longer over one path of many
    /// pieces than over the same pieces one at a time: a zoomed-out tile of California's
    /// main roads took about 7 s as one path and under 0.1 s piece by piece.
    static func stroke(_ lines: [Road.Kind: RoadLines], in context: CGContext, zoomScale: MKZoomScale) {
        context.setLineJoin(.round)
        context.setLineCap(.round)
        // Lesser roads first, so highways draw over them.
        for kind in [Road.Kind.other, .ferry, .secondary, .major] {
            guard let kept = lines[kind], let (color, width) = Self.styles[kind] else { continue }
            context.setStrokeColor(color)
            context.setLineWidth(width / zoomScale)
            context.setLineDash(phase: 0, lengths: kind == .ferry ? [3 / zoomScale, 3 / zoomScale] : [])
            var start = 0
            for end in kept.ends {
                context.move(to: kept.points[start])
                for index in start + 1..<end {
                    context.addLine(to: kept.points[index])
                }
                context.strokePath()
                start = end
            }
        }
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

    /// Called once per roads or streets file; the totals add up.
    func loaded(roads: Int, points: Int, took: Duration) {
        DispatchQueue.main.async {
            self.roads += roads
            self.points += points
            self.loadTime = (self.loadTime ?? .zero) + took
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
