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
    /// Apple's street map when true; otherwise the bundled offline base map,
    /// and MapKit fetches no tiles.
    let appleMap: Bool
    /// Bumped to ask the map to fit all cells again.
    let fitToken: Int
    let onSelect: (CellSummary?) -> Void

    static let levels = 6

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

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
        return map
    }

    private func update(_ map: MKMapView, _ context: Context) {
        let coordinator = context.coordinator
        coordinator.binned = binned
        coordinator.size = size
        coordinator.onSelect = onSelect
        setBase(map, coordinator)
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
            let share = log(Double(binned.value(cell)) + 1) / log(Double(top) + 1)
            let level = min(Self.levels - 1, Int(share * Double(Self.levels)))
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

        if coordinator.fittedToken != fitToken {
            coordinator.fittedToken = fitToken
            let rect = coordinator.hexOverlays.reduce(MKMapRect.null) { $0.union($1.boundingMapRect) }
            if !rect.isNull {
                #if os(macOS)
                let padding = NSEdgeInsets(top: 40, left: 40, bottom: 40, right: 40)
                #else
                let padding = UIEdgeInsets(top: 40, left: 40, bottom: 40, right: 40)
                #endif
                map.setVisibleMapRect(rect, edgePadding: padding, animated: true)
            }
        }
    }

    /// Switches between Apple's map and the bundled base map when the toggle changes.
    private func setBase(_ map: MKMapView, _ coordinator: Coordinator) {
        guard coordinator.appleMap != appleMap else { return }
        coordinator.appleMap = appleMap
        map.removeOverlays(coordinator.baseOverlays)
        coordinator.baseOverlays = []
        coordinator.places = nil
        if appleMap {
            map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .realistic)
            map.pointOfInterestFilter = .includingAll
            return
        }
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
            guard let map, let coordinator, coordinator.appleMap == false,
                  coordinator.baseOverlays.count == 1 else { return }
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
        }
    }

    final class ShadedCells: MKMultiPolygon {
        var level = 0
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var binned = Binned()
        var size = CellSize.r7
        var fittedToken = -1
        var appleMap: Bool?
        var hexOverlays: [MKOverlay] = []
        var baseOverlays: [MKOverlay] = []
        /// The place-name overlay, kept on top of the cells.
        var places: MKOverlay?
        var onSelect: (CellSummary?) -> Void

        init(onSelect: @escaping (CellSummary?) -> Void) { self.onSelect = onSelect }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let base = basemapRenderer(for: overlay) { return base }
            guard let cells = overlay as? ShadedCells else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKMultiPolygonRenderer(multiPolygon: cells)
            let alpha = 0.15 + 0.7 * Double(cells.level + 1) / Double(HexMapView.levels)
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
