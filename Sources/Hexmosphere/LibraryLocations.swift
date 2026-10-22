// SPDX-License-Identifier: Apache-2.0
// Read where and when every photo and video in the Photos library was
// taken, from the library's own metadata. No image is opened or downloaded, so a
// library of tens of thousands of items takes seconds. Needs Photos access (Full,
// or Limited to a chosen subset); the app never writes to the library.

import CoreLocation
import Foundation
import Photos

/// How many items were read, and how many had no usable location.
struct ImportTally {
    var chosen = 0
    var withoutLocation = 0
}

enum LibraryAccessError: LocalizedError {
    case denied

    var errorDescription: String? {
        #if os(macOS)
        "Photos access wasn't granted. Allow it in System Settings → Privacy & Security → Photos → Hexmosphere."
        #else
        "Photos access wasn't granted. Allow it in Settings → Privacy & Security → Photos → Hexmosphere."
        #endif
    }
}

/// Reads every asset's location, date and accuracy. `progress` is called on the
/// main thread with (read so far, total).
func readLibrary(progress: @escaping @MainActor (Int, Int) -> Void) async throws -> ([Sample], ImportTally) {
    let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    guard status == .authorized || status == .limited else { throw LibraryAccessError.denied }

    return await Task.detached(priority: .userInitiated) {
        let options = PHFetchOptions()
        options.includeAssetSourceTypes = [.typeUserLibrary, .typeCloudShared, .typeiTunesSynced]
        let assets = PHAsset.fetchAssets(with: options)
        let total = assets.count
        var samples: [Sample] = []
        samples.reserveCapacity(total)
        var tally = ImportTally(chosen: total)
        let batch = 2_000
        var start = 0
        while start < total {
            let end = min(start + batch, total)
            assets.enumerateObjects(at: IndexSet(start..<end), options: []) { asset, _, _ in
                guard let location = asset.location, let date = asset.creationDate,
                      CLLocationCoordinate2DIsValid(location.coordinate),
                      location.coordinate.latitude != 0 || location.coordinate.longitude != 0
                else {
                    tally.withoutLocation += 1
                    return
                }
                let accuracy = location.horizontalAccuracy > 0 ? location.horizontalAccuracy : nil
                samples.append(Sample(coordinate: location.coordinate, date: date, accuracy: accuracy))
            }
            start = end
            let done = end
            await progress(done, total)
        }
        return (samples, tally)
    }.value
}
