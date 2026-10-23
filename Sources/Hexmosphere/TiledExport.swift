// SPDX-License-Identifier: Apache-2.0
// Exports the hexagons in view as a Tiled map (https://www.mapeditor.org): a
// folder holding hexmosphere.tmj and its tile image, hexes.png.
//
// H3's local I/J grid (cellToLocalIj) gives every cell near an origin cell a
// position on a flat hex grid, so neighbours in H3 stay neighbours in Tiled.
// TiledLayout turns that grid to within 15° of north up, using pointy- or
// flat-topped hexagons as needed; the map's properties record its origin cell,
// centre and the turn left over so other tools can place it.
//
// Two layers: tiles shaded by photo count, as on screen, and one point object
// per hexagon with its H3 index, centre, photo and day counts and first and
// last dates, ready to be named and described as a place. Photos library
// identifiers stay on the device.

import CoreGraphics
import Foundation
import ImageIO
import MapKit
import SwiftUI
import UniformTypeIdentifiers

/// The exported folder, handed to SwiftUI's file exporter.
struct TiledMapDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.folder] }

    let folder: FileWrapper

    init(folder: FileWrapper) { self.folder = folder }

    init(configuration: ReadConfiguration) throws {
        folder = configuration.file
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { folder }
}

enum TiledExportError: LocalizedError {
    case nothingInView
    case tooLarge(Int, Int)

    var errorDescription: String? {
        switch self {
        case .nothingInView: "No hexagons in view to export. Move the map over some."
        case .tooLarge(let width, let height):
            "The area in view is \(width) × \(height) hexagons, too large for one Tiled map. Zoom in or pick a larger cell size."
        }
    }
}

struct TiledExport {
    let document: TiledMapDocument
    let exported: Int
    /// Cells in view that H3's local grid couldn't place relative to the origin.
    let leftOut: Int
    let suggestedName: String

    static let maxTiles = 4_000_000

    init(binned: Binned, size: CellSize, visible: MKMapRect) throws {
        let backend = binned.backend
        let top = binned.cells.values.map { binned.value($0) }.max() ?? 0
        let inView = binned.cells.values.compactMap { cell -> (CellSummary, MKMapPoint)? in
            let corners = outline(of: cell.id, backend: backend)
            guard !corners.isEmpty else { return nil }
            let points = corners.map(MKMapPoint.init)
            let middle = MKMapPoint(x: points.map(\.x).reduce(0, +) / Double(points.count),
                                    y: points.map(\.y).reduce(0, +) / Double(points.count))
            return visible.contains(middle) ? (cell, middle) : nil
        }
        guard top > 0, !inView.isEmpty else { throw TiledExportError.nothingInView }

        let centre = MKMapPoint(x: visible.midX, y: visible.midY).coordinate
        let origin = cellFor(centre, size: size, backend: backend) ?? inView[0].0.id

        var placed: [(cell: CellSummary, point: MKMapPoint, i: Int, j: Int)] = []
        var leftOut = 0
        for (cell, point) in inView {
            guard let ij = localIJ(of: cell.id, origin: origin, backend: backend) else {
                leftOut += 1
                continue
            }
            placed.append((cell, point, ij.i, ij.j))
        }
        guard !placed.isEmpty else { throw TiledExportError.nothingInView }
        // Map points grow southwards; the layout wants north up.
        let layout = TiledLayout(cells: placed.map { ($0.i, $0.j, $0.point.x, -$0.point.y) })
        let width = layout.width, height = layout.height
        guard width * height <= Self.maxTiles else { throw TiledExportError.tooLarge(width, height) }

        var data = [Int](repeating: 0, count: width * height)
        var objects: [[String: Any]] = []
        let date = ISO8601DateFormatter()
        date.formatOptions = [.withFullDate]
        for (index, (place, tile)) in zip(placed, layout.tiles).enumerated() {
            let level = HexMapView.level(binned.value(place.cell), top: top)
            data[tile.row * width + tile.column] = 1 + level
            let (x, y) = layout.centre(tile)
            let coordinate = place.point.coordinate
            objects.append([
                "id": index + 1, "name": "", "type": "h3cell",
                "x": x, "y": y, "width": 0, "height": 0, "rotation": 0,
                "point": true, "visible": true,
                "properties": [
                    Self.property("h3", "string", cellName(place.cell.id)),
                    Self.property("latitude", "float", coordinate.latitude),
                    Self.property("longitude", "float", coordinate.longitude),
                    Self.property("photos", "int", place.cell.samples),
                    Self.property("days", "int", place.cell.days.count),
                    Self.property("first", "string", date.string(from: place.cell.first)),
                    Self.property("last", "string", date.string(from: place.cell.last)),
                ],
            ])
        }

        let map: [String: Any] = [
            "type": "map", "version": "1.10", "tiledversion": "1.12.2",
            "orientation": "hexagonal", "renderorder": "right-down",
            "staggeraxis": layout.staggerAxis, "staggerindex": layout.staggerIndex,
            "width": width, "height": height,
            "tilewidth": layout.tileWidth, "tileheight": layout.tileHeight, "hexsidelength": layout.hexSide,
            "infinite": false, "nextlayerid": 3, "nextobjectid": objects.count + 1,
            "properties": [
                Self.property("source", "string", "Hexmosphere"),
                Self.property("h3_resolution", "int", size.rawValue),
                Self.property("h3_backend", "string", backend.name),
                Self.property("origin_cell", "string", cellName(origin)),
                Self.property("centre_latitude", "float", centre.latitude),
                Self.property("centre_longitude", "float", centre.longitude),
                Self.property("turned_from_north_degrees", "float", (layout.residualDegrees * 10).rounded() / 10),
                Self.property("exported", "string", ISO8601DateFormatter().string(from: Date())),
            ],
            "tilesets": [[
                "firstgid": 1, "name": "photo count", "image": "hexes.png",
                "imagewidth": layout.tileWidth * HexMapView.levels, "imageheight": layout.tileHeight,
                "tilewidth": layout.tileWidth, "tileheight": layout.tileHeight,
                "tilecount": HexMapView.levels, "columns": HexMapView.levels, "margin": 0, "spacing": 0,
            ]],
            "layers": [
                [
                    "id": 1, "name": "photo count", "type": "tilelayer",
                    "x": 0, "y": 0, "width": width, "height": height,
                    "opacity": 1, "visible": true, "data": data,
                ],
                [
                    "id": 2, "name": "places", "type": "objectgroup", "draworder": "topdown",
                    "x": 0, "y": 0, "opacity": 1, "visible": true, "objects": objects,
                ],
            ],
        ]
        let json = try JSONSerialization.data(withJSONObject: map, options: [.prettyPrinted, .sortedKeys])
        document = TiledMapDocument(folder: FileWrapper(directoryWithFileWrappers: [
            "hexmosphere.tmj": FileWrapper(regularFileWithContents: json),
            "hexes.png": FileWrapper(regularFileWithContents: Self.tileImage(layout)),
        ]))
        exported = placed.count
        self.leftOut = leftOut
        // A new name each time: reusing one collides with the copy iOS stages
        // in the app's temporary folder, or with an earlier export.
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HHmmss"
        suggestedName = "Hexmosphere res \(size.rawValue) \(stamp.string(from: Date()))"
    }

    private static func property(_ name: String, _ type: String, _ value: Any) -> [String: Any] {
        ["name": name, "type": type, "value": value]
    }

    /// One hexagon (pointy- or flat-topped, to match the map) per shade level,
    /// side by side, in the app's orange.
    static func tileImage(_ layout: TiledLayout) -> Data {
        let levels = HexMapView.levels
        let tileWidth = layout.tileWidth, tileHeight = layout.tileHeight
        let context = CGContext(data: nil, width: tileWidth * levels, height: tileHeight, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // systemOrange, as near as a fixed colour gets.
        let (red, green, blue) = (1.0, 0.584, 0.0)
        for level in 0..<levels {
            let left = CGFloat(level * tileWidth)
            let w = CGFloat(tileWidth), h = CGFloat(tileHeight)
            let hexagon = CGMutablePath()
            if layout.kind == .pointy {
                let quarter = (h - CGFloat(layout.hexSide)) / 2
                hexagon.addLines(between: [
                    CGPoint(x: left + w / 2, y: 0), CGPoint(x: left + w, y: quarter),
                    CGPoint(x: left + w, y: h - quarter), CGPoint(x: left + w / 2, y: h),
                    CGPoint(x: left, y: h - quarter), CGPoint(x: left, y: quarter),
                ])
            } else {
                let quarter = (w - CGFloat(layout.hexSide)) / 2
                hexagon.addLines(between: [
                    CGPoint(x: left + quarter, y: 0), CGPoint(x: left + w - quarter, y: 0),
                    CGPoint(x: left + w, y: h / 2), CGPoint(x: left + w - quarter, y: h),
                    CGPoint(x: left + quarter, y: h), CGPoint(x: left, y: h / 2),
                ])
            }
            hexagon.closeSubpath()
            context.addPath(hexagon)
            context.setFillColor(red: red, green: green, blue: blue, alpha: HexMapView.alpha(level))
            context.fillPath()
            context.addPath(hexagon)
            context.setStrokeColor(red: red, green: green, blue: blue, alpha: 0.9)
            context.setLineWidth(1)
            context.strokePath()
        }
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }
}
