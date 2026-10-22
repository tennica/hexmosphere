// SPDX-License-Identifier: Apache-2.0
// The offline base map: Natural Earth outlines and OpenStreetMap place names,
// bundled with the app and drawn by MapKit as overlays on a blank background,
// so the map never asks Apple (or anyone) for tiles unless the Apple map is on.

import CoreGraphics
import CoreText
import Foundation
import ImageIO
import MapKit
import UniformTypeIdentifiers

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
        context.setFillColor(red: 0.965, green: 0.953, blue: 0.933, alpha: 1)
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

enum LineStyle { case coast, border, state }

final class BaseLines: MKMultiPolyline {
    var style = LineStyle.coast
}

final class BaseWater: MKMultiPolygon {}

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

// MARK: - Loading

struct Basemap {
    var overlays: [MKOverlay] = []
    var places: Places?

    static func load() -> Basemap {
        guard let root = Bundle.main.url(forResource: "Basemap", withExtension: nil) else { return Basemap() }
        var basemap = Basemap()
        let ne = root.appendingPathComponent("naturalearth")
        basemap.overlays += lines(ne.appendingPathComponent("ne_50m_coastline.geojson"), .coast)
        basemap.overlays += lines(ne.appendingPathComponent("ne_50m_admin_0_boundary_lines_land.geojson"), .border)
        basemap.overlays += lines(ne.appendingPathComponent("ne_50m_admin_1_states_provinces_lines.geojson"), .state)
        basemap.overlays += water(ne.appendingPathComponent("ne_50m_lakes.geojson"))

        var places = worldCities(ne.appendingPathComponent("ne_10m_populated_places_simple.geojson"))
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

    private static func lines(_ url: URL, _ style: LineStyle) -> [MKOverlay] {
        var polylines: [MKPolyline] = []
        for feature in features(url) {
            for shape in feature.geometry {
                if let line = shape as? MKPolyline { polylines.append(line) }
                if let multi = shape as? MKMultiPolyline { polylines += multi.polylines }
            }
        }
        guard !polylines.isEmpty else { return [] }
        let overlay = BaseLines(polylines)
        overlay.style = style
        return [overlay]
    }

    private static func water(_ url: URL) -> [MKOverlay] {
        var polygons: [MKPolygon] = []
        for feature in features(url) {
            for shape in feature.geometry {
                if let polygon = shape as? MKPolygon { polygons.append(polygon) }
                if let multi = shape as? MKMultiPolygon { polygons += multi.polygons }
            }
        }
        return polygons.isEmpty ? [] : [BaseWater(polygons)]
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

func basemapRenderer(for overlay: MKOverlay) -> MKOverlayRenderer? {
    if let tiles = overlay as? BlankTiles {
        return MKTileOverlayRenderer(tileOverlay: tiles)
    }
    if let places = overlay as? Places {
        return PlacesRenderer(places)
    }
    if let lines = overlay as? BaseLines {
        let renderer = MKMultiPolylineRenderer(multiPolyline: lines)
        switch lines.style {
        case .coast:
            renderer.strokeColor = PlatformColor(red: 0.45, green: 0.52, blue: 0.60, alpha: 1)
            renderer.lineWidth = 1.0
        case .border:
            renderer.strokeColor = PlatformColor(red: 0.50, green: 0.50, blue: 0.52, alpha: 1)
            renderer.lineWidth = 1.0
        case .state:
            renderer.strokeColor = PlatformColor(red: 0.62, green: 0.62, blue: 0.64, alpha: 1)
            renderer.lineWidth = 0.7
            renderer.lineDashPattern = [4, 3]
        }
        return renderer
    }
    if let water = overlay as? BaseWater {
        let renderer = MKMultiPolygonRenderer(multiPolygon: water)
        renderer.fillColor = PlatformColor(red: 0.84, green: 0.89, blue: 0.94, alpha: 1)
        renderer.strokeColor = PlatformColor(red: 0.45, green: 0.52, blue: 0.60, alpha: 0.8)
        renderer.lineWidth = 0.6
        return renderer
    }
    return nil
}
