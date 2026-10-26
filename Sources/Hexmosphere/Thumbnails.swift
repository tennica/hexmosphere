// SPDX-License-Identifier: Apache-2.0
// Small previews of the photos in a selected cell, newest first; tap one to see it
// larger. Both come from PhotoKit under the same Photos access the app already has, at
// sizes it renders for the app (the larger one PhotoView.pixels on its long side, never
// the original), are kept only in memory, and are never downloaded from iCloud: a photo
// that isn't on this device shows a placeholder instead.

import Photos
import SwiftUI

#if os(macOS)
import AppKit
private typealias PlatformImage = NSImage
private extension Image {
    init(platformImage: NSImage) { self.init(nsImage: platformImage) }
}
#else
import UIKit
private typealias PlatformImage = UIImage
private extension Image {
    init(platformImage: UIImage) { self.init(uiImage: platformImage) }
}
#endif

struct ThumbnailStrip: View {
    let assetIDs: [String]

    /// The most previews one cell shows.
    static let limit = 24
    static let side: CGFloat = 64

    @State private var images: [String: PlatformImage] = [:]
    @State private var missing: Set<String> = []
    @State private var enlarged: Enlarged?

    struct Enlarged: Identifiable {
        let id: String
    }

    var body: some View {
        if !assetIDs.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 4) {
                    ForEach(assetIDs, id: \.self) { id in
                        ZStack {
                            RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                            if let image = images[id] {
                                Image(platformImage: image)
                                    .resizable()
                                    .scaledToFill()
                            } else if missing.contains(id) {
                                Image(systemName: "icloud")
                                    .foregroundStyle(.secondary)
                                    .help("Not on this device; Hexmosphere doesn't download from iCloud.")
                            }
                        }
                        .frame(width: Self.side, height: Self.side)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                        .onTapGesture { if !missing.contains(id) { enlarged = Enlarged(id: id) } }
                    }
                }
            }
            .frame(height: Self.side)
            .task { await load() }
            .sheet(item: $enlarged) { photo in
                PhotoView(assetID: photo.id, preview: images[photo.id])
            }
        }
    }

    private func load() async {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil)
        var found: [PHAsset] = []
        assets.enumerateObjects { asset, _, _ in found.append(asset) }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        let pixels = Self.side * 2
        for asset in found {
            let id = asset.localIdentifier
            PHImageManager.default().requestImage(
                for: asset, targetSize: CGSize(width: pixels, height: pixels),
                contentMode: .aspectFill, options: options
            ) { image, info in
                DispatchQueue.main.async {
                    if let image {
                        images[id] = image
                    } else if (info?[PHImageResultIsInCloudKey] as? Bool) == true || info?[PHImageErrorKey] != nil {
                        missing.insert(id)
                    }
                }
            }
        }
        // Identifiers the library no longer has (deleted since the read).
        let known = Set(found.map(\.localIdentifier))
        missing.formUnion(assetIDs.filter { !known.contains($0) })
    }
}

/// One photo, larger: a rendition PhotoKit makes at `pixels` on the long side, not the
/// original. Shown over the map until closed, and not kept after.
struct PhotoView: View {
    let assetID: String
    /// The thumbnail already loaded, shown until (or instead of) the larger one.
    fileprivate let preview: PlatformImage?

    static let pixels: CGFloat = 1024

    @State private var image: PlatformImage?
    @State private var date: Date?
    @State private var note: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                if let date {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            if let shown = image ?? preview {
                Image(platformImage: shown)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let note {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 720, minHeight: 400, idealHeight: 620)
        #endif
        .task { load() }
    }

    private func load() {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else {
            note = "This photo is no longer in the library."
            return
        }
        date = asset.creationDate
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .highQualityFormat
        // Exactly the size asked for: .fast may hand back something larger.
        options.resizeMode = .exact
        PHImageManager.default().requestImage(
            for: asset, targetSize: CGSize(width: Self.pixels, height: Self.pixels),
            contentMode: .aspectFit, options: options
        ) { result, info in
            DispatchQueue.main.async {
                if let result {
                    image = result
                } else {
                    note = "A larger copy isn't on this device; Hexmosphere doesn't download from iCloud."
                }
            }
        }
    }
}
