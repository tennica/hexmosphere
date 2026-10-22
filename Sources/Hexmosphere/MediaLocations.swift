// SPDX-License-Identifier: Apache-2.0
// Reads where and when a photo or video was taken from the file's own metadata:
// EXIF GPS for images (ImageIO), the ISO 6709 location for videos (AVFoundation).
// Works on files the owner picked, so the app never needs Photos library access.
// Not wired into the interface at the moment: both apps read the whole library
// (LibraryLocations.swift). Kept for bringing back per-photo picking.

import AVFoundation
import CoreLocation
import Foundation
import ImageIO
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ImportTally {
    var chosen = 0
    var withoutLocation = 0
    var unreadable = 0
}

/// A picked video, delivered by the picker as a temporary file.
struct PickedMovie: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "-" + received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMovie(url: copy)
        }
    }
}

/// Resumes a continuation once, whichever of the work or the timer finishes first.
private final class Once<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    /// Returns false if the continuation was already resumed, so the value came too late.
    @discardableResult
    func resume(_ continuation: CheckedContinuation<T?, Never>, _ value: T?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return false }
        done = true
        continuation.resume(returning: value)
        return true
    }
}

/// Runs `work`, giving up after `seconds` without waiting for it, so one stuck
/// picker item can't hang the import. A result that arrives after giving up is
/// passed to `late`, so it can be cleaned up instead of left behind.
private func withTimeout<T>(_ seconds: Double, late: @escaping @Sendable (T) -> Void = { _ in },
                            _ work: @escaping @Sendable () async -> T?) async -> T? {
    await withCheckedContinuation { continuation in
        let once = Once<T>()
        Task {
            let value = await work()
            if !once.resume(continuation, value), let value { late(value) }
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            once.resume(continuation, nil)
        }
    }
}

/// Copies one picked item to a temporary file. Photos come over as data (their
/// original bytes, metadata included); videos as files.
private func temporaryFile(for item: PhotosPickerItem) async -> URL? {
    let types = item.supportedContentTypes
    NSLog("Hexmosphere: picked item offers %@", types.map(\.identifier).joined(separator: ", "))
    if types.contains(where: { $0.conforms(to: .movie) }) {
        // A video copied after the time limit would otherwise stay in the temporary folder.
        return await withTimeout(30, late: { try? FileManager.default.removeItem(at: $0) }) {
            try? await item.loadTransferable(type: PickedMovie.self)?.url
        }
    }
    guard let data = await withTimeout(30, { try? await item.loadTransferable(type: Data.self) }) else {
        return nil
    }
    let ext = types.first(where: { $0.conforms(to: .image) })?.preferredFilenameExtension ?? "img"
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
    return (try? data.write(to: url)) == nil ? nil : url
}

/// Reads samples from items chosen in the Photos picker.
func readSamples(picked items: [PhotosPickerItem]) async -> ([Sample], ImportTally) {
    var found: [Sample] = []
    var tally = ImportTally(chosen: items.count)
    for item in items {
        guard let url = await temporaryFile(for: item) else {
            tally.unreadable += 1
            continue
        }
        defer { try? FileManager.default.removeItem(at: url) }
        if let sample = await sample(at: url) {
            found.append(sample)
        } else {
            tally.withoutLocation += 1
        }
    }
    return (found, tally)
}

/// Reads samples from files and folders chosen with the open panel.
func readSamples(files urls: [URL]) async -> ([Sample], ImportTally) {
    var found: [Sample] = []
    var tally = ImportTally()
    for url in urls {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        for file in mediaFiles(under: url) {
            tally.chosen += 1
            if let sample = await sample(at: file) {
                found.append(sample)
            } else {
                tally.withoutLocation += 1
            }
        }
    }
    return (found, tally)
}

private func mediaFiles(under url: URL) -> [URL] {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
    guard isDirectory.boolValue else { return [url] }
    let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.contentTypeKey],
                                                options: [.skipsHiddenFiles])
    var files: [URL] = []
    while let file = walker?.nextObject() as? URL {
        let type = (try? file.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        if let type, type.conforms(to: .image) || type.conforms(to: .movie) {
            files.append(file)
        }
    }
    return files
}

private func sample(at url: URL) async -> Sample? {
    let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
    if type?.conforms(to: .movie) == true {
        return await videoSample(at: url)
    }
    return imageSample(at: url)
}

private func imageSample(at url: URL) -> Sample? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any],
          var latitude = gps[kCGImagePropertyGPSLatitude] as? Double,
          var longitude = gps[kCGImagePropertyGPSLongitude] as? Double
    else { return nil }
    if (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" { latitude = -latitude }
    if (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" { longitude = -longitude }
    let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    guard CLLocationCoordinate2DIsValid(coordinate), latitude != 0 || longitude != 0 else { return nil }
    let accuracy = gps[kCGImagePropertyGPSHPositioningError] as? Double
    let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
    let date = exifDate(exif) ?? fileDate(url)
    return Sample(coordinate: coordinate, date: date, accuracy: accuracy)
}

/// EXIF DateTimeOriginal ("2026:10:21 18:52:03"), with its offset when present.
private func exifDate(_ exif: [CFString: Any]?) -> Date? {
    guard let text = exif?[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    if let offset = exif?[kCGImagePropertyExifOffsetTimeOriginal] as? String {
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ssxxx"
        if let date = formatter.date(from: text + offset) { return date }
    }
    formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
    return formatter.date(from: text)
}

private func videoSample(at url: URL) async -> Sample? {
    let asset = AVURLAsset(url: url)
    guard let metadata = try? await asset.load(.commonMetadata) else { return nil }
    let locations = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierLocation)
    guard let text = try? await locations.first?.load(.stringValue),
          let coordinate = iso6709(text)
    else { return nil }
    var date = fileDate(url)
    if let created = try? await asset.load(.creationDate), let value = try? await created.load(.dateValue) {
        date = value
    }
    return Sample(coordinate: coordinate, date: date, accuracy: nil)
}

/// Parses "+39.7392-104.9903+1609.344/" (ISO 6709) into a coordinate.
func iso6709(_ text: String) -> CLLocationCoordinate2D? {
    let pattern = #"^([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)"#
    guard let match = text.range(of: pattern, options: .regularExpression) else { return nil }
    let head = String(text[match])
    guard let split = head.dropFirst().firstIndex(where: { $0 == "+" || $0 == "-" }),
          let latitude = Double(head[..<split]), let longitude = Double(head[split...])
    else { return nil }
    let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
}

private func fileDate(_ url: URL) -> Date {
    (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? Date()
}
