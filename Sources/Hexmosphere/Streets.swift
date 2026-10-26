// SPDX-License-Identifier: Apache-2.0
// OpenStreetMap streets for chosen regions, from Basemap/streets/streets-<name>.tiles
// (scripts/fetch-basemap.sh streets or extract; format in scripts/write-streets.py). Only
// the file's index is read at launch. Each 1° square is read when a tile first needs it
// and kept in a cache of bounded size, so memory stays about the same however many
// regions are bundled. A square comes at up to four levels: the motorways and trunk roads,
// joined and simplified, for the widest views (zoom 5 to 7); an overview of the main roads
// (7 to 10); the main streets from zoom 10; and residential streets from zoom 14.

import Foundation
import MapKit

final class StreetTiles: NSObject, MKOverlay {
    struct Chunk {
        let south: Int
        let west: Int
        let level: Int
        let offset: Int
        let length: Int
        let rect: MKMapRect
    }

    /// Zooms from which each level is drawn; the overview gives way to the main streets.
    static let wideFrom = 5.0
    static let overviewFrom = 7.0
    static let mainFrom = 10.0
    static let residentialFrom = 14.0
    /// Points held in decoded squares before the least recently drawn are let go:
    /// about 100 MB, a few dense city squares.
    static let cachePoints = 4_000_000

    private static let pad = 0.25
    private static let step = (1 + 2 * pad) / 65535

    let chunks: [Chunk]
    let boundingMapRect: MKMapRect
    let streets: Int
    let points: Int
    private let data: Data
    /// The squares with main streets, where Natural Earth's roads give way to these.
    private let mainSquares: Set<Int>
    /// Whether the file has level 3, the motorways and trunk roads for the widest views.
    private let hasWide: Bool

    private let lock = NSLock()
    /// One per square, so tiles that need the same square wait for one read of it.
    private let reading: [NSLock]
    private var cache: [Int: (roads: Roads, used: UInt64)] = [:]
    private var cachedPoints = 0
    private var clock: UInt64 = 0

    init?(_ url: URL) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count >= 20,
              data.prefix(4) == Data("HXST".utf8) else { return nil }
        var chunks: [Chunk] = []
        var streets = 0, points = 0
        let ok = data.withUnsafeBytes { raw -> Bool in
            func read<T: FixedWidthInteger>(_: T.Type, _ at: Int) -> T {
                T(littleEndian: raw.loadUnaligned(fromByteOffset: at, as: T.self))
            }
            func float(_ at: Int) -> Double { Double(Float(bitPattern: read(UInt32.self, at))) }
            guard read(UInt16.self, 4) == 1 else { return false }
            let count = Int(read(UInt32.self, 8))
            streets = Int(read(UInt32.self, 12))
            points = Int(read(UInt32.self, 16))
            let entry = 40
            guard raw.count >= 20 + count * entry else { return false }
            for i in 0..<count {
                let at = 20 + i * entry
                let northWest = MKMapPoint(CLLocationCoordinate2D(latitude: float(at + 36), longitude: float(at + 24)))
                let southEast = MKMapPoint(CLLocationCoordinate2D(latitude: float(at + 28), longitude: float(at + 32)))
                chunks.append(Chunk(
                    south: Int(read(Int16.self, at)), west: Int(read(Int16.self, at + 2)),
                    level: Int(read(UInt8.self, at + 4)),
                    offset: Int(read(UInt64.self, at + 8)), length: Int(read(UInt32.self, at + 16)),
                    rect: MKMapRect(x: northWest.x, y: northWest.y,
                                    width: max(1, southEast.x - northWest.x), height: max(1, southEast.y - northWest.y))))
            }
            return true
        }
        guard ok else { return nil }
        self.data = data
        self.chunks = chunks
        reading = chunks.map { _ in NSLock() }
        self.streets = streets
        self.points = points
        boundingMapRect = chunks.reduce(MKMapRect.null) { $0.union($1.rect) }
        mainSquares = Set(chunks.filter { $0.level == 1 }.map { Self.square($0.south, $0.west) })
        hasWide = chunks.contains { $0.level == 3 }
    }

    var coordinate: CLLocationCoordinate2D { MKMapPoint(x: boundingMapRect.midX, y: boundingMapRect.midY).coordinate }

    private static func square(_ south: Int, _ west: Int) -> Int { (south + 90) * 360 + (west + 180) }

    /// Whether the middle of `rect` has main streets of its own.
    func covers(_ rect: MKMapRect) -> Bool {
        let middle = MKMapPoint(x: rect.midX, y: rect.midY).coordinate
        return mainSquares.contains(Self.square(Int(floor(middle.latitude)), Int(floor(middle.longitude))))
    }

    /// The levels to draw at a zoom. Files written before the wide level existed use the
    /// overview for the widest views too.
    func levels(atZoom zoom: Double) -> [Int] {
        if zoom >= Self.residentialFrom { return [1, 2] }
        if zoom >= Self.mainFrom { return [1] }
        if zoom >= Self.overviewFrom { return [0] }
        if zoom >= Self.wideFrom { return hasWide ? [3] : [0] }
        return []
    }

    /// The decoded square, from the cache or read now. Called from MapKit's drawing threads.
    func roads(_ index: Int) -> Roads {
        if let hit = cached(index) { return hit }
        reading[index].lock()
        defer { reading[index].unlock() }
        if let hit = cached(index) { return hit }   // another tile read it while this one waited

        let roads = decode(chunks[index])
        lock.lock()
        defer { lock.unlock() }
        clock += 1
        cache[index] = (roads, clock)
        cachedPoints += roads.points.count
        while cachedPoints > Self.cachePoints, cache.count > 1,
              let oldest = cache.filter({ $0.key != index }).min(by: { $0.value.used < $1.value.used }) {
            cachedPoints -= oldest.value.roads.points.count
            cache[oldest.key] = nil
        }
        return roads
    }

    private func cached(_ index: Int) -> Roads? {
        lock.lock()
        defer { lock.unlock() }
        guard let hit = cache[index] else { return nil }
        clock += 1
        cache[index] = (hit.roads, clock)
        return hit.roads
    }

    private func decode(_ chunk: Chunk) -> Roads {
        var all: [MKMapPoint] = []
        var pieces: [Road] = []
        all.reserveCapacity(chunk.length / 4)   // 4 bytes a point, less the part headers
        let west = Double(chunk.west) - Self.pad, south = Double(chunk.south) - Self.pad
        data.withUnsafeBytes { raw in
            var at = chunk.offset
            let end = chunk.offset + chunk.length
            func read<T: FixedWidthInteger>(_: T.Type) -> T {
                defer { at += MemoryLayout<T>.size }
                return T(littleEndian: raw.loadUnaligned(fromByteOffset: at, as: T.self))
            }
            while at < end {
                let kind = Road.Kind(rawValue: read(UInt8.self)) ?? .other
                let minZoom = Double(read(UInt8.self)) / 10
                let count = Int(read(UInt16.self))
                let first = all.count
                for _ in 0..<count {
                    let x = Double(read(UInt16.self)), y = Double(read(UInt16.self))
                    all.append(MKMapPoint(CLLocationCoordinate2D(latitude: south + y * Self.step, longitude: west + x * Self.step)))
                }
                Roads.cut(all, from: first, kind: kind, minZoom: minZoom, into: &pieces)
            }
        }
        return Roads(roads: pieces, points: all)
    }
}

final class StreetTilesRenderer: MKOverlayRenderer {
    private let tiles: StreetTiles

    init(_ tiles: StreetTiles) {
        self.tiles = tiles
        super.init(overlay: tiles)
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let started = ContinuousClock.now
        let zoom = RoadsRenderer.zoom(zoomScale)
        let levels = tiles.levels(atZoom: zoom)
        guard !levels.isEmpty else { return }
        let area = RoadsRenderer.area(mapRect, zoomScale)
        let step = RoadsRenderer.step(zoomScale)
        var lines: [Road.Kind: RoadLines] = [:]
        var drawn = 0
        for (index, chunk) in tiles.chunks.enumerated() where levels.contains(chunk.level) && chunk.rect.intersects(area) {
            drawn += tiles.roads(index).addLines(to: &lines, area: area, zoom: zoom, step: step) { point(for: $0) }
        }
        RoadsRenderer.stroke(lines, in: context, zoomScale: zoomScale)
        RoadStats.shared.drew(roads: drawn, took: ContinuousClock.now - started)
    }
}
