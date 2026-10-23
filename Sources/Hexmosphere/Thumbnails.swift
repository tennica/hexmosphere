// SPDX-License-Identifier: Apache-2.0
// Small previews of the photos in a selected cell, newest first. They come from
// PhotoKit under the same Photos access the app already has, are kept only in
// memory, and are never downloaded from iCloud: a photo whose thumbnail isn't on
// this device shows a placeholder instead.

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
                    }
                }
            }
            .frame(height: Self.side)
            .task { await load() }
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
