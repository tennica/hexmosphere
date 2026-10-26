// SPDX-License-Identifier: Apache-2.0
// The toolbar (library, cell size, H3 backend, base map), the map, and a summary.

import SwiftUI

struct ContentView: View {
    @State private var samples: [Sample] = []
    @State private var tally = ImportTally()
    @State private var busy = false
    @State private var size = CellSize.r7
    @State private var backend = H3Backend.h3o
    @State private var selected: CellSummary?
    /// Recomputed off the main thread when the photos or the cell size change,
    /// so a whole library doesn't stall every redraw.
    @State private var binned = Binned()
    /// How long the last library read and the last binning took, for the summary line.
    @State private var readTime: Duration?
    @State private var binTime: Duration?
    @State private var libraryProgress: (Int, Int)?
    @State private var libraryError: String?
    private let visible = HexMapView.VisibleArea()
    @State private var export: TiledExport?
    @State private var exporting = false
    /// What the last export did, shown under the summary.
    @State private var exportNote: String?
    /// The hexagon you're in, when Where I Am is on. Never stored or exported.
    @State private var here = HereTracker()
    /// The vintage layer shown over the land, if any. Not remembered between launches.
    @State private var vintage: VintageLayer?

    var body: some View {
        VStack(spacing: 0) {
            // The full toolbar where it fits (Mac, iPad). On an iPhone the same
            // controls sit close together, with icon buttons and, if still too
            // wide, the cell size as a drop-down.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    toolbarControls
                    Spacer()
                    exportButton
                }
                compactToolbar { sizePicker.pickerStyle(.segmented).fixedSize() }
                compactToolbar { sizePicker.pickerStyle(.menu).fixedSize() }
            }
            .padding(10)

            ZStack(alignment: .bottomLeading) {
                HexMapView(binned: binned, size: size, onSelect: { selected = $0 }, visible: visible,
                           here: here.cell, hereTrip: here.trip, follow: here.driving, vintage: vintage)
                if let selected {
                    CellCard(cell: selected).padding(12)
                }
                if busy {
                    ProgressView(progressText).padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            // A panel of its own under the map, with room to read the counts
            // and timings while building up places.
            VStack(alignment: .leading, spacing: 8) {
                // The base map's credit on a line of its own (ODbL asks for it).
                Text(vintage.map { "\(basemapCredit) · \($0.credit)" } ?? basemapCredit)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(summary(binned))
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                if here.on {
                    Text(hereText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if let exportNote {
                    Text(exportNote)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                RoadTimes()
            }
            .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
        .fileExporter(isPresented: $exporting, document: export?.document, contentType: .folder,
                      defaultFilename: export?.suggestedName) { result in
            switch result {
            case .success(let url):
                guard let export else { return }
                var note = "Exported \(export.exported.formatted()) hexagons to \(url.lastPathComponent)"
                if export.leftOut > 0 {
                    note += "; \(export.leftOut.formatted()) left out, too far from the centre for H3's local grid"
                }
                exportNote = note + "."
            case .failure(let error):
                exportNote = "Export failed: \(error.localizedDescription)"
            }
        }
        .onChange(of: size) { selected = nil; rebin(); here.use(size: size, backend: backend) }
        .onChange(of: backend) { selected = nil; rebin(); here.use(size: size, backend: backend) }
        .onChange(of: samples.count) { rebin() }
        // For testing: launching with -vintage <layer id> starts with that layer on, and
        // -drive <route id> (e.g. route-66) starts that demo drive.
        .task {
            if let id = UserDefaults.standard.string(forKey: "vintage") {
                vintage = VintageLayer.all.first { $0.id == id }
            }
            if let id = UserDefaults.standard.string(forKey: "drive"), let route = DemoRoute.all.first(where: { $0.id == id }) {
                here.drive(route, size: size, backend: backend)
            }
        }
    }

    @ViewBuilder private var toolbarControls: some View {
        libraryButton
        clearButton
        Divider().frame(height: 20)
        sizePicker.pickerStyle(.segmented).fixedSize()
        backendPicker.pickerStyle(.segmented).fixedSize()
        Divider().frame(height: 20)
        hereButton
        driveButton
        vintageMenu
    }

    private func clear() {
        samples = []
        tally = ImportTally()
        selected = nil
        libraryError = nil
    }

    private var libraryButton: some View {
        // The whole library is the only source, on every device.
        Button { Task { await useLibrary() } } label: { Label("Whole Library…", systemImage: "photo.stack") }
            .help("Read where every photo in your library was taken. Asks for Photos access.")
    }

    private var clearButton: some View {
        Button("Clear") { clear() }
            .disabled(samples.isEmpty && tally.chosen == 0)
    }

    private var sizePicker: some View {
        Picker("Cell size", selection: $size) {
            ForEach(CellSize.allCases) { Text($0.across(backend)).tag($0) }
        }
    }

    private var backendPicker: some View {
        Picker("H3", selection: $backend) {
            ForEach(H3Backend.allCases) { Text($0.rawValue).tag($0) }
        }
        .help("Which H3 library makes the cells: h3o, an independent Rust implementation, or Uber's H3 C, the reference. They agree on every cell and edge length.")
    }

    /// The toolbar for narrow screens: the same controls, packed together.
    private func compactToolbar(@ViewBuilder size: () -> some View) -> some View {
        HStack(spacing: 8) {
            libraryButton.labelStyle(.iconOnly)
            Button { clear() } label: { Label("Clear", systemImage: "xmark.circle") }
                .labelStyle(.iconOnly)
                .disabled(samples.isEmpty && tally.chosen == 0)
            size()
            backendPicker.pickerStyle(.segmented).fixedSize()
            hereButton.labelStyle(.iconOnly)
            driveButton.labelStyle(.iconOnly)
            vintageMenu.labelStyle(.iconOnly)
            exportButton.labelStyle(.iconOnly)
        }
        .frame(maxWidth: .infinity)
    }

    private var hereButton: some View {
        Toggle(isOn: Binding(get: { here.on && !here.driving }, set: { $0 ? here.start(size: size, backend: backend) : here.stop() })) {
            Label("Where I Am", systemImage: here.on && !here.driving ? "location.fill" : "location")
        }
        .toggleStyle(.button)
        .help("Outline the hexagon you're in. Asks for your location while the app is in use. Your position is never saved, exported or sent.")
    }

    /// Old maps or early satellite imagery over the land, when the app has any bundled.
    @ViewBuilder private var vintageMenu: some View {
        if !VintageLayer.all.isEmpty {
            Menu {
                Picker("Vintage", selection: $vintage) {
                    Text("None").tag(VintageLayer?.none)
                    ForEach(VintageLayer.all) { layer in
                        Text(layer.title).tag(VintageLayer?.some(layer))
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Vintage", systemImage: vintage == nil ? "clock.arrow.circlepath" : "clock.fill")
            }
            .help("Show old maps or early satellite imagery along a route, under the hexagons.")
        }
    }

    /// Where I Am fed by a demo drive instead of your location.
    private var driveButton: some View {
        Menu {
            ForEach(DemoRoute.all) { route in
                Button { here.drive(route, size: size, backend: backend) } label: {
                    if here.route?.id == route.id {
                        Label(route.title, systemImage: "checkmark")
                    } else {
                        Text(route.title)
                    }
                }
            }
            if here.driving {
                Divider()
                Button("Stop Driving") { here.stop() }
            }
        } label: {
            Label("Demo Drive", systemImage: here.driving ? "car.fill" : "car")
        }
        .help("Try Where I Am on a simulated drive along a real road, in place of your location.")
    }

    /// The line under the summary while Where I Am is on.
    private var hereText: String {
        if let note = here.note { return note }
        guard let cell = here.cell else { return "Finding where you are…" }
        let photos = binned.cells[cell].map { " · \($0.days.count) days and \($0.samples) photos here" } ?? " · no photos here yet"
        if let route = here.route {
            let pace = route.times == 1 ? "real time" : "\(route.times.formatted())× real time"
            return "Demo drive, \(route.title) at \(pace): in the outlined hexagon, \(cellName(cell))\(photos)."
        }
        return "You're in the outlined hexagon, \(cellName(cell))\(photos). It isn't saved or exported."
    }

    private var exportButton: some View {
        Button { exportTiled() } label: { Label("Export Tiled…", systemImage: "square.and.arrow.up") }
            .disabled(binned.cells.isEmpty)
            .help("Save the hexagons in view as a Tiled map (a folder with hexmosphere.tmj), with each hexagon as a place to name.")
    }

    private var progressText: String {
        guard let (done, total) = libraryProgress else { return "Reading locations…" }
        return "Reading the library… \(done.formatted()) of \(total.formatted())"
    }

    private func seconds(_ duration: Duration) -> String {
        let value = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return value < 1 ? String(format: "%.0f ms", value * 1000) : String(format: "%.2f s", value)
    }

    private func exportTiled() {
        do {
            export = try TiledExport(binned: binned, size: binned.size, visible: visible.rect)
            exporting = true
        } catch {
            exportNote = error.localizedDescription
        }
    }

    private func rebin() {
        let samples = samples, size = size, backend = backend
        Task {
            let (result, took) = await Task.detached(priority: .userInitiated) {
                let clock = ContinuousClock()
                var result = Binned()
                let took = clock.measure { result = bin(samples, size: size, backend: backend) }
                return (result, took)
            }.value
            if size == self.size && backend == self.backend {
                binned = result
                binTime = took
            }
        }
    }

    /// Replaces whatever was shown with every photo in the library.
    private func useLibrary() async {
        busy = true
        libraryError = nil
        libraryProgress = (0, 0)
        defer { busy = false; libraryProgress = nil }
        do {
            let started = ContinuousClock.now
            let (found, counts) = try await readLibrary { done, total in libraryProgress = (done, total) }
            readTime = ContinuousClock.now - started
            samples = found
            tally = counts
            selected = nil
        } catch {
            libraryError = error.localizedDescription
        }
    }

    private func summary(_ binned: Binned) -> String {
        if let libraryError { return libraryError }
        guard tally.chosen > 0 else {
            let start = "Use Whole Library to read where your photos were taken. Nothing leaves this device unless you export it."
            return start
        }
        var parts = [
            "\(tally.chosen) in the library",
            "\(samples.count) with a location",
            "\(binned.cells.count) hexagons at \(size.label(backend))",
        ]
        if tally.withoutLocation > 0 { parts.append("\(tally.withoutLocation) without a location") }
        if binned.tooCoarse > 0 {
            parts.append("\(binned.tooCoarse) left out: position not known well enough for this size")
        }
        if let readTime { parts.append("library read in \(seconds(readTime))") }
        if let binTime { parts.append("binned in \(seconds(binTime)) with \(backend.name)") } else { parts.append(backend.name) }
        #if os(macOS)
        return parts.joined(separator: " · ") + ". Click a hexagon for details."
        #else
        return parts.joined(separator: " · ") + ". Tap a hexagon for details."
        #endif
    }
}

/// Road load and draw times, on a line of their own: they change while tiles
/// draw, and only this view should redraw when they do.
struct RoadTimes: View {
    private let stats = RoadStats.shared

    var body: some View {
        if let loadTime = stats.loadTime {
            Text(text(loadTime))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func text(_ loadTime: Duration) -> String {
        var text = "\(stats.roads.formatted()) roads loaded in \(milliseconds(loadTime))"
        if stats.tiles > 0 {
            text += " · slowest of \(stats.tiles.formatted()) road tiles \(milliseconds(stats.slowestTile)) (up to \(stats.busiestTile.formatted()) pieces)"
        }
        return text
    }

    private func milliseconds(_ duration: Duration) -> String {
        let value = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        return String(format: "%.1f ms", value)
    }
}

struct CellCard: View {
    let cell: CellSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(cellName(cell.id)).font(.caption.monospaced()).foregroundStyle(.secondary)
            Text("\(cell.days.count) days · \(cell.samples) photos")
            Text("\(cell.first.formatted(date: .abbreviated, time: .omitted)) – \(cell.last.formatted(date: .abbreviated, time: .omitted))")
                .foregroundStyle(.secondary)
            ThumbnailStrip(assetIDs: cell.photos.sorted { $0.date > $1.date }.prefix(ThumbnailStrip.limit).map(\.assetID))
                .id(cell.id)
        }
        .frame(maxWidth: 480, alignment: .leading)
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
