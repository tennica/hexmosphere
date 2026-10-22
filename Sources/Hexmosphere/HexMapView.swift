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
    let shading: Shading
    let size: CellSize
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
        map.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .realistic)
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
        map.removeOverlays(map.overlays)

        let values = binned.cells.values.map { binned.value($0, shading) }
        guard let top = values.max(), top > 0 else { return }
        // Log scale, like the solstone prototype: a few very busy cells
        // shouldn't wash out everything else.
        var buckets = Array(repeating: [MKPolygon](), count: Self.levels)
        for cell in binned.cells.values {
            let corners = outline(of: cell.id)
            guard corners.count >= 3 else { continue }
            let share = log(Double(binned.value(cell, shading)) + 1) / log(Double(top) + 1)
            let level = min(Self.levels - 1, Int(share * Double(Self.levels)))
            buckets[level].append(MKPolygon(coordinates: corners, count: corners.count))
        }
        for (level, polygons) in buckets.enumerated() where !polygons.isEmpty {
            let overlay = ShadedCells(polygons)
            overlay.level = level
            map.addOverlay(overlay, level: .aboveRoads)
        }

        if coordinator.fittedToken != fitToken {
            coordinator.fittedToken = fitToken
            let rect = map.overlays.reduce(MKMapRect.null) { $0.union($1.boundingMapRect) }
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

    final class ShadedCells: MKMultiPolygon {
        var level = 0
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var binned = Binned()
        var size = CellSize.r9
        var fittedToken = -1
        var onSelect: (CellSummary?) -> Void

        init(onSelect: @escaping (CellSummary?) -> Void) { self.onSelect = onSelect }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
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
            guard let cell = cellFor(coordinate, size: size) else { return onSelect(nil) }
            onSelect(binned.cells[cell])
        }
    }
}
