// SPDX-License-Identifier: Apache-2.0
// Vintage layers: old maps and early satellite imagery along a route, as bundled tiles in
// Basemap/vintage/<name>/{z}/{x}/{y}.webp with a layer.json naming them (made by
// scripts/vintage-fetch.py with vintage-landsat.py or vintage-topo.py; gitignored, like the
// streets). One at a time is drawn over the land and under the roads, place names and
// hexagons. Like the rest of the base map, they're read from the app, never fetched.

import Foundation
import ImageIO
import MapKit
import UniformTypeIdentifiers

struct VintageLayer: Identifiable, Hashable {
    let id: String
    let title: String
    /// Added to the map's credit line while the layer is shown.
    let credit: String
    let minZoom: Int
    let maxZoom: Int
    let folder: URL

    /// Every bundled layer, by title.
    static let all: [VintageLayer] = {
        guard let root = Bundle.main.url(forResource: "Basemap", withExtension: nil)?.appendingPathComponent("vintage"),
              let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return folders.compactMap { folder -> VintageLayer? in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("layer.json")),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let title = json["title"] as? String else { return nil }
            return VintageLayer(id: folder.lastPathComponent, title: title, credit: json["credit"] as? String ?? "",
                                minZoom: json["minZoom"] as? Int ?? 0, maxZoom: json["maxZoom"] as? Int ?? 18, folder: folder)
        }
        .sorted { $0.title < $1.title }
    }()
}

/// A vintage layer's tiles, read from the app bundle. Past the layer's deepest zoom, a
/// tile is cut from the deepest one and enlarged, so the layer stays on screen as you zoom
/// in; MapKit draws nothing past a tile overlay's maximum zoom, which a Retina screen
/// passes sooner than the zoom level suggests.
final class VintageTiles: MKTileOverlay {
    let layer: VintageLayer

    /// A transparent 1×1 PNG, for places and zooms the layer doesn't cover.
    private static let empty = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAC0lEQVR4nGNgAAIAAAUAAXpeqz8AAAAASUVORK5CYII=")!

    init(_ layer: VintageLayer) {
        self.layer = layer
        super.init(urlTemplate: nil)
        canReplaceMapContent = false
        minimumZ = layer.minZoom
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        if path.z <= layer.maxZoom {
            return result(read(path.z, path.x, path.y) ?? Self.empty, nil)
        }
        result(enlarged(path) ?? Self.empty, nil)
    }

    private func read(_ z: Int, _ x: Int, _ y: Int) -> Data? {
        try? Data(contentsOf: layer.folder.appendingPathComponent("\(z)/\(x)/\(y).webp"))
    }

    /// The part of the deepest tile that this deeper tile covers, scaled up to a full tile, as PNG.
    private func enlarged(_ path: MKTileOverlayPath) -> Data? {
        let levels = path.z - layer.maxZoom
        let parts = 1 << levels
        guard let data = read(layer.maxZoom, path.x >> levels, path.y >> levels),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let side = CGFloat(image.width) / CGFloat(parts)
        let column = CGFloat(path.x & (parts - 1)), row = CGFloat(path.y & (parts - 1))
        guard let piece = image.cropping(to: CGRect(x: column * side, y: row * side, width: side, height: side)),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        context.draw(piece, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let scaled = context.makeImage() else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, scaled, nil)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}
