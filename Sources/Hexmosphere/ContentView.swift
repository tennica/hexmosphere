// SPDX-License-Identifier: Apache-2.0
// The toolbar (library, cell size, H3 backend, base map), the map, and a summary.

import SwiftUI

struct ContentView: View {
    @State private var samples: [Sample] = []
    @State private var tally = ImportTally()
    @State private var busy = false
    @State private var size = CellSize.r7
    @State private var backend = H3Backend.h3o
    /// Off by default: the bundled base map, and no map tiles fetched from Apple.
    @State private var appleMap = false
    @State private var selected: CellSummary?
    /// Recomputed off the main thread when the photos or the cell size change,
    /// so a whole library doesn't stall every redraw.
    @State private var binned = Binned()
    /// How long the last library read and the last binning took, for the summary line.
    @State private var readTime: Duration?
    @State private var binTime: Duration?
    @State private var libraryProgress: (Int, Int)?
    @State private var libraryError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                // The whole library is the only source, on Mac and iPad alike.
                Button { Task { await useLibrary() } } label: { Label("Whole Library…", systemImage: "photo.stack") }
                    .help("Read where every photo in your library was taken. Asks for Photos access.")
                Button("Clear") { samples = []; tally = ImportTally(); selected = nil; libraryError = nil }
                    .disabled(samples.isEmpty && tally.chosen == 0)
                Divider().frame(height: 20)
                Picker("Cell size", selection: $size) {
                    ForEach(CellSize.allCases) { Text($0.across(backend)).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Picker("H3", selection: $backend) {
                    ForEach(H3Backend.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .help("Which H3 library makes the cells: h3o, an independent Rust implementation, or Uber's H3 C, the reference. They agree on every cell and edge length.")
                Toggle("Apple map", isOn: $appleMap)
                    .help("Show Apple's street map. This fetches map tiles from Apple for the areas you view.")
                Spacer()
            }
            .padding(10)

            ZStack(alignment: .bottomLeading) {
                HexMapView(binned: binned, size: size, appleMap: appleMap) { selected = $0 }
                if let selected {
                    CellCard(cell: selected).padding(12)
                }
                if busy {
                    ProgressView(progressText).padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            Text(summary(binned))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
            if !appleMap {
                RoadTimes()
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
        }
        .onChange(of: size) { selected = nil; rebin() }
        .onChange(of: backend) { selected = nil; rebin() }
        .onChange(of: samples.count) { rebin() }
    }

    private var progressText: String {
        guard let (done, total) = libraryProgress else { return "Reading locations…" }
        return "Reading the library… \(done.formatted()) of \(total.formatted())"
    }

    private func seconds(_ duration: Duration) -> String {
        let value = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return value < 1 ? String(format: "%.0f ms", value * 1000) : String(format: "%.2f s", value)
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
            let start = "Use Whole Library to read where your photos were taken. Nothing leaves this device."
            return appleMap ? start : start + " " + basemapCredit
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
        if !appleMap { parts.append(basemapCredit) }
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
                .font(.caption)
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
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
