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
    /// The deepest zoom of each map scale in the layer, coarsest first (the topo maps: 11 for
    /// 1:250,000, 13 for 1:62,500, 15 for 1:24,000); just maxZoom for a layer of one scale.
    let levels: [Int]
    let folder: URL

    /// Every bundled layer, by title.
    static let all: [VintageLayer] = {
        guard let root = Bundle.main.url(forResource: "Basemap", withExtension: nil)?.appendingPathComponent("vintage"),
              let folders = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return [] }
        return folders.compactMap { folder -> VintageLayer? in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent("layer.json")),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let title = json["title"] as? String else { return nil }
            let maxZoom = json["maxZoom"] as? Int ?? 18
            return VintageLayer(id: folder.lastPathComponent, title: title, credit: json["credit"] as? String ?? "",
                                minZoom: json["minZoom"] as? Int ?? 0, maxZoom: maxZoom,
                                levels: (json["levels"] as? [Int])?.sorted() ?? [maxZoom], folder: folder)
        }
        .sorted { $0.title < $1.title }
    }()
}

/// A vintage layer's tiles, read from the app bundle. Each map scale is drawn over the
/// coarser ones, enlarged: the topo maps are clipped to narrower chains of hexagons the finer
/// the scale, and cover only parts of the route at the finer scales, so the 1:250,000 map
/// fills its wide chain, with sharper maps inside where there are any. Past the deepest zoom
/// every scale is enlarged, so the layer stays on screen as you zoom in; MapKit draws nothing
/// past a tile overlay's maximum zoom, which a Retina screen passes sooner than the zoom
/// level suggests.
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
        // For each scale that has begun by this zoom, coarsest first: its tile here, or past its
        // deepest zoom the one it has there, with how many zooms up that is.
        var sources: [(data: Data, up: Int)] = []
        var start = layer.minZoom
        for deepest in layer.levels where start <= path.z {
            let z = min(path.z, deepest), up = path.z - z
            if let data = read(z, path.x >> up, path.y >> up) { sources.append((data, up)) }
            start = deepest + 1
        }
        if sources.count == 1, sources[0].up == 0 { return result(sources[0].data, nil) }
        result(sources.isEmpty ? Self.empty : stacked(sources, path) ?? Self.empty, nil)
    }

    private func read(_ z: Int, _ x: Int, _ y: Int) -> Data? {
        try? Data(contentsOf: layer.folder.appendingPathComponent("\(z)/\(x)/\(y).webp"))
    }

    /// The tiles drawn one over another, coarsest first, each cut to the part this tile covers
    /// and scaled up to a full tile when it's from zooms up, as PNG.
    private func stacked(_ sources: [(data: Data, up: Int)], _ path: MKTileOverlayPath) -> Data? {
        let side = 256
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .medium
        for (data, up) in sources {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            let parts = 1 << up
            let part = CGFloat(image.width) / CGFloat(parts)
            let column = CGFloat(path.x & (parts - 1)), row = CGFloat(path.y & (parts - 1))
            guard let piece = image.cropping(to: CGRect(x: column * part, y: row * part, width: part, height: part))
            else { continue }
            context.draw(piece, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        guard let scaled = context.makeImage() else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, scaled, nil)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}
