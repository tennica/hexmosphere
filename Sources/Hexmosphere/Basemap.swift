// SPDX-License-Identifier: Apache-2.0
// The offline base map: Natural Earth outlines and OpenStreetMap place names,
// bundled with the app and drawn by MapKit as overlays on a blank background,
// so the map never asks Apple (or anyone) for tiles.

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import MapKit
import UniformTypeIdentifiers
import CH3

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Map credit to show whenever the bundled base map is visible (ODbL asks for it).
let basemapCredit = "map: Natural Earth · © OpenStreetMap contributors"

// MARK: - Overlays

/// Replaces MapKit's own map content with a plain background, so no tiles are fetched.
final class BlankTiles: MKTileOverlay {
    static let tile: Data = {
        let size = 256
        let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        if Basemap.landCellsURL != nil {
            context.setFillColor(red: 0.84, green: 0.89, blue: 0.94, alpha: 1)  // ocean
        } else {
            context.setFillColor(red: 0.965, green: 0.953, blue: 0.933, alpha: 1)  // paper
        }
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }()

    init() {
        super.init(urlTemplate: nil)
        canReplaceMapContent = true
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, Error?) -> Void) {
        result(Self.tile, nil)
    }
}

/// How one Natural Earth layer is drawn.
struct LayerStyle {
    enum Kind { case line, fill }
    let kind: Kind
    let stroke: (CGFloat, CGFloat, CGFloat)?
    let fill: (CGFloat, CGFloat, CGFloat)?
    let width: CGFloat
    let dash: [NSNumber]?

    static func line(_ c: (CGFloat, CGFloat, CGFloat), _ width: CGFloat, dash: [NSNumber]? = nil) -> LayerStyle {
        LayerStyle(kind: .line, stroke: c, fill: nil, width: width, dash: dash)
    }
    static func area(_ fill: (CGFloat, CGFloat, CGFloat), edge: (CGFloat, CGFloat, CGFloat)? = nil) -> LayerStyle {
        LayerStyle(kind: .fill, stroke: edge, fill: fill, width: 0.6, dash: nil)
    }
}

private let water = (CGFloat(0.84), CGFloat(0.89), CGFloat(0.94))
private let waterEdge = (CGFloat(0.45), CGFloat(0.52), CGFloat(0.60))
private let ice = (CGFloat(0.95), CGFloat(0.97), CGFloat(0.99))

/// The Natural Earth layers the app draws, bottom to top, by name without the
/// scale prefix. Other layers in the folders (countries, graticules, labels…)
/// are cached but not drawn.
/// The ocean isn't drawn: it is one world-sized polygon of about 61,000 points at
/// 1:50m, redrawn for every tile, and the coastline already shows where land ends.
let layerStyles: [(String, LayerStyle)] = [
    ("glaciated_areas", .area(ice)),
    ("antarctic_ice_shelves_polys", .area(ice)),
    ("playas", .area((0.93, 0.89, 0.80))),
    ("urban_areas", .area((0.89, 0.87, 0.84))),
    ("lakes", .area(water, edge: waterEdge)),
    ("lakes_north_america", .area(water, edge: waterEdge)),
    ("lakes_europe", .area(water, edge: waterEdge)),
    ("rivers_lake_centerlines", .line((0.55, 0.68, 0.82), 0.8)),
    ("rivers_north_america", .line((0.55, 0.68, 0.82), 0.6)),
    ("rivers_europe", .line((0.55, 0.68, 0.82), 0.6)),
    ("geographic_lines", .line((0.70, 0.72, 0.76), 0.5, dash: [2, 4])),
    ("coastline", .line(waterEdge, 1.0)),
    ("admin_1_states_provinces_lines", .line((0.62, 0.62, 0.64), 0.7, dash: [4, 3])),
    ("admin_0_boundary_lines_maritime_indicator", .line((0.55, 0.62, 0.72), 0.6, dash: [3, 3])),
    ("admin_0_boundary_lines_disputed_areas", .line((0.50, 0.50, 0.52), 0.9, dash: [5, 3])),
    ("admin_0_boundary_lines_land", .line((0.50, 0.50, 0.52), 1.0)),
]

final class StyledLines: MKMultiPolyline {
    var style = LayerStyle.line((0, 0, 0), 1)
}

final class StyledAreas: MKMultiPolygon {
    var style = LayerStyle.area((0, 0, 0))
}

struct Place {
    let point: MKMapPoint
    let name: String
    /// 0 = world city / large city, 1 = city, 2 = town, 3 = suburb or village.
    let tier: Int
}

/// All place names in one overlay; its renderer picks which tiers to label by zoom.
final class Places: NSObject, MKOverlay {
    let places: [Place]
    init(_ places: [Place]) { self.places = places }
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: 0, longitude: 0) }
    var boundingMapRect: MKMapRect { .world }
}

final class PlacesRenderer: MKOverlayRenderer {
    private let places: Places

    init(_ places: Places) {
        self.places = places
        super.init(overlay: places)
    }

    /// The finest tier worth labelling at this zoom, from metres per screen point.
    private func maxTier(metresPerPoint: Double) -> Int {
        switch metresPerPoint {
        case ..<25: return 3
        case ..<150: return 2
        case ..<1500: return 1
        default: return 0
        }
    }

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let metresPerPoint = MKMetersPerMapPointAtLatitude(mapRect.origin.coordinate.latitude) / Double(zoomScale)
        let finest = maxTier(metresPerPoint: metresPerPoint)
        // Look a little beyond this tile so labels that cross its edge are drawn in both tiles.
        let margin = 160 / Double(zoomScale)
        let area = mapRect.insetBy(dx: -margin, dy: -margin)
        let fontSize = CGFloat(11) / zoomScale
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let ink = CGColor(red: 0.27, green: 0.29, blue: 0.33, alpha: 1)
        let radius = CGFloat(2.2) / zoomScale

        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for place in places.places where place.tier <= finest && area.contains(place.point) {
            let at = point(for: place.point)
            context.setFillColor(ink)
            context.fillEllipse(in: CGRect(x: at.x - radius, y: at.y - radius, width: radius * 2, height: radius * 2))
            let text = NSAttributedString(string: place.name, attributes: [
                kCTFontAttributeName as NSAttributedString.Key: font,
                kCTForegroundColorAttributeName as NSAttributedString.Key: ink,
            ])
            let line = CTLineCreateWithAttributedString(text)
            context.textPosition = CGPoint(x: at.x + radius * 2, y: at.y + fontSize * 0.35)
            CTLineDraw(line, context)
        }
    }
}

/// Splits shapes into regional groups on an 8×8 grid over the world, by where
/// each shape's middle falls. MapKit only draws an overlay on the tiles its
/// bounds touch, so a tile then draws its own region's shapes instead of the
/// whole world's.
func groupedByRegion<Shape: MKOverlay>(_ shapes: [Shape]) -> [[Shape]] {
    let side = 8.0
    let world = MKMapRect.world
    var groups: [Int: [Shape]] = [:]
    for shape in shapes {
        let rect = shape.boundingMapRect
        let column = min(Int(side) - 1, max(0, Int((rect.midX - world.minX) / world.width * side)))
        let row = min(Int(side) - 1, max(0, Int((rect.midY - world.minY) / world.height * side)))
        groups[row * Int(side) + column, default: []].append(shape)
    }
    return Array(groups.values)
}

// MARK: - Land as H3 cells

/// A cell's outline as a map polygon. Cells that straddle the 180° meridian get
/// their western vertices shifted one world-width east, so MapKit draws them in
/// place instead of stretched across the whole map.
func cellPolygon(_ cell: UInt64) -> MKPolygon? {
    var boundary = CellBoundary()
    guard cellToBoundary(cell, &boundary) == 0, boundary.numVerts >= 3 else { return nil }
    let count = Int(boundary.numVerts)
    var points: [MKMapPoint] = withUnsafeBytes(of: &boundary.verts) { raw in
        let vertices = raw.bindMemory(to: LatLng.self)
        return (0..<count).map {
            MKMapPoint(CLLocationCoordinate2D(latitude: radsToDegs(vertices[$0].lat), longitude: radsToDegs(vertices[$0].lng)))
        }
    }
    let xs = points.map(\.x)
    if let low = xs.min(), let high = xs.max(), high - low > MKMapRect.world.width / 2 {
        points = points.map { $0.x < MKMapRect.world.width / 2 ? MKMapPoint(x: $0.x + MKMapRect.world.width, y: $0.y) : $0 }
    }
    return MKPolygon(points: points, count: points.count)
}

// MARK: - Loading

struct Basemap {
    var overlays: [MKOverlay] = []
    var places: Places?

    private static let queue = DispatchQueue(label: "hexmosphere.basemap", qos: .userInitiated)
    private static var loaded: Basemap?

    /// Loads the bundled base map once, off the main thread, and hands it back on the main thread.
    static func whenLoaded(_ done: @escaping (Basemap) -> Void) {
        if let loaded { return done(loaded) }
        queue.async {
            let basemap = loaded ?? load()
            DispatchQueue.main.async {
                loaded = basemap
                done(basemap)
            }
        }
    }

    /// Every Natural Earth file in Basemap/naturalearth and Basemap/naturalearth-extra,
    /// keeping the finest scale (10m, then 50m, then 110m) for each layer name.
    private static func naturalEarthLayers(_ root: URL) -> [String: URL] {
        let rank = ["10m": 0, "50m": 1, "110m": 2]
        var best: [String: (Int, URL)] = [:]
        for folder in ["naturalearth", "naturalearth-extra"] {
            let dir = root.appendingPathComponent(folder)
            for file in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                let name = file.deletingPathExtension().lastPathComponent
                guard file.pathExtension == "geojson", name.hasPrefix("ne_") else { continue }
                let parts = name.dropFirst(3).split(separator: "_", maxSplits: 1).map(String.init)
                guard parts.count == 2, let r = rank[parts[0]] else { continue }
                if best[parts[1]].map({ r < $0.0 }) ?? true { best[parts[1]] = (r, file) }
            }
        }
        return best.mapValues(\.1)
    }

    /// The precomputed land cells (scripts/build-land-cells.sh), if bundled.
    static let landCellsURL: URL? = {
        guard let dir = Bundle.main.url(forResource: "Basemap", withExtension: nil)?.appendingPathComponent("h3") else { return nil }
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "cells" && $0.lastPathComponent.hasPrefix("land-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }.last
    }()

    /// Land drawn as compacted H3 cells, in paper colour on the ocean-blue background.
    private static func landCells() -> [MKOverlay] {
        guard let url = landCellsURL, let data = try? Data(contentsOf: url) else { return [] }
        let cells: [UInt64] = data.withUnsafeBytes { raw in
            (0..<(raw.count / 8)).map { UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 8, as: UInt64.self)) }
        }
        let polygons = cells.compactMap(cellPolygon)
        let style = LayerStyle.area((0.965, 0.953, 0.933), edge: (0.80, 0.78, 0.74))
        return groupedByRegion(polygons).map { group in
            let overlay = StyledAreas(group)
            overlay.style = LayerStyle(kind: .fill, stroke: style.stroke, fill: style.fill, width: 0.3, dash: nil)
            return overlay
        }
    }

    static func load() -> Basemap {
        guard let root = Bundle.main.url(forResource: "Basemap", withExtension: nil) else { return Basemap() }
        var basemap = Basemap()
        let layers = naturalEarthLayers(root)
        let land = landCells()
        basemap.overlays += land
        let roadsURL = root.appendingPathComponent("roads/roads.bin")
        let worldRoads = FileManager.default.fileExists(atPath: roadsURL.path) ? Roads.load(roadsURL, side: 16) : []
        let streetFiles = ((try? FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent("streets"), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("streets-") && $0.pathExtension == "bin" }
        var streets: [Roads] = []
        var covered: [MKMapRect] = []
        for file in streetFiles {
            // About 1.4° squares, so a tile looks at only a few thousand pieces.
            let region = Roads.load(file, side: 256)
            streets += region
            covered.append(region.reduce(MKMapRect.null) { $0.union($1.boundingMapRect) })
        }
        for overlay in worldRoads { overlay.hiddenWithin = covered }
        let roads: [MKOverlay] = worldRoads + streets
        for (name, style) in layerStyles {
            // Roads go above water and rivers, below borders and other lines.
            if name == "geographic_lines" { basemap.overlays += roads }
            // With the land drawn as hexagons, their edges are the coast.
            if !land.isEmpty && name == "coastline" { continue }
            guard let url = layers[name] else { continue }
            basemap.overlays += overlays(url, style)
        }

        var places: [Place] = []
        if let cities = layers["populated_places_simple"] ?? layers["populated_places"] {
            places += worldCities(cities)
        }
        let osm = root.appendingPathComponent("osm")
        for file in (try? FileManager.default.contentsOfDirectory(at: osm, includingPropertiesForKeys: nil)) ?? []
        where file.lastPathComponent.hasPrefix("places-") && file.pathExtension == "geojson" {
            places += osmPlaces(file)
        }
        basemap.places = Places(places)
        return basemap
    }

    private static func features(_ url: URL) -> [MKGeoJSONFeature] {
        guard let data = try? Data(contentsOf: url),
              let objects = try? MKGeoJSONDecoder().decode(data) else { return [] }
        return objects.compactMap { $0 as? MKGeoJSONFeature }
    }

    private static func overlays(_ url: URL, _ style: LayerStyle) -> [MKOverlay] {
        var polylines: [MKPolyline] = []
        var polygons: [MKPolygon] = []
        for feature in features(url) {
            for shape in feature.geometry {
                if let line = shape as? MKPolyline { polylines.append(line) }
                if let multi = shape as? MKMultiPolyline { polylines += multi.polylines }
                if let polygon = shape as? MKPolygon { polygons.append(polygon) }
                if let multi = shape as? MKMultiPolygon { polygons += multi.polygons }
            }
        }
        switch style.kind {
        case .line:
            return groupedByRegion(polylines).map { group in
                let overlay = StyledLines(group)
                overlay.style = style
                return overlay
            }
        case .fill:
            return groupedByRegion(polygons).map { group in
                let overlay = StyledAreas(group)
                overlay.style = style
                return overlay
            }
        }
    }


    private static func points(_ url: URL) -> [(CLLocationCoordinate2D, [String: Any])] {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = json["features"] as? [[String: Any]] else { return [] }
        return features.compactMap { feature in
            guard let geometry = feature["geometry"] as? [String: Any],
                  let coordinates = geometry["coordinates"] as? [Double], coordinates.count >= 2,
                  let properties = feature["properties"] as? [String: Any] else { return nil }
            return (CLLocationCoordinate2D(latitude: coordinates[1], longitude: coordinates[0]), properties)
        }
    }

    /// Natural Earth's world cities: the biggest always, the rest as cities.
    private static func worldCities(_ url: URL) -> [Place] {
        points(url).compactMap { coordinate, properties in
            guard let name = properties["name"] as? String else { return nil }
            let rank = properties["rank"] as? Int ?? 10
            return Place(point: MKMapPoint(coordinate), name: name, tier: rank <= 3 ? 0 : 1)
        }
    }

    private static func osmPlaces(_ url: URL) -> [Place] {
        points(url).compactMap { coordinate, properties in
            guard let name = properties["name"] as? String, let kind = properties["place"] as? String else { return nil }
            let tier: Int
            switch kind {
            case "city": tier = 1
            case "town": tier = 2
            default: tier = 3
            }
            return Place(point: MKMapPoint(coordinate), name: name, tier: tier)
        }
    }
}

// MARK: - Renderers for the base layers

private func color(_ c: (CGFloat, CGFloat, CGFloat)?, _ alpha: CGFloat = 1) -> PlatformColor? {
    c.map { PlatformColor(red: $0.0, green: $0.1, blue: $0.2, alpha: alpha) }
}

func basemapRenderer(for overlay: MKOverlay) -> MKOverlayRenderer? {
    if let tiles = overlay as? BlankTiles {
        return MKTileOverlayRenderer(tileOverlay: tiles)
    }
    if let places = overlay as? Places {
        return PlacesRenderer(places)
    }
    if let roads = overlay as? Roads {
        return RoadsRenderer(roads)
    }
    if let lines = overlay as? StyledLines {
        let renderer = MKMultiPolylineRenderer(multiPolyline: lines)
        renderer.strokeColor = color(lines.style.stroke)
        renderer.lineWidth = lines.style.width
        renderer.lineDashPattern = lines.style.dash
        return renderer
    }
    if let areas = overlay as? StyledAreas {
        let renderer = MKMultiPolygonRenderer(multiPolygon: areas)
        renderer.fillColor = color(areas.style.fill)
        renderer.strokeColor = color(areas.style.stroke, 0.8)
        renderer.lineWidth = areas.style.width
        return renderer
    }
    return nil
}
