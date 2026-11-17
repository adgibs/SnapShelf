import Combine
import CoreGraphics
import Foundation
import SnapShelfKit

/// Keeps the most recent captures on disk: `<directory>/<uuid>/<name>.png` plus a thumbnail, and an index.
public final class HistoryStore: ObservableObject {
    /// Newest first.
    @Published public private(set) var items: [CaptureItem] = []

    public let directory: URL
    public let limit: Int
    private let fileManager: FileManager
    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    public static let thumbnailMaxPixel = 480

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SnapShelf/History", isDirectory: true)
    }

    public init(directory: URL = HistoryStore.defaultDirectory, limit: Int = 20, fileManager: FileManager = .default) {
        self.directory = directory
        self.limit = limit
        self.fileManager = fileManager
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    public var mostRecent: CaptureItem? { items.first }

    /// Writes the image files for a new capture. Touches only the disk, so it can run off the main thread.
    public func write(image: CGImage, scale: CGFloat, mode: String, pattern: String, date: Date = Date()) throws -> CaptureItem {
        let id = UUID()
        let folder = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = FileNamer.baseName(pattern: pattern, date: date, mode: mode, pixelWidth: image.width, pixelHeight: image.height)
        let fileURL = folder.appendingPathComponent("\(base).png")
        // Kept out of the way in a subfolder so it is never mistaken for the capture itself.
        let thumbFolder = folder.appendingPathComponent(".thumb", isDirectory: true)
        try fileManager.createDirectory(at: thumbFolder, withIntermediateDirectories: true)
        let thumbURL = thumbFolder.appendingPathComponent("thumb.png")
        do {
            try ImageCodec.write(image, to: fileURL, format: .png, scale: scale)
            let thumb = ImageCodec.thumbnail(of: image, maxPixel: HistoryStore.thumbnailMaxPixel) ?? image
            try ImageCodec.write(thumb, to: thumbURL, format: .png)
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
        return CaptureItem(
            id: id, date: date, mode: mode, pixelWidth: image.width, pixelHeight: image.height,
            scale: Double(scale), fileURL: fileURL, thumbnailURL: thumbURL
        )
    }

    /// Adds a written capture to the front of history and prunes anything past the limit.
    public func insert(_ item: CaptureItem) {
        var updated = items
        updated.insert(item, at: 0)
        while updated.count > limit {
            let removed = updated.removeLast()
            try? fileManager.removeItem(at: folderURL(for: removed))
        }
        items = updated
        persist()
    }

    @discardableResult
    public func add(image: CGImage, scale: CGFloat, mode: String, pattern: String, date: Date = Date()) throws -> CaptureItem {
        let item = try write(image: image, scale: scale, mode: mode, pattern: pattern, date: date)
        insert(item)
        return item
    }

    public func remove(_ item: CaptureItem) {
        try? fileManager.removeItem(at: folderURL(for: item))
        items.removeAll { $0.id == item.id }
        persist()
    }

    public func clear() {
        for item in items { try? fileManager.removeItem(at: folderURL(for: item)) }
        items = []
        persist()
    }

    private func folderURL(for item: CaptureItem) -> URL {
        directory.appendingPathComponent(item.id.uuidString, isDirectory: true)
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let stored = try? JSONDecoder().decode([CaptureItem].self, from: data) else { return }
        // Entries whose file has gone are dropped.
        items = Array(stored.filter { fileManager.fileExists(atPath: $0.fileURL.path) }.prefix(limit))
        if items.count != stored.count { persist() }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
