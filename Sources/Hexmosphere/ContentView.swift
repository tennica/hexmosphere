// SPDX-License-Identifier: Apache-2.0
// Controls for choosing photos and cell size, the map, and a summary.

import PhotosUI
import SwiftUI

struct ContentView: View {
    @State private var samples: [Sample] = []
    @State private var tally = ImportTally()
    @State private var picked: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var busy = false
    @State private var size = CellSize.r9
    /// Off by default: the bundled base map, and no map tiles fetched from Apple.
    @State private var appleMap = false
    @State private var fitToken = 0
    @State private var selected: CellSummary?
    /// Recomputed off the main thread when the photos or the cell size change,
    /// so a whole library doesn't stall every redraw.
    @State private var binned = Binned()
    @State private var libraryProgress: (Int, Int)?
    @State private var libraryError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                PhotosPicker(selection: $picked, matching: .any(of: [.images, .videos]),
                             preferredItemEncoding: .current) {
                    Label("Choose Photos…", systemImage: "photo.on.rectangle")
                }
                Button { importing = true } label: { Label("Open Files…", systemImage: "folder") }
                #if os(iOS)
                Button { Task { await useLibrary() } } label: { Label("Whole Library…", systemImage: "photo.stack") }
                    .help("Read where every photo in your library was taken. Asks for Photos access.")
                #endif
                Button("Clear") { samples = []; tally = ImportTally(); selected = nil; libraryError = nil }
                    .disabled(samples.isEmpty && tally.chosen == 0)
                Divider().frame(height: 20)
                Picker("Cell size", selection: $size) {
                    ForEach(CellSize.allCases) { Text($0.across).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Toggle("Apple map", isOn: $appleMap)
                    .help("Show Apple's street map. This fetches map tiles from Apple for the areas you view.")
                Button("Fit all") { fitToken += 1 }
                Spacer()
            }
            .padding(10)

            ZStack(alignment: .bottomLeading) {
                HexMapView(binned: binned, size: size, appleMap: appleMap, fitToken: fitToken) { selected = $0 }
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
        }
        .onChange(of: picked) {
            let items = picked
            guard !items.isEmpty else { return }
            Task { await add { await readSamples(picked: items) }; picked = [] }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image, .movie, .folder],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { await add { await readSamples(files: urls) } }
        }
        .onChange(of: size) { selected = nil; rebin() }
        .onChange(of: samples.count) { rebin() }
    }

    private var progressText: String {
        guard let (done, total) = libraryProgress else { return "Reading locations…" }
        return "Reading the library… \(done.formatted()) of \(total.formatted())"
    }

    private func rebin() {
        let samples = samples, size = size
        Task {
            let result = await Task.detached(priority: .userInitiated) { bin(samples, size: size) }.value
            if size == self.size { binned = result }
        }
    }

    #if os(iOS)
    /// Replaces whatever was chosen with every photo in the library.
    private func useLibrary() async {
        busy = true
        libraryError = nil
        libraryProgress = (0, 0)
        defer { busy = false; libraryProgress = nil }
        do {
            let (found, counts) = try await readLibrary { done, total in libraryProgress = (done, total) }
            samples = found
            tally = counts
            selected = nil
            fitToken += 1
        } catch {
            libraryError = error.localizedDescription
        }
    }
    #endif

    private func add(_ read: () async -> ([Sample], ImportTally)) async {
        busy = true
        let (found, more) = await read()
        samples += found
        tally.chosen += more.chosen
        tally.withoutLocation += more.withoutLocation
        tally.unreadable += more.unreadable
        busy = false
        fitToken += 1
    }

    private func summary(_ binned: Binned) -> String {
        if let libraryError { return libraryError }
        guard tally.chosen > 0 else {
            let start = "Choose photos or open a folder of exported photos. Only what you choose is read, and nothing leaves this device."
            return appleMap ? start : start + " " + basemapCredit
        }
        var parts = [
            "\(tally.chosen) chosen",
            "\(samples.count) with a location",
            "\(binned.cells.count) hexagons at \(size.label)",
        ]
        if tally.withoutLocation > 0 { parts.append("\(tally.withoutLocation) without a location") }
        if tally.unreadable > 0 { parts.append("\(tally.unreadable) couldn't be read") }
        if binned.tooCoarse > 0 {
            parts.append("\(binned.tooCoarse) left out: position not known well enough for this size")
        }
        parts.append(h3Backend)
        if !appleMap { parts.append(basemapCredit) }
        return parts.joined(separator: " · ") + ". Click a hexagon for details."
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
