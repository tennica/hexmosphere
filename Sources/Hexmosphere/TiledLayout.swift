// SPDX-License-Identifier: Apache-2.0
// Lays H3 cells out on a Tiled hexagonal map, north up.
//
// H3's local I/J grid keeps neighbours together, but its axes point a different
// way in each part of the world (and can be mirrored), so taken as is the map
// comes out turned. A hex grid can only be turned in 60° steps without breaking
// it, and Tiled's two hexagon kinds, pointy-top (rows staggered) and flat-top
// (columns staggered), differ by 30°. Together they bring any orientation to
// within 15° of north up. The turn needed is measured from the cells themselves:
// their grid positions against where they are on the map.
//
// Pure arithmetic, no MapKit, so it can be tested on its own.

import Foundation

struct TiledLayout {
    enum Kind: String { case pointy, flat }

    let kind: Kind
    /// Whether the grid was mirrored to match the map.
    let mirrored: Bool
    /// How far the map is still turned from north up, anticlockwise, in degrees.
    let residualDegrees: Double
    let width: Int
    let height: Int
    let staggerIndex: String
    /// Each input cell's tile column, row, and whether its row or column is shifted.
    let tiles: [(column: Int, row: Int, shifted: Bool)]

    // Tile sizes: hexagons about 16 points a side.
    var tileWidth: Int { kind == .pointy ? 28 : 32 }
    var tileHeight: Int { kind == .pointy ? 32 : 28 }
    let hexSide = 16
    var staggerAxis: String { kind == .pointy ? "y" : "x" }

    /// The centre of a tile in Tiled's pixel coordinates.
    func centre(_ tile: (column: Int, row: Int, shifted: Bool)) -> (x: Int, y: Int) {
        switch kind {
        case .pointy:
            return (tile.column * tileWidth + (tile.shifted ? tileWidth / 2 : 0) + tileWidth / 2,
                    tile.row * (tileHeight + hexSide) / 2 + tileHeight / 2)
        case .flat:
            return (tile.column * (tileWidth + hexSide) / 2 + tileWidth / 2,
                    tile.row * tileHeight + (tile.shifted ? tileHeight / 2 : 0) + tileHeight / 2)
        }
    }

    /// `cells` are local I/J coordinates with each cell's position on a north-up
    /// plane (x east, y north; any scale), such as its map point with y negated.
    init(cells: [(i: Int, j: Int, x: Double, y: Double)]) {
        // Axial coordinates on a 60° basis: position = q·(1, 0) + r·(½, √3/2).
        // H3's J axis is 120° from I, so q = i − j and r = j.
        var axial = cells.map { (q: $0.i - $0.j, r: $0.j) }
        let world = cells.map { ($0.x, $0.y) }

        let plain = Self.fit(axial, world)
        let flipped = Self.fit(axial.map(Self.mirror), world)
        mirrored = flipped.strength > plain.strength
        if mirrored { axial = axial.map(Self.mirror) }
        let theta = mirrored ? flipped.degrees : plain.degrees

        // Turning the grid 60° anticlockwise k times leaves theta − 60k to go.
        let pointySteps = Int((theta / 60).rounded())
        let flatSteps = Int(((theta - 30) / 60).rounded())
        let pointyLeft = theta - 60 * Double(pointySteps)
        let flatLeft = theta - 30 - 60 * Double(flatSteps)
        kind = abs(pointyLeft) <= abs(flatLeft) ? .pointy : .flat
        residualDegrees = kind == .pointy ? pointyLeft : flatLeft
        let steps = ((kind == .pointy ? pointySteps : flatSteps) % 6 + 6) % 6
        for _ in 0..<steps { axial = axial.map(Self.rotate60) }

        func half(_ value: Int) -> Int { Int((Double(value) / 2).rounded(.down)) }
        var raw: [(column: Int, row: Int, shifted: Bool)]
        switch kind {
        case .pointy:
            // Rows of constant r, numbered downwards; odd-r rows sit half a hexagon right.
            let rMax = axial.map(\.r).max() ?? 0
            raw = axial.map { (half(2 * $0.q + $0.r), rMax - $0.r, !$0.r.isMultiple(of: 2)) }
            staggerIndex = rMax.isMultiple(of: 2) ? "odd" : "even"
        case .flat:
            // After the turn the grid's first axis points 30° above east: columns of
            // constant q, centres at y = r + q/2 (north), so odd-q columns sit half
            // a hexagon lower.
            raw = axial.map { ($0.q, half(-(2 * $0.r + $0.q)), !$0.q.isMultiple(of: 2)) }
            let qMin = axial.map(\.q).min() ?? 0
            staggerIndex = qMin.isMultiple(of: 2) ? "odd" : "even"
        }
        let columnMin = raw.map(\.column).min() ?? 0, rowMin = raw.map(\.row).min() ?? 0
        if kind == .pointy {
            // Rows were numbered from rMax, so they already start at 0.
            raw = raw.map { ($0.column - columnMin, $0.row, $0.shifted) }
        } else {
            raw = raw.map { ($0.column - columnMin, $0.row - rowMin, $0.shifted) }
        }
        tiles = raw
        width = (raw.map(\.column).max() ?? 0) + 1
        height = (raw.map(\.row).max() ?? 0) + 1
    }

    private static func mirror(_ cell: (q: Int, r: Int)) -> (q: Int, r: Int) { (cell.q + cell.r, -cell.r) }
    private static func rotate60(_ cell: (q: Int, r: Int)) -> (q: Int, r: Int) { (-cell.r, cell.q + cell.r) }

    /// The anticlockwise turn, in degrees, that best carries grid positions onto
    /// the map, and how well it fits (0 to 1).
    private static func fit(_ axial: [(q: Int, r: Int)], _ world: [(Double, Double)]) -> (degrees: Double, strength: Double) {
        let grid = axial.map { (Double($0.q) + Double($0.r) / 2, Double($0.r) * 3.0.squareRoot() / 2) }
        func centred(_ points: [(Double, Double)]) -> [(Double, Double)] {
            let n = Double(points.count)
            let mx = points.map(\.0).reduce(0, +) / n, my = points.map(\.1).reduce(0, +) / n
            return points.map { ($0.0 - mx, $0.1 - my) }
        }
        let g = centred(grid), w = centred(world)
        var dot = 0.0, cross = 0.0, gg = 0.0, ww = 0.0
        for (a, b) in zip(g, w) {
            dot += a.0 * b.0 + a.1 * b.1
            cross += a.0 * b.1 - a.1 * b.0
            gg += a.0 * a.0 + a.1 * a.1
            ww += b.0 * b.0 + b.1 * b.1
        }
        guard gg > 0, ww > 0 else { return (0, 0) }
        return (atan2(cross, dot) * 180 / .pi, (dot * dot + cross * cross).squareRoot() / (gg * ww).squareRoot())
    }
}
