// SPDX-License-Identifier: Apache-2.0
// MapKit view drawing cells as polygons, grouped into a few shade levels so
// thousands of cells stay fast (one multipolygon overlay per level).
// Shared by the Mac (AppKit) and iPad (UIKit) builds.

import MapKit
import SwiftUI

#if os(macOS)
import AppKit
typealias PlatformColor = NSColor
typealias PlatformViewRepresentable = NSViewRepresentable
#else
import UIKit
typealias PlatformColor = UIColor
typealias PlatformViewRepresentable = UIViewRepresentable
#endif

struct HexMapView: PlatformViewRepresentable {
    let binned: Binned
    let size: CellSize
    let onSelect: (CellSummary?) -> Void
    /// Where the map is looking, kept up to date for exporting the visible area.
    let visible: VisibleArea
    /// The hexagon you're in, when Where I Am is on: outlined above the photos' cells.
    var here: CellID? = nil

    static let levels = 6

    /// The shade level (0 to levels − 1) for a cell's value, on a log scale like
    /// the solstone prototype, so a few very busy cells don't wash out the rest.
    static func level(_ value: Int, top: Int) -> Int {
        let share = log(Double(value) + 1) / log(Double(top) + 1)
        return min(levels - 1, Int(share * Double(levels)))
    }

    /// Fill opacity for a shade level, shared with the Tiled export's tile image.
    static func alpha(_ level: Int) -> Double {
        0.15 + 0.7 * Double(level + 1) / Double(levels)
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect, visible: visible) }

    #if os(macOS)
    func makeNSView(context: Context) -> MKMapView { makeMap(context) }
    func updateNSView(_ map: MKMapView, context: Context) { update(map, context) }
    #else
    func makeUIView(context: Context) -> MKMapView { makeMap(context) }
    func updateUIView(_ map: MKMapView, context: Context) { update(map, context) }
    #endif

    private func makeMap(_ context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsCompass = true
        #if os(macOS)
        map.showsZoomControls = true
        map.addGestureRecognizer(NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.picked(_:))))
        #else
        map.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.picked(_:))))
        #endif
        addBase(map, context.coordinator)
        return map
    }

    private func update(_ map: MKMapView, _ context: Context) {
        let coordinator = context.coordinator
        coordinator.binned = binned
        coordinator.size = size
        coordinator.onSelect = onSelect
        showHere(map, coordinator)
        // SwiftUI calls this for any change in the window; rebuild the cells
        // only when they changed, or redrawing them can feed back into here.
        guard coordinator.drawnID != binned.id else { return }
        coordinator.drawnID = binned.id
        map.removeOverlays(coordinator.hexOverlays)
        coordinator.hexOverlays = []

        let values = binned.cells.values.map { binned.value($0) }
        guard let top = values.max(), top > 0 else { return }
        // Log scale, like the solstone prototype: a few very busy cells
        // shouldn't wash out everything else.
        var buckets = Array(repeating: [MKPolygon](), count: Self.levels)
        for cell in binned.cells.values {
            let corners = outline(of: cell.id, backend: binned.backend)
            guard corners.count >= 3 else { continue }
            let level = Self.level(binned.value(cell), top: top)
            buckets[level].append(MKPolygon(coordinates: corners, count: corners.count))
        }
        // One overlay per shade level and region, so a tile only draws nearby cells.
        for (level, polygons) in buckets.enumerated() where !polygons.isEmpty {
            for group in groupedByRegion(polygons) {
                let overlay = ShadedCells(group)
                overlay.level = level
                // Everything sits above Apple's labels (see setBase), with place names on top.
                if let places = coordinator.places {
                    map.insertOverlay(overlay, below: places)
                } else {
                    map.addOverlay(overlay, level: .aboveLabels)
                }
                coordinator.hexOverlays.append(overlay)
            }
        }
        // The cells just went in under the place names, so put the hexagon you're in back above them.
        if let hereOverlay = coordinator.hereOverlay {
            map.removeOverlay(hereOverlay)
            if let places = coordinator.places {
                map.insertOverlay(hereOverlay, below: places)
            } else {
                map.addOverlay(hereOverlay, level: .aboveLabels)
            }
        }

        // MapKit doesn't always draw overlays added to tiles already on screen
        // until the map moves, so ask every cell renderer to draw once the
        // renderers exist (MapKit creates them after this returns).
        let added = coordinator.hexOverlays
        DispatchQueue.main.async { [weak map] in
            for overlay in added {
                map?.renderer(for: overlay)?.setNeedsDisplay()
            }
        }
    }

    /// Outlines the hexagon you're in, replacing the last one only when it changes.
    private func showHere(_ map: MKMapView, _ coordinator: Coordinator) {
        guard coordinator.hereCell != here || coordinator.hereBackend != binned.backend else { return }
        let found = coordinator.hereCell == nil
        coordinator.hereCell = here
        coordinator.hereBackend = binned.backend
        if let old = coordinator.hereOverlay {
            map.removeOverlay(old)
            coordinator.hereOverlay = nil
        }
        guard let here else { return }
        let corners = outline(of: here, backend: binned.backend)
        guard corners.count >= 3 else { return }
        let overlay = HereCell(coordinates: corners, count: corners.count)
        if let places = coordinator.places {
            map.insertOverlay(overlay, below: places)
        } else {
            map.addOverlay(overlay, level: .aboveLabels)
        }
        coordinator.hereOverlay = overlay
        // When you're first found, go there: a dozen hexagons across, and never wider
        // in view than about 5 km, so the smaller sizes still open on streets. After that
        // the map stays where you put it, and the outline moves within it.
        if found {
            let cell = overlay.boundingMapRect
            let floor = 5000 / MKMetersPerMapPointAtLatitude(overlay.coordinate.latitude)
            let side = max(cell.width * 12, floor)
            let area = MKMapRect(x: cell.midX - side / 2, y: cell.midY - side / 2, width: side, height: side)
            map.setVisibleMapRect(area, animated: true)
        }
    }

    /// Covers Apple's map with the bundled offline base map. Apple's map is
    /// never shown: the offline map, with OpenStreetMap streets for fetched
    /// regions, is the whole map.
    private func addBase(_ map: MKMapView, _ coordinator: Coordinator) {
        let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        configuration.pointOfInterestFilter = .excludingAll
        configuration.showsTraffic = false
        map.preferredConfiguration = configuration
        // The blank background goes in at once, so no Apple tiles load while
        // the bundled data (up to tens of MB) is read in the background.
        let blank = BlankTiles()
        // At the "above labels" level, the blank background covers Apple's
        // labels too, not just its map; everything else goes above it.
        map.insertOverlay(blank, at: 0, level: .aboveLabels)
        coordinator.baseOverlays = [blank]
        Basemap.whenLoaded { [weak map, weak coordinator] basemap in
            guard let map, let coordinator else { return }
            // Cells sit above the outlines; place names go on top of everything.
            for (offset, overlay) in basemap.overlays.enumerated() {
                map.insertOverlay(overlay, at: offset + 1, level: .aboveLabels)
            }
            coordinator.baseOverlays += basemap.overlays
            if let places = basemap.places {
                map.addOverlay(places, level: .aboveLabels)
                coordinator.baseOverlays.append(places)
                coordinator.places = places
            }
            // The map has usually drawn its first tiles by now, and MapKit
            // doesn't add new overlays to tiles already on screen until the
            // map moves, so ask every base layer to draw (as for the cells).
            let added = coordinator.baseOverlays
            DispatchQueue.main.async { [weak map] in
                for overlay in added {
                    map?.renderer(for: overlay)?.setNeedsDisplay()
                }
            }
        }
    }

    /// The map's visible area, shared by reference so updating it doesn't
    /// redraw the SwiftUI window on every pan.
    final class VisibleArea {
        var rect = MKMapRect.null
    }

    final class ShadedCells: MKMultiPolygon {
        var level = 0
    }

    final class HereCell: MKPolygon {}

    final class Coordinator: NSObject, MKMapViewDelegate {
        var binned = Binned()
        var size = CellSize.r7
        var drawnID: UUID?
        var hexOverlays: [MKOverlay] = []
        var baseOverlays: [MKOverlay] = []
        /// The place-name overlay, kept on top of the cells.
        var places: MKOverlay?
        var onSelect: (CellSummary?) -> Void
        var hereCell: CellID?
        var hereBackend: H3Backend?
        var hereOverlay: HereCell?

        let visible: VisibleArea

        init(onSelect: @escaping (CellSummary?) -> Void, visible: VisibleArea) {
            self.onSelect = onSelect
            self.visible = visible
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            visible.rect = mapView.visibleMapRect
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let base = basemapRenderer(for: overlay) { return base }
            if let here = overlay as? HereCell {
                let renderer = MKPolygonRenderer(polygon: here)
                renderer.fillColor = PlatformColor.systemBlue.withAlphaComponent(0.2)
                renderer.strokeColor = PlatformColor.systemBlue
                renderer.lineWidth = 3
                return renderer
            }
            guard let cells = overlay as? ShadedCells else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKMultiPolygonRenderer(multiPolygon: cells)
            let alpha = HexMapView.alpha(cells.level)
            renderer.fillColor = PlatformColor.systemOrange.withAlphaComponent(alpha)
            renderer.strokeColor = PlatformColor.systemOrange.withAlphaComponent(0.9)
            renderer.lineWidth = 0.8
            return renderer
        }

        /// A click (Mac) or tap (iPad) on the map shows that cell's details.
        @objc func picked(_ gesture: Any) {
            #if os(macOS)
            guard let gesture = gesture as? NSGestureRecognizer, let map = gesture.view as? MKMapView else { return }
            #else
            guard let gesture = gesture as? UIGestureRecognizer, let map = gesture.view as? MKMapView else { return }
            #endif
            let coordinate = map.convert(gesture.location(in: map), toCoordinateFrom: map)
            guard let cell = cellFor(coordinate, size: size, backend: binned.backend) else { return onSelect(nil) }
            onSelect(binned.cells[cell])
        }
    }
}
