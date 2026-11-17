import AppKit
import CoreGraphics
import XCTest
@testable import SnapShelfHistory
@testable import SnapShelfKit

func makeImage(width: Int, height: Int, alpha: Bool = true) -> CGImage {
    let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue
    )!
    ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
    return ctx.makeImage()!
}

func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("SnapShelfTests-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

final class ImageCodecTests: XCTestCase {
    func testPNGRoundTripKeepsPixelSizeAndSignature() throws {
        let data = try XCTUnwrap(ImageCodec.encode(makeImage(width: 640, height: 400), format: .png, scale: 2))
        XCTAssertEqual(Array(data.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let url = tempDirectory().appendingPathComponent("a.png")
        try data.write(to: url)
        XCTAssertEqual(ImageCodec.pixelSize(of: url), CGSize(width: 640, height: 400))
        let loaded = try XCTUnwrap(ImageCodec.load(url))
        XCTAssertEqual(loaded.width, 640)
        XCTAssertEqual(loaded.height, 400)
    }

    func testPNGRecordsRetinaDPI() throws {
        let url = tempDirectory().appendingPathComponent("a.png")
        try ImageCodec.write(makeImage(width: 100, height: 100), to: url, format: .png, scale: 2)
        let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        XCTAssertEqual((props[kCGImagePropertyDPIWidth] as? Double ?? 0).rounded(), 144)
    }

    func testPNGKeepsTransparency() throws {
        let url = tempDirectory().appendingPathComponent("a.png")
        try ImageCodec.write(makeImage(width: 20, height: 20), to: url, format: .png)
        let loaded = try XCTUnwrap(ImageCodec.load(url))
        XCTAssertFalse([.none, .noneSkipFirst, .noneSkipLast].contains(loaded.alphaInfo))
    }

    func testJPEGIsFlattenedAndHasSignature() throws {
        let data = try XCTUnwrap(ImageCodec.encode(makeImage(width: 64, height: 64), format: .jpeg))
        XCTAssertEqual(Array(data.prefix(2)), [0xFF, 0xD8])
        let flat = try XCTUnwrap(ImageCodec.flattened(makeImage(width: 4, height: 4)))
        XCTAssertEqual(flat.alphaInfo, .noneSkipLast)
        // The right half was transparent, so it becomes white.
        let bytes = try XCTUnwrap(flat.dataProvider?.data as Data?)
        let offset = 3 * 4 // pixel (3, 0)
        XCTAssertEqual([bytes[offset], bytes[offset + 1], bytes[offset + 2]], [255, 255, 255])
    }

    func testThumbnailScalesDownButNeverUp() throws {
        let thumb = try XCTUnwrap(ImageCodec.thumbnail(of: makeImage(width: 2000, height: 1000), maxPixel: 480))
        XCTAssertEqual(thumb.width, 480)
        XCTAssertEqual(thumb.height, 240)
        let small = try XCTUnwrap(ImageCodec.thumbnail(of: makeImage(width: 100, height: 50), maxPixel: 480))
        XCTAssertEqual(small.width, 100)
    }
}

final class FileNamerTests: XCTestCase {
    let date = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15 08:00:00 UTC
    let utc = TimeZone(identifier: "UTC")!

    func testTokens() {
        let name = FileNamer.baseName(
            pattern: "Shot {date} {time} {mode} {width}x{height}", date: date, mode: "area",
            pixelWidth: 800, pixelHeight: 600, timeZone: utc
        )
        XCTAssertEqual(name, "Shot 2027-01-15 08.00.00 area 800x600")
    }

    func testSanitisesPathCharactersAndEmptyPatterns() {
        XCTAssertEqual(FileNamer.baseName(pattern: "a/b:c", date: date, mode: "m", pixelWidth: 1, pixelHeight: 1), "a-b-c")
        XCTAssertEqual(FileNamer.baseName(pattern: "  ", date: date, mode: "m", pixelWidth: 1, pixelHeight: 1), "SnapShelf")
        XCTAssertEqual(FileNamer.baseName(pattern: "..hidden", date: date, mode: "m", pixelWidth: 1, pixelHeight: 1), "hidden")
    }

    func testUniqueURLAvoidsExistingFiles() throws {
        let dir = tempDirectory()
        let first = FileNamer.uniqueURL(directory: dir, baseName: "Shot", ext: "png")
        XCTAssertEqual(first.lastPathComponent, "Shot.png")
        try Data().write(to: first)
        let second = FileNamer.uniqueURL(directory: dir, baseName: "Shot", ext: "png")
        XCTAssertEqual(second.lastPathComponent, "Shot 2.png")
        try Data().write(to: second)
        XCTAssertEqual(FileNamer.uniqueURL(directory: dir, baseName: "Shot", ext: "png").lastPathComponent, "Shot 3.png")
    }
}

final class HistoryStoreTests: XCTestCase {
    func testAddWritesPNGAndThumbnail() throws {
        let store = HistoryStore(directory: tempDirectory())
        let item = try store.add(image: makeImage(width: 1200, height: 800), scale: 2, mode: "area", pattern: "Shot {width}")
        XCTAssertEqual(item.fileURL.lastPathComponent, "Shot 1200.png")
        XCTAssertEqual(ImageCodec.pixelSize(of: item.fileURL), CGSize(width: 1200, height: 800))
        XCTAssertEqual(ImageCodec.pixelSize(of: item.thumbnailURL), CGSize(width: 480, height: 320))
        XCTAssertEqual(store.items, [item])
        XCTAssertEqual(store.mostRecent, item)
    }

    func testNewestFirstAndPrunesPastLimit() throws {
        let store = HistoryStore(directory: tempDirectory(), limit: 3)
        var added: [CaptureItem] = []
        for i in 0..<5 {
            added.append(try store.add(image: makeImage(width: 10, height: 10), scale: 1, mode: "area", pattern: "n\(i)"))
        }
        XCTAssertEqual(store.items.map(\.baseName), ["n4", "n3", "n2"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: added[0].fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: added[1].fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: added[2].fileURL.path))
    }

    func testPersistsAcrossInstancesAndDropsMissingFiles() throws {
        let dir = tempDirectory()
        let store = HistoryStore(directory: dir)
        let a = try store.add(image: makeImage(width: 10, height: 10), scale: 1, mode: "area", pattern: "a")
        let b = try store.add(image: makeImage(width: 10, height: 10), scale: 1, mode: "area", pattern: "b")
        XCTAssertEqual(HistoryStore(directory: dir).items, [b, a])

        try FileManager.default.removeItem(at: a.fileURL)
        XCTAssertEqual(HistoryStore(directory: dir).items, [b])
    }

    func testRemoveAndClear() throws {
        let store = HistoryStore(directory: tempDirectory())
        let a = try store.add(image: makeImage(width: 10, height: 10), scale: 1, mode: "area", pattern: "a")
        let b = try store.add(image: makeImage(width: 10, height: 10), scale: 1, mode: "area", pattern: "b")
        store.remove(a)
        XCTAssertEqual(store.items, [b])
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.fileURL.path))
        store.clear()
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.fileURL.path))
    }
}

final class HistoryHousekeepingTests: XCTestCase {
    func testOrphanedFoldersAreRemovedAtLoad() throws {
        let dir = tempDirectory()
        let store = HistoryStore(directory: dir)
        let kept = try store.add(image: makeImage(width: 10, height: 10), scale: 1, mode: "area", pattern: "kept")
        // Files written but never recorded, as after a crash mid-capture.
        let orphan = try store.write(image: makeImage(width: 10, height: 10), scale: 1, mode: "area", pattern: "orphan")
        let unrelated = dir.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: unrelated)

        let reloaded = HistoryStore(directory: dir)
        XCTAssertEqual(reloaded.items.map(\.id), [kept.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.fileURL.deletingLastPathComponent().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.fileURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path), "only capture folders are swept")
    }

    func testLostIndexDoesNotLeaveFilesBehind() throws {
        let dir = tempDirectory()
        let store = HistoryStore(directory: dir)
        let item = try store.add(image: makeImage(width: 10, height: 10), scale: 1, mode: "area", pattern: "a")
        try FileManager.default.removeItem(at: dir.appendingPathComponent("index.json"))
        XCTAssertTrue(HistoryStore(directory: dir).items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.fileURL.path))
    }

    func testCapturesInUseAreNotPruned() throws {
        let store = HistoryStore(directory: tempDirectory(), limit: 2)
        let pinned = try store.add(image: makeImage(width: 10, height: 10), scale: 1, mode: "area", pattern: "pinned")
        store.isInUse = { $0 == pinned.id }
        for i in 0..<4 {
            try store.add(image: makeImage(width: 10, height: 10), scale: 1, mode: "area", pattern: "n\(i)")
        }
        XCTAssertEqual(store.items.map(\.baseName), ["n3", "pinned"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: pinned.fileURL.path))
        // Once released it goes at the next capture.
        store.isInUse = nil
        try store.add(image: makeImage(width: 10, height: 10), scale: 1, mode: "area", pattern: "n4")
        XCTAssertEqual(store.items.map(\.baseName), ["n4", "n3"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: pinned.fileURL.path))
    }

    func testHistorySurvivesAMovedFolderAndStaysBounded() throws {
        let original = tempDirectory()
        let store = HistoryStore(directory: original, limit: 3)
        for i in 0..<6 {
            try store.add(image: makeImage(width: 40, height: 40), scale: 1, mode: "area", pattern: "n\(i)")
        }
        // Exactly the limit on disk: three capture folders plus the index.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: original.path).count, 4)
        XCTAssertGreaterThan(store.diskUsage, 0)

        let moved = FileManager.default.temporaryDirectory.appendingPathComponent("SnapShelfTests-moved-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: original, to: moved)
        let reloaded = HistoryStore(directory: moved, limit: 3)
        XCTAssertEqual(reloaded.items.map(\.baseName), ["n5", "n4", "n3"])
        XCTAssertTrue(reloaded.items.allSatisfy { $0.fileURL.path.hasPrefix(moved.path) && FileManager.default.fileExists(atPath: $0.thumbnailURL.path) })
    }
}

final class HistoryExpiryTests: XCTestCase {
    func testRemovesOnlyCapturesOlderThanTheLimit() throws {
        let store = HistoryStore(directory: tempDirectory())
        let now = Date()
        let day = 86_400.0
        let old = try store.add(image: makeImage(width: 10, height: 10), scale: 1, mode: "area", pattern: "old", date: now.addingTimeInterval(-8 * day))
        let recent = try store.add(image: makeImage(width: 10, height: 10), scale: 1, mode: "area", pattern: "recent", date: now.addingTimeInterval(-6 * day))

        XCTAssertEqual(store.removeExpired(days: 0, now: now), 0, "0 means never expire")
        XCTAssertEqual(store.items.count, 2)

        XCTAssertEqual(store.removeExpired(days: 7, now: now), 1)
        XCTAssertEqual(store.items, [recent])
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.fileURL.deletingLastPathComponent().path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.fileURL.path))
        XCTAssertEqual(HistoryStore(directory: store.directory).items, [recent], "the removal is persisted")
    }

    func testExpiryLeavesCapturesInUse() throws {
        let store = HistoryStore(directory: tempDirectory())
        let now = Date()
        let onShelf = try store.add(image: makeImage(width: 10, height: 10), scale: 1, mode: "area", pattern: "shelf", date: now.addingTimeInterval(-30 * 86_400))
        store.isInUse = { $0 == onShelf.id }
        XCTAssertEqual(store.removeExpired(days: 1, now: now), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: onShelf.fileURL.path))
        store.isInUse = nil
        XCTAssertEqual(store.removeExpired(days: 1, now: now), 1)
        XCTAssertTrue(store.items.isEmpty)
    }

    func testExpirySettingDefaultsToNeverAndPersists() {
        let name = "SnapShelfTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        XCTAssertEqual(AppSettings(defaults: defaults).historyExpiryDays, 0)
        AppSettings(defaults: defaults).historyExpiryDays = 14
        XCTAssertEqual(AppSettings(defaults: defaults).historyExpiryDays, 14)
        defaults.removePersistentDomain(forName: name)
    }
}

final class SaveExporterTests: XCTestCase {
    func testSavesPNGAndJPEGWithUniqueNames() throws {
        let store = HistoryStore(directory: tempDirectory())
        let item = try store.add(image: makeImage(width: 300, height: 200), scale: 2, mode: "area", pattern: "Shot")
        let folder = tempDirectory().appendingPathComponent("nested/out")

        let png = try SaveExporter.save(item, to: folder, format: .png)
        XCTAssertEqual(png.lastPathComponent, "Shot.png")
        XCTAssertEqual(try Data(contentsOf: png), try Data(contentsOf: item.fileURL))
        XCTAssertEqual(try SaveExporter.save(item, to: folder, format: .png).lastPathComponent, "Shot 2.png")

        let jpg = try SaveExporter.save(item, to: folder, format: .jpeg)
        XCTAssertEqual(jpg.lastPathComponent, "Shot.jpg")
        XCTAssertEqual(ImageCodec.pixelSize(of: jpg), CGSize(width: 300, height: 200))
        XCTAssertEqual(Array(try Data(contentsOf: jpg).prefix(2)), [0xFF, 0xD8])
    }
}

final class SettingsTests: XCTestCase {
    func makeDefaults() -> UserDefaults {
        let name = "SnapShelfTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testDefaults() {
        let s = AppSettings(defaults: makeDefaults())
        XCTAssertTrue(s.copyToClipboard)
        XCTAssertTrue(s.showOverlay)
        XCTAssertFalse(s.saveToFolder)
        XCTAssertEqual(s.saveFolderPath, "~/Pictures/SnapShelf")
        XCTAssertEqual(s.corner, .bottomLeft)
        XCTAssertEqual(s.autoDismissSeconds, 0)
        XCTAssertEqual(s.format, .png)
        XCTAssertEqual(s.hotkeys[.area]?.displayString, "⌃⇧4")
        XCTAssertEqual(Set(s.hotkeys.values).count, HotkeyAction.allCases.count, "default hotkeys must not collide")
    }

    func testPersistenceAndHotkeyConflicts() {
        let defaults = makeDefaults()
        let s = AppSettings(defaults: defaults)
        s.corner = .bottomRight
        s.autoDismissSeconds = 12
        s.format = .jpeg
        let key = Hotkey(keyCode: 0, modifiers: Hotkey.command | Hotkey.option)
        s.setHotkey(key, for: .area)
        s.setHotkey(key, for: .window) // takes it from .area
        s.setHotkey(nil, for: .fullScreen)

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.corner, .bottomRight)
        XCTAssertEqual(reloaded.autoDismissSeconds, 12)
        XCTAssertEqual(reloaded.format, .jpeg)
        XCTAssertNil(reloaded.hotkeys[.area])
        XCTAssertEqual(reloaded.hotkeys[.window], key)
        XCTAssertNil(reloaded.hotkeys[.fullScreen])
        XCTAssertEqual(key.displayString, "⌥⌘A")
    }
}

final class DragPayloadTests: XCTestCase {
    /// What a drop target reads: a file URL that resolves to the full-size PNG.
    func testDragPasteboardCarriesTheRealPNGFile() throws {
        let store = HistoryStore(directory: tempDirectory())
        let item = try store.add(image: makeImage(width: 800, height: 500), scale: 2, mode: "area", pattern: "Shot")
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        XCTAssertTrue(pasteboard.writeObjects([FileDragWriter(url: item.fileURL)]))
        XCTAssertEqual(pasteboard.data(forType: .png), try Data(contentsOf: item.fileURL))
        XCTAssertTrue(pasteboard.types?.contains(.fileURL) ?? false)
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        let dropped = try XCTUnwrap(urls?.first)
        XCTAssertEqual(dropped.pathExtension, "png")
        XCTAssertEqual(ImageCodec.pixelSize(of: dropped), CGSize(width: 800, height: 500))
        XCTAssertEqual(Array(try Data(contentsOf: dropped).prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }
}

@testable import SnapShelfAnnotate
import SnapShelfCapture

final class AnnotationTests: XCTestCase {
    func testRenderKeepsPixelSizeAndAppliesCrop() throws {
        let model = EditorModel(image: makeImage(width: 400, height: 300, alpha: false), scale: 2)
        model.add(Annotation(tool: .rectangle, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 100, y: 80), color: .red, width: 6))
        model.add(Annotation(tool: .blur, start: CGPoint(x: 150, y: 50), end: CGPoint(x: 300, y: 200), color: .red, width: 6))
        model.add(Annotation(tool: .text, start: CGPoint(x: 20, y: 200), end: .zero, color: .red, width: 6, text: "Hi"))
        let full = try XCTUnwrap(model.render())
        XCTAssertEqual([full.width, full.height], [400, 300])

        model.setCrop(CGRect(x: 50, y: 40, width: 200, height: 100))
        let cropped = try XCTUnwrap(model.render())
        XCTAssertEqual([cropped.width, cropped.height], [200, 100])
    }

    func testAnnotationIsDrawnWhereItWasPlaced() throws {
        // White image; a red stroke near the top-left must land in the top-left of the output.
        let ctx = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let model = EditorModel(image: ctx.makeImage()!, scale: 1)
        model.add(Annotation(tool: .line, start: CGPoint(x: 5, y: 10), end: CGPoint(x: 40, y: 10), color: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), width: 6))
        let out = try XCTUnwrap(model.render())
        let data = try XCTUnwrap(out.dataProvider?.data as Data?)
        func pixel(_ x: Int, _ y: Int) -> [UInt8] { // y counted from the top
            let o = y * out.bytesPerRow + x * 4
            return [data[o], data[o + 1], data[o + 2]]
        }
        XCTAssertEqual(pixel(20, 10), [255, 0, 0])
        XCTAssertEqual(pixel(20, 90), [255, 255, 255])
    }

    func testUndoRedoAndStepNumbers() {
        let model = EditorModel(image: makeImage(width: 50, height: 50), scale: 1)
        XCTAssertFalse(model.canUndo)
        for _ in 0..<2 {
            model.add(Annotation(tool: .step, start: .zero, end: .zero, color: .red, width: 3, number: model.nextStepNumber))
        }
        XCTAssertEqual(model.annotations.map(\.number), [1, 2])
        model.undo()
        XCTAssertEqual(model.annotations.count, 1)
        XCTAssertTrue(model.canRedo)
        model.redo()
        XCTAssertEqual(model.annotations.count, 2)
        model.setCrop(CGRect(x: 0, y: 0, width: 10, height: 10))
        model.undo()
        XCTAssertNil(model.crop)
    }

    func testHitTestingAndMoving() {
        var line = Annotation(tool: .line, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 0), color: .red, width: 2)
        XCTAssertTrue(line.hitTest(CGPoint(x: 50, y: 3), tolerance: 4))
        XCTAssertFalse(line.hitTest(CGPoint(x: 50, y: 30), tolerance: 4))
        line.translate(dx: 0, dy: 30)
        XCTAssertTrue(line.hitTest(CGPoint(x: 50, y: 30), tolerance: 4))
        let rect = Annotation(tool: .rectangle, start: .zero, end: CGPoint(x: 100, y: 100), color: .red, width: 2)
        XCTAssertTrue(rect.hitTest(CGPoint(x: 0, y: 50), tolerance: 4))
        XCTAssertFalse(rect.hitTest(CGPoint(x: 50, y: 50), tolerance: 4))
    }
}

final class BackdropTests: XCTestCase {
    func testBackgroundAddsPaddingAroundTheCapture() throws {
        let model = EditorModel(image: makeImage(width: 400, height: 200, alpha: false), scale: 1)
        model.backdrop = .ocean
        model.paddingFraction = 0.1
        let out = try XCTUnwrap(model.render())
        XCTAssertEqual([out.width, out.height], [400 + 80, 200 + 80])
        model.setCrop(CGRect(x: 0, y: 0, width: 100, height: 100))
        let cropped = try XCTUnwrap(model.render())
        XCTAssertEqual([cropped.width, cropped.height], [120, 120], "padding follows the cropped size")
        model.backdrop = .none
        XCTAssertEqual(try XCTUnwrap(model.render()).width, 100)
    }

    /// Set SNAPSHELF_DUMP to a folder to write a sample for a visual check.
    func testDumpSampleForVisualCheck() throws {
        guard let folder = ProcessInfo.processInfo.environment["SNAPSHELF_DUMP"] else { return }
        let model = EditorModel(image: makeImage(width: 600, height: 380, alpha: false), scale: 2)
        model.add(Annotation(tool: .arrow, start: CGPoint(x: 80, y: 300), end: CGPoint(x: 300, y: 120), color: .systemRed, width: 8))
        model.add(Annotation(tool: .step, start: CGPoint(x: 420, y: 120), end: .zero, color: .systemRed, width: 8, number: 1))
        model.add(Annotation(tool: .text, start: CGPoint(x: 330, y: 220), end: .zero, color: .black, width: 6, text: "Padding"))
        model.backdrop = .sunset
        let image = try XCTUnwrap(model.render())
        try ImageCodec.write(image, to: URL(fileURLWithPath: folder).appendingPathComponent("backdrop.png"), format: .png)
    }
}

final class ScrollStitcherTests: XCTestCase {
    /// A tall page where every row is different, so each offset has exactly one match.
    func makePage(width: Int, height: Int, stickyHeader: Int = 0) -> (page: CGImage, frame: (Int, Int) -> CGImage) {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for block in 0..<(width / 8) {
                let v = UInt8.random(in: 0...255, using: &generator)
                for x in (block * 8)..<(block * 8 + 8) {
                    let i = (y * width + x) * 4
                    bytes[i] = v; bytes[i + 1] = v; bytes[i + 2] = v
                }
            }
        }
        func image(_ data: [UInt8], _ h: Int) -> CGImage {
            CGImage(width: width, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                    provider: CGDataProvider(data: Data(data) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        }
        let frame: (Int, Int) -> CGImage = { offset, frameHeight in
            var rows = Array(bytes[(offset * width * 4)..<((offset + frameHeight) * width * 4)])
            // A header that stays put while the page moves under it.
            for i in 0..<(stickyHeader * width * 4) { rows[i] = 40 }
            return image(rows, frameHeight)
        }
        return (image(bytes, height), frame)
    }

    func pixels(_ image: CGImage) -> Data { image.dataProvider!.data! as Data }

    func testStitchesScrolledFramesIntoThePage() throws {
        let (page, frame) = makePage(width: 240, height: 1000)
        let stitcher = ScrollStitcher()
        for offset in [0, 0, 37, 120, 121, 300, 455, 600] { stitcher.add(frame(offset, 400)) }
        let result = try XCTUnwrap(stitcher.result())
        XCTAssertEqual(result.width, 240)
        XCTAssertEqual(result.height, 1000)
        XCTAssertEqual(stitcher.missedFrames, 0)
        XCTAssertEqual(pixels(result), pixels(page))
    }

    func testCopesWithAStickyHeaderAndSkipsFramesItCannotPlace() throws {
        let (_, frame) = makePage(width: 240, height: 2000, stickyHeader: 40)
        let stitcher = ScrollStitcher()
        stitcher.add(frame(0, 400))
        XCTAssertEqual(stitcher.add(frame(150, 400)), 150)
        // Jumped a whole screen: nothing overlaps, so the frame is skipped, not glued on.
        XCTAssertEqual(stitcher.add(frame(1200, 400)), 0)
        XCTAssertEqual(stitcher.missedFrames, 1)
        XCTAssertEqual(stitcher.add(frame(260, 400)), 110)
        XCTAssertEqual(stitcher.height, 660)
    }

    /// Lines of text: the same 13-pixel pattern over and over, differing only in a small "line number".
    func testRepeatingLinesAreNotConfusedWithEachOther() throws {
        let width = 240, pitch = 13, lines = 150
        let height = lines * pitch
        var bytes = [UInt8](repeating: 30, count: width * height * 4)
        func set(_ x: Int, _ y: Int, _ v: UInt8) {
            let i = (y * width + x) * 4
            bytes[i] = v; bytes[i + 1] = v; bytes[i + 2] = v
        }
        for line in 0..<lines {
            for row in 2..<10 {
                let y = line * pitch + row
                for x in stride(from: 40, to: 220, by: 3) { set(x, y, 230) }       // identical "words"
                for bit in 0..<8 where (line >> bit) & 1 == 1 { set(8 + bit * 2, y, 230) } // the number
            }
        }
        func frame(_ offset: Int) -> CGImage {
            let rows = Data(bytes[(offset * width * 4)..<((offset + 390) * width * 4)])
            return CGImage(width: width, height: 390, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                           provider: CGDataProvider(data: rows as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        }
        let stitcher = ScrollStitcher()
        // Shifts that are multiples of the pitch, and some that are not.
        for offset in [0, 130, 260, 300, 533, 800, 1040, 1300] { stitcher.add(frame(offset)) }
        XCTAssertEqual(stitcher.missedFrames, 0)
        let result = try XCTUnwrap(stitcher.result())
        XCTAssertEqual(result.height, 1690)
        XCTAssertEqual(pixels(result), Data(bytes[0..<(1690 * width * 4)]))
    }

    func testStopsAtTheHeightLimit() {
        let (_, frame) = makePage(width: 240, height: 1000)
        let stitcher = ScrollStitcher(maxHeight: 500)
        stitcher.add(frame(0, 400))
        stitcher.add(frame(200, 400))
        XCTAssertEqual(stitcher.height, 500)
        XCTAssertTrue(stitcher.isFull)
    }
}

final class RecordingFileTests: XCTestCase {
    func testRecordingsMoveIntoHistoryAndSaveUnchanged() throws {
        let store = HistoryStore(directory: tempDirectory())
        let source = tempDirectory().appendingPathComponent("clip.mp4")
        try Data("not really a movie".utf8).write(to: source)
        let item = try store.importFile(at: source, poster: makeImage(width: 800, height: 600), pixelWidth: 800, pixelHeight: 600, scale: 2, mode: "recording", pattern: "Clip")
        store.insert(item)
        XCTAssertEqual(item.fileURL.lastPathComponent, "Clip.mp4")
        XCTAssertFalse(item.isStillImage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), "moved, not copied")
        XCTAssertEqual(ImageCodec.pixelSize(of: item.thumbnailURL), CGSize(width: 480, height: 360))
        XCTAssertEqual(HistoryStore(directory: store.directory).items, [item])

        let saved = try SaveExporter.save(item, to: tempDirectory(), format: .jpeg)
        XCTAssertEqual(saved.lastPathComponent, "Clip.mp4", "the still-image format setting does not apply")
        XCTAssertEqual(try Data(contentsOf: saved), try Data(contentsOf: item.fileURL))
    }
}
