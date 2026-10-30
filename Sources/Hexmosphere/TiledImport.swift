// SPDX-License-Identifier: Apache-2.0
// Opens a Tiled hexagonal map (a folder holding a .tmj and its tile images) as a layer
// on the globe: the reverse of TiledExport.
//
// The map's properties say where it goes: origin_cell, an H3 cell, or else
// centre_latitude, centre_longitude and h3_resolution, as an export writes them.
// origin_column and origin_row name the tile the origin sits on; without them, an
// exported map's own h3 objects find it, and a hand-drawn map is centred on it. The
// cells around the origin are laid out as the export lays them out, north up with the
// map's hexagon kind, and each tile takes the cell that lands on it.
//
// Tiles are drawn in their image's main colour. Point objects with a name become
// places, labelled on the map, with their description property shown when tapped.
//
// The folder can also hold hex corridors, GeoJSON joining places too far apart for one
// flat map, such as two maps on different continents. A feature with an "h3" cell index
// is that cell, as tools/hexchain.c writes them; a line is a route, each segment along
// the great circle, drawn as the chain of cells it crosses at the app's cell size, so it
// grows and shrinks with the size picker. Either takes an optional "fill" (#rrggbb). A feature
// with "landmark": true, an "h3" cell and a "name" (and "description") is a landmark there
// instead, labelled like a map's.
// Nothing is saved: the layer is gone when the app closes.

import CH3
import CoreGraphics
import Foundation
import ImageIO
import MapKit

enum TiledImportError: LocalizedError {
    case noMap
    case notHexagonal
    case noOrigin
    case unreadable(String)
    case nothingPlaced

    var errorDescription: String? {
        switch self {
        case .noMap: "That folder has no Tiled map (.tmj) or hex corridor (.geojson) in it."
        case .notHexagonal: "Only hexagonal Tiled maps can go on the globe."
        case .noOrigin:
            "The map doesn't say where it goes. Give it an origin_cell property, or centre_latitude, centre_longitude and h3_resolution."
        case .unreadable(let why): "The Tiled map couldn't be read: \(why)."
        case .nothingPlaced: "None of the map's tiles could be placed on H3 cells around its origin."
        }
    }
}

struct TiledOverlayMap: Identifiable {
    struct Landmark {
        let name: String
        let description: String
        let cell: CellID
    }

    let id = UUID()
    /// The same for every `showing` of one opened folder, so hiding a resolution doesn't move the map.
    let opening: UUID
    let name: String
    /// The H3 resolutions of the maps and corridors, finest last.
    let resolutions: [Int]
    /// The tiles as cell outlines, one overlay per colour and region.
    let areas: [StyledAreas]
    /// The places' names, drawn like the base map's place names.
    let labels: Places
    /// Routes drawn as cells at the app's cell size (routeAreas).
    let routes: [Route]
    let landmarks: [CellID: Landmark]
    let cells: Int
    /// Painted tiles H3 couldn't place around their origin (too far, or across a pentagon).
    let leftOut: Int
    /// Objects whose h3 property names a different cell from the one their tile landed on
    /// (an export, or an authored planet that carries its cells): 0 when the layout round-trips.
    let mismatched: Int
    /// Whether every map in it says it's authored, not real (map property fictional = true).
    let fictional: Bool
    let bounds: MKMapRect
    /// The maps and corridors it was read from, so `showing` can leave some out without reading them again.
    private let pieces: [Piece]

    struct Route {
        let points: [CLLocationCoordinate2D]
        let fill: Int
    }

    /// What one map or corridor adds.
    private struct Piece {
        var resolution = 0
        var polygons: [Int: [MKPolygon]] = [:]
        var landmarks: [CellID: Landmark] = [:]
        var names: [Place] = []
        var routes: [Route] = []
        var placed = 0
        var missed = 0
        var mismatched = 0
        var fictional = false
    }

    /// The landmark in the hexagon at `coordinate`, if any.
    func landmark(at coordinate: CLLocationCoordinate2D) -> Landmark? {
        var point = LatLng(lat: degsToRads(coordinate.latitude), lng: degsToRads(coordinate.longitude))
        for resolution in resolutions.reversed() {
            var cell: H3Index = 0
            guard latLngToCell(&point, Int32(resolution), &cell) == 0 else { continue }
            if let landmark = landmarks[cell] { return landmark }
        }
        return nil
    }

    /// Reads every .tmj and .geojson in `folder`. Call off the main thread: it lays out
    /// thousands of cells.
    init(folder: URL, backend: H3Backend) throws {
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }
        let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .sorted { $0.path < $1.path }
        let maps = files.filter { $0.pathExtension == "tmj" }, corridors = files.filter { $0.pathExtension == "geojson" }
        guard !maps.isEmpty || !corridors.isEmpty else { throw TiledImportError.noMap }
        // Corridors first, so the maps they join draw over them.
        let pieces = try corridors.compactMap(Self.corridor) + maps.map { try Self.map($0, folder: folder, backend: backend) }
        guard !pieces.isEmpty else { throw TiledImportError.nothingPlaced }
        self.init(pieces: pieces, name: folder.lastPathComponent, opening: UUID())
    }

    private init(pieces: [Piece], name: String, opening: UUID) {
        self.pieces = pieces
        self.opening = opening
        areas = pieces.flatMap { $0.polygons.flatMap(Self.styled) }
        routes = pieces.flatMap(\.routes)
        cells = pieces.map(\.placed).reduce(0, +)
        leftOut = pieces.map(\.missed).reduce(0, +)
        mismatched = pieces.map(\.mismatched).reduce(0, +)
        let drawn = pieces.filter { $0.placed > 0 }
        fictional = !drawn.isEmpty && drawn.allSatisfy { $0.fictional }
        let routeBounds = routes.flatMap(\.points).map { MKMapRect(origin: MKMapPoint($0), size: MKMapSize(width: 0, height: 0)) }
        bounds = (areas.map(\.boundingMapRect) + routeBounds).reduce(MKMapRect.null) { $0.union($1) }
        landmarks = pieces.reduce(into: [:]) { all, piece in all.merge(piece.landmarks) { first, _ in first } }
        labels = Places(pieces.flatMap(\.names))
        // A file holding only routes has no resolution of its own: they take the size picker's.
        resolutions = Set(pieces.filter { $0.placed > 0 }.map(\.resolution)).sorted()
        self.name = name
    }

    /// The map with only the maps and corridors at the `shown` resolutions. Files of routes
    /// alone have no resolution and always stay.
    func showing(_ shown: Set<Int>) -> TiledOverlayMap {
        TiledOverlayMap(pieces: pieces.filter { $0.placed == 0 || shown.contains($0.resolution) }, name: name, opening: opening)
    }

    /// How many maps and corridors draw cells at `resolution`.
    func count(at resolution: Int) -> Int {
        pieces.filter { $0.placed > 0 && $0.resolution == resolution }.count
    }

    /// The routes as the chains of cells they cross at `resolution`, one overlay per colour and region.
    func routeAreas(resolution: Int) -> [StyledAreas] {
        var edge = 0.0
        _ = getHexagonEdgeLengthAvgKm(Int32(resolution), &edge)
        var byColour: [Int: [MKPolygon]] = [:]
        for route in routes {
            var seen = Set<CellID>()
            for (a, b) in zip(route.points, route.points.dropFirst()) {
                // Points a quarter of a cell edge apart along the great circle, so no cell is skipped.
                let u = Self.vector(a), v = Self.vector(b)
                let angle = acos(max(-1, min(1, u.0 * v.0 + u.1 * v.1 + u.2 * v.2)))
                let steps = max(1, Int((angle * 6371.0088 / (edge / 4)).rounded(.up)))
                for n in 0...steps {
                    let t = Double(n) / Double(steps)
                    let wa = angle > 0 ? sin((1 - t) * angle) / sin(angle) : 1 - t
                    let wb = angle > 0 ? sin(t * angle) / sin(angle) : t
                    let x = wa * u.0 + wb * v.0, y = wa * u.1 + wb * v.1, z = wa * u.2 + wb * v.2
                    var point = LatLng(lat: atan2(z, (x * x + y * y).squareRoot()), lng: atan2(y, x))
                    var cell: H3Index = 0
                    guard latLngToCell(&point, Int32(resolution), &cell) == 0, seen.insert(cell).inserted,
                          let polygon = cellPolygon(cell) else { continue }
                    byColour[route.fill, default: []].append(polygon)
                }
            }
        }
        return byColour.flatMap(Self.styled)
    }

    private static func vector(_ c: CLLocationCoordinate2D) -> (Double, Double, Double) {
        let lat = degsToRads(c.latitude), lng = degsToRads(c.longitude)
        return (cos(lat) * cos(lng), cos(lat) * sin(lng), sin(lat))
    }

    /// Cell outlines in one colour (0xRRGGBB), edged a shade darker, grouped by region.
    private static func styled(_ rgb: Int, _ polygons: [MKPolygon]) -> [StyledAreas] {
        let fill = (CGFloat(rgb >> 16 & 0xFF) / 255, CGFloat(rgb >> 8 & 0xFF) / 255, CGFloat(rgb & 0xFF) / 255)
        return groupedByRegion(polygons).map { group in
            let overlay = StyledAreas(group)
            overlay.style = LayerStyle(kind: .fill, stroke: (fill.0 * 0.75, fill.1 * 0.75, fill.2 * 0.75),
                                       fill: fill, width: 0.5, dash: nil)
            return overlay
        }
    }

    /// One hex corridor: its features' "h3" cells and its routes, in their "fill" colours (#rrggbb).
    private static func corridor(_ file: URL) -> Piece? {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = json["features"] as? [[String: Any]] else { return nil }
        var piece = Piece()
        for feature in features {
            let properties = feature["properties"] as? [String: Any] ?? [:]
            let fill = (properties["fill"] as? String).flatMap { Int($0.dropFirst(), radix: 16) } ?? 0xC8553D
            if properties["h3"] == nil, let geometry = feature["geometry"] as? [String: Any] {
                let lines: [[[Double]]]
                switch geometry["type"] as? String {
                case "LineString": lines = [geometry["coordinates"] as? [[Double]] ?? []]
                case "MultiLineString": lines = geometry["coordinates"] as? [[[Double]]] ?? []
                default: lines = []
                }
                for line in lines where line.count >= 2 {
                    piece.routes.append(Route(points: line.filter { $0.count >= 2 }
                        .map { CLLocationCoordinate2D(latitude: $0[1], longitude: $0[0]) }, fill: fill))
                }
                continue
            }
            if properties["landmark"] as? Bool == true, let title = properties["name"] as? String, !title.isEmpty,
               let named = properties["h3"] as? String, let cell = CellID(named, radix: 16), isValidCell(cell) != 0 {
                piece.landmarks[cell] = Landmark(name: title, description: properties["description"] as? String ?? "", cell: cell)
                var centre = LatLng()
                if cellToLatLng(cell, &centre) == 0 {
                    let point = MKMapPoint(CLLocationCoordinate2D(latitude: radsToDegs(centre.lat), longitude: radsToDegs(centre.lng)))
                    piece.names.append(Place(point: point, name: title, tier: 0))
                }
                continue
            }
            guard let name = properties["h3"] as? String, let cell = CellID(name, radix: 16), isValidCell(cell) != 0,
                  let polygon = cellPolygon(cell) else { continue }
            piece.polygons[fill, default: []].append(polygon)
            piece.resolution = Int(getResolution(cell))
            piece.placed += 1
        }
        return piece.placed > 0 || !piece.routes.isEmpty || !piece.landmarks.isEmpty ? piece : nil
    }

    /// One Tiled map, placed where its properties say.
    private static func map(_ file: URL, folder: URL, backend: H3Backend) throws -> Piece {
        let json: [String: Any]
        do {
            json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] ?? [:]
        } catch {
            throw TiledImportError.unreadable(error.localizedDescription)
        }
        guard json["orientation"] as? String == "hexagonal",
              let width = json["width"] as? Int, let height = json["height"] as? Int,
              let tileWidth = json["tilewidth"] as? Int, let tileHeight = json["tileheight"] as? Int else {
            throw TiledImportError.notHexagonal
        }
        let kind: TiledLayout.Kind = json["staggeraxis"] as? String == "x" ? .flat : .pointy
        let staggerOdd = json["staggerindex"] as? String != "even"
        let side = json["hexsidelength"] as? Int ?? 0
        let properties = Self.properties(json["properties"])

        // Where it goes.
        let origin: CellID
        if let name = properties["origin_cell"] as? String, let cell = CellID(name, radix: 16), isValidCell(cell) != 0 {
            origin = cell
        } else if let latitude = Self.number(properties["centre_latitude"]),
                  let longitude = Self.number(properties["centre_longitude"]),
                  let res = properties["h3_resolution"] as? Int {
            var point = LatLng(lat: degsToRads(latitude), lng: degsToRads(longitude))
            var cell: H3Index = 0
            guard latLngToCell(&point, Int32(res), &cell) == 0 else { throw TiledImportError.noOrigin }
            origin = cell
        } else {
            throw TiledImportError.noOrigin
        }
        let resolution = Int(getResolution(origin))

        let layers = json["layers"] as? [[String: Any]] ?? []
        let objects = layers.filter { $0["type"] as? String == "objectgroup" && $0["visible"] as? Bool != false }
            .flatMap { $0["objects"] as? [[String: Any]] ?? [] }

        // Which tile a point in Tiled's pixels falls on, and whether its row (or column) is shifted.
        func shifted(_ index: Int) -> Bool { index.isMultiple(of: 2) != staggerOdd }
        func tile(x: Double, y: Double) -> (column: Int, row: Int) {
            switch kind {
            case .pointy:
                let row = Int(((y - Double(tileHeight) / 2) / (Double(tileHeight + side) / 2)).rounded())
                let column = Int(((x - Double(tileWidth) / 2 - (shifted(row) ? Double(tileWidth) / 2 : 0)) / Double(tileWidth)).rounded())
                return (column, row)
            case .flat:
                let column = Int(((x - Double(tileWidth) / 2) / (Double(tileWidth + side) / 2)).rounded())
                let row = Int(((y - Double(tileHeight) / 2 - (shifted(column) ? Double(tileHeight) / 2 : 0)) / Double(tileHeight)).rounded())
                return (column, row)
            }
        }

        // The origin's tile: given, or the export's own h3 object for it, or the middle.
        var originTile: (column: Int, row: Int)
        if let column = properties["origin_column"] as? Int, let row = properties["origin_row"] as? Int {
            originTile = (column, row)
        } else if let object = objects.first(where: { Self.properties($0["properties"])["h3"] as? String == cellName(origin) }),
                  let x = Self.number(object["x"]), let y = Self.number(object["y"]) {
            originTile = tile(x: x, y: y)
        } else {
            originTile = (width / 2, height / 2)
        }

        // Lay out every cell near enough to cover the map, as the export would, and no more:
        // rings only as far as the map's farthest corner from the origin (|columns| + |rows|
        // bounds the steps), since past a pentagon H3's local grid hands back distorted
        // positions that would claim tiles and skew the north-up fit (the HeusDenVerSe's island
        // at resolution 3 reached past the North Pacific pentagon).
        let corners = [(0, 0), (width - 1, 0), (0, height - 1), (width - 1, height - 1)]
        let k = corners.map { abs($0.0 - originTile.column) + abs($0.1 - originTile.row) }.max()! + 2
        var size: Int64 = 0
        guard maxGridDiskSize(Int32(k), &size) == 0 else { throw TiledImportError.nothingPlaced }
        var disk = [H3Index](repeating: 0, count: Int(size))
        var rings = [Int32](repeating: 0, count: Int(size))
        guard gridDiskDistances(origin, Int32(k), &disk, &rings) == 0 else { throw TiledImportError.nothingPlaced }
        var near: [(cell: CellID, i: Int, j: Int, x: Double, y: Double)] = []
        var ring: [CellID: Int32] = [:]
        for (cell, distance) in zip(disk, rings) where cell != 0 {
            ring[cell] = distance
            guard let ij = localIJ(of: cell, origin: origin, backend: backend) else { continue }
            var centre = LatLng()
            guard cellToLatLng(cell, &centre) == 0 else { continue }
            let point = MKMapPoint(CLLocationCoordinate2D(latitude: radsToDegs(centre.lat), longitude: radsToDegs(centre.lng)))
            // Map points grow southwards; the layout wants north up.
            near.append((cell, ij.i, ij.j, point.x, -point.y))
        }
        let layout = TiledLayout(cells: near.map { ($0.i, $0.j, $0.x, $0.y) }, kind: kind)
        guard let at = near.firstIndex(where: { $0.cell == origin }) else { throw TiledImportError.nothingPlaced }
        let laidOrigin = layout.tiles[at]
        // A staggered grid can only be moved by whole rows (or columns) of the same stagger;
        // if the origin's tile has the other one, use its neighbour.
        if kind == .pointy, shifted(originTile.row) != laidOrigin.shifted {
            originTile.row += originTile.row + 1 < height ? 1 : -1
        } else if kind == .flat, shifted(originTile.column) != laidOrigin.shifted {
            originTile.column += originTile.column + 1 < width ? 1 : -1
        }
        var cellAt: [Int: CellID] = [:]
        for (entry, laid) in zip(near, layout.tiles) {
            let column = laid.column - laidOrigin.column + originTile.column
            let row = laid.row - laidOrigin.row + originTile.row
            guard (0..<width).contains(column), (0..<height).contains(row) else { continue }
            // Two cells on one tile: the nearer to the origin is the real one.
            if let held = cellAt[row * width + column], ring[held, default: 0] <= ring[entry.cell, default: 0] { continue }
            cellAt[row * width + column] = entry.cell
        }

        // The painted tiles, later layers over earlier ones.
        var gids = [Int](repeating: 0, count: width * height)
        for layer in layers where layer["type"] as? String == "tilelayer" && layer["visible"] as? Bool != false {
            guard layer["encoding"] == nil, let data = layer["data"] as? [Int], data.count == gids.count else { continue }
            for (index, gid) in data.enumerated() where gid != 0 {
                gids[index] = gid & 0x1FFF_FFFF  // without Tiled's flip flags
            }
        }
        let colours = Self.tileColours(json["tilesets"], folder: folder)
        var piece = Piece(resolution: resolution)
        piece.fictional = properties["fictional"] as? Bool ?? false
        for (index, gid) in gids.enumerated() where gid != 0 {
            guard let cell = cellAt[index], let polygon = cellPolygon(cell) else {
                piece.missed += 1
                continue
            }
            piece.polygons[colours[gid] ?? 0x9A9A9A, default: []].append(polygon)
            piece.placed += 1
        }
        guard piece.placed > 0 else { throw TiledImportError.nothingPlaced }

        // Named points are places; text objects are only labels for Tiled's own view.
        for object in objects where object["text"] == nil {
            if let named = Self.properties(object["properties"])["h3"] as? String,
               let x = Self.number(object["x"]), let y = Self.number(object["y"]) {
                let at = tile(x: x, y: y)
                let laid = (0..<width).contains(at.column) && (0..<height).contains(at.row)
                    ? cellAt[at.row * width + at.column] : nil
                if laid.map(cellName) != named { piece.mismatched += 1 }
            }
            guard let name = object["name"] as? String, !name.isEmpty,
                  let x = Self.number(object["x"]), let y = Self.number(object["y"]) else { continue }
            let at = tile(x: x, y: y)
            guard (0..<width).contains(at.column), (0..<height).contains(at.row),
                  let cell = cellAt[at.row * width + at.column] else { continue }
            let description = Self.properties(object["properties"])["description"] as? String ?? ""
            piece.landmarks[cell] = Landmark(name: name, description: description, cell: cell)
            var centre = LatLng()
            guard cellToLatLng(cell, &centre) == 0 else { continue }
            let point = MKMapPoint(CLLocationCoordinate2D(latitude: radsToDegs(centre.lat), longitude: radsToDegs(centre.lng)))
            piece.names.append(Place(point: point, name: name, tier: 0))
        }
        return piece
    }

    /// Tiled's property list as a dictionary.
    private static func properties(_ list: Any?) -> [String: Any] {
        var out: [String: Any] = [:]
        for item in list as? [[String: Any]] ?? [] {
            if let name = item["name"] as? String, let value = item["value"] { out[name] = value }
        }
        return out
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    /// Each tile's main colour (as 0xRRGGBB, by gid): the commonest opaque colour in its
    /// part of the tileset image, so outlines and small marks don't tint it.
    private static func tileColours(_ tilesets: Any?, folder: URL) -> [Int: Int] {
        var colours: [Int: Int] = [:]
        for tileset in tilesets as? [[String: Any]] ?? [] {
            guard let first = tileset["firstgid"] as? Int, let path = tileset["image"] as? String,
                  let width = tileset["tilewidth"] as? Int, let height = tileset["tileheight"] as? Int,
                  let count = tileset["tilecount"] as? Int, let columns = tileset["columns"] as? Int, columns > 0,
                  let source = CGImageSourceCreateWithURL(folder.appending(path: path) as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            let margin = tileset["margin"] as? Int ?? 0, spacing = tileset["spacing"] as? Int ?? 0
            let w = image.width, h = image.height
            guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let pixels = context.data else { continue }
            let bytes = pixels.bindMemory(to: UInt8.self, capacity: w * h * 4)
            for id in 0..<count {
                let left = margin + (id % columns) * (width + spacing), top = margin + (id / columns) * (height + spacing)
                var tally: [Int: Int] = [:]
                for y in top..<min(top + height, h) {
                    for x in left..<min(left + width, w) {
                        let p = (y * w + x) * 4
                        guard bytes[p + 3] == 255 else { continue }
                        tally[Int(bytes[p]) << 16 | Int(bytes[p + 1]) << 8 | Int(bytes[p + 2]), default: 0] += 1
                    }
                }
                if let commonest = tally.max(by: { $0.value < $1.value })?.key { colours[first + id] = commonest }
            }
        }
        return colours
    }
}

// The Mentagons drawn straight from H3, with no files: each size's 41 rooms coloured by
// region, as the maps made from the Mentagon export are, and the pentagon room named.
extension TiledOverlayMap {
    /// Each Mentagon size's pentagon resolution; its rooms are two finer.
    static let mentagonSizes = [(0, "JumboMentagon"), (1, "BigMentagon"), (4, "Mentagon")]
    /// H3's twelve base pentagons, by base cell number.
    static let pentagonBases = [4, 14, 24, 38, 49, 58, 63, 72, 83, 97, 107, 117]

    /// Every size of Mentagon around each base pentagon in `bases`, coarsest first so the
    /// finer draw on top. Each size is its own resolution, so Tiled Layers hides it.
    init(mentagonsAround bases: [Int], name: String) {
        var pieces: [Piece] = []
        for (resolution, size) in Self.mentagonSizes {
            for baseCell in bases {
                let base: CellID = 0x8001fffffffffff | CellID(baseCell) << 45
                if let piece = Self.mentagon(base: base, resolution: resolution, title: "\(size) \(baseCell)") {
                    pieces.append(piece)
                }
            }
        }
        self.init(pieces: pieces, name: name, opening: UUID())
    }

    private static func mentagon(base: CellID, resolution: Int, title: String) -> Piece? {
        guard isPentagonCell(base), let pentagon = centreChild(of: base, at: resolution),
              let middle = centreChild(of: pentagon, at: resolution + 1),
              let room = centreChild(of: pentagon, at: resolution + 2) else { return nil }
        // The centre region, then the five around it clockwise from north (make.py's colours).
        let colours = [0x3468A8, 0x288496, 0x469678, 0x6078B0, 0x7864A0, 0x3C5A8C], landing = 0xECC45C
        let centre = Self.latLng(pentagon)
        // The middle region first: its bearing from the centre it shares is only rounding.
        let regions = [middle] + children(of: pentagon, at: resolution + 1).filter { $0 != middle }
            .sorted { Self.bearing(from: centre, to: Self.latLng($0)) < Self.bearing(from: centre, to: Self.latLng($1)) }
        var piece = Piece(resolution: resolution + 2)
        piece.fictional = true
        for (index, region) in regions.enumerated() {
            for cell in children(of: region, at: resolution + 2) {
                guard let polygon = cellPolygon(cell) else { piece.missed += 1; continue }
                piece.polygons[cell == room ? landing : colours[index % colours.count], default: []].append(polygon)
                piece.placed += 1
            }
        }
        let description = "Base cell \(getBaseCellNumber(base))'s pentagon at resolution \(resolution): five ways out, where a sixth would be on any other hex."
        piece.landmarks[room] = Landmark(name: title, description: description, cell: room)
        let at = Self.latLng(room)
        piece.names.append(Place(point: MKMapPoint(CLLocationCoordinate2D(latitude: at.latitude, longitude: at.longitude)), name: title, tier: 0))
        return piece.placed > 0 ? piece : nil
    }

    static func latLng(_ cell: CellID) -> (latitude: Double, longitude: Double) {
        var centre = LatLng()
        _ = cellToLatLng(cell, &centre)
        return (radsToDegs(centre.lat), radsToDegs(centre.lng))
    }

    /// Compass bearing in degrees, 0 at north, clockwise.
    static func bearing(from a: (latitude: Double, longitude: Double), to b: (latitude: Double, longitude: Double)) -> Double {
        let la1 = degsToRads(a.latitude), la2 = degsToRads(b.latitude), dl = degsToRads(b.longitude - a.longitude)
        let angle = atan2(sin(dl) * cos(la2), cos(la1) * sin(la2) - sin(la1) * cos(la2) * cos(dl))
        return (radsToDegs(angle) + 360).truncatingRemainder(dividingBy: 360)
    }
}
