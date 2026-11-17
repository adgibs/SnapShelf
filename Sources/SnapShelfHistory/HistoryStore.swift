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
    /// Captures that are still on screen (on the shelf, pinned, being annotated). Their files are never
    /// pruned, so a thumbnail left out for days can still be dragged.
    public var isInUse: ((UUID) -> Bool)?
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

    /// Moves a finished recording (MP4 or GIF) into history, with `poster` as its thumbnail.
    public func importFile(at source: URL, poster: CGImage, pixelWidth: Int, pixelHeight: Int, scale: CGFloat, mode: String, pattern: String, date: Date = Date()) throws -> CaptureItem {
        let id = UUID()
        let folder = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        let thumbFolder = folder.appendingPathComponent(".thumb", isDirectory: true)
        try fileManager.createDirectory(at: thumbFolder, withIntermediateDirectories: true)
        let base = FileNamer.baseName(pattern: pattern, date: date, mode: mode, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        let fileURL = folder.appendingPathComponent("\(base).\(source.pathExtension)")
        let thumbURL = thumbFolder.appendingPathComponent("thumb.png")
        do {
            try fileManager.moveItem(at: source, to: fileURL)
            let thumb = ImageCodec.thumbnail(of: poster, maxPixel: HistoryStore.thumbnailMaxPixel) ?? poster
            try ImageCodec.write(thumb, to: thumbURL, format: .png)
        } catch {
            try? fileManager.removeItem(at: folder)
            throw error
        }
        return CaptureItem(
            id: id, date: date, mode: mode, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
            scale: Double(scale), fileURL: fileURL, thumbnailURL: thumbURL
        )
    }

    /// Adds a written capture to the front of history and prunes anything past the limit.
    public func insert(_ item: CaptureItem) {
        var updated = items
        updated.insert(item, at: 0)
        // Drop the oldest captures past the limit, skipping any still in use.
        var index = updated.count - 1
        while updated.count > limit, index >= 1 {
            if isInUse?(updated[index].id) != true {
                try? fileManager.removeItem(at: folderURL(for: updated[index]))
                updated.remove(at: index)
            }
            index -= 1
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

    /// Deletes captures older than `days` days, except any still in use. 0 or less does nothing.
    /// Returns how many were removed.
    @discardableResult
    public func removeExpired(days: Int, now: Date = Date()) -> Int {
        guard days > 0 else { return 0 }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let expired = items.filter { $0.date < cutoff && isInUse?($0.id) != true }
        guard !expired.isEmpty else { return 0 }
        for item in expired { try? fileManager.removeItem(at: folderURL(for: item)) }
        let ids = Set(expired.map(\.id))
        items.removeAll { ids.contains($0.id) }
        persist()
        return expired.count
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
        let stored = (try? Data(contentsOf: indexURL)).flatMap { try? JSONDecoder().decode([CaptureItem].self, from: $0) } ?? []
        // Paths are rebuilt from this directory, so history survives a moved or renamed home folder.
        let rerooted = stored.map { item -> CaptureItem in
            let folder = folderURL(for: item)
            return CaptureItem(
                id: item.id, date: item.date, mode: item.mode, pixelWidth: item.pixelWidth, pixelHeight: item.pixelHeight,
                scale: item.scale, fileURL: folder.appendingPathComponent(item.fileURL.lastPathComponent),
                thumbnailURL: folder.appendingPathComponent(".thumb/thumb.png")
            )
        }
        // Entries whose file has gone are dropped.
        items = Array(rerooted.filter { fileManager.fileExists(atPath: $0.fileURL.path) }.prefix(limit))
        if items != stored { persist() }
        removeOrphans()
    }

    /// Deletes capture folders the index does not know about: left by a crash between writing the files
    /// and recording them, by a lost index, or by entries dropped above. Without this they would stay forever.
    private func removeOrphans() {
        let known = Set(items.map { $0.id.uuidString })
        let contents = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for url in contents where UUID(uuidString: url.lastPathComponent) != nil && !known.contains(url.lastPathComponent) {
            try? fileManager.removeItem(at: url)
        }
    }

    /// Bytes used by history on disk.
    public var diskUsage: Int {
        guard let walker = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total = 0
        for case let url as URL in walker {
            total += (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return total
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
