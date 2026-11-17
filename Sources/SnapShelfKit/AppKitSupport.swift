import AppKit
import os

private let dragLog = Logger(subsystem: "app.snapshelf.SnapShelf", category: "drag")

public extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? CGMainDisplayID()
    }

    /// The screen the mouse pointer is on.
    static var underMouse: NSScreen {
        let p = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(p, $0.frame, false) } ?? main ?? screens[0]
    }
}

/// Puts images on the general pasteboard.
public enum Clipboard {
    /// Copies the PNG at `url` as image data. TIFF is offered too, but only produced if an app asks for it.
    public static func copyImage(at url: URL) {
        guard url.pathExtension.lowercased() == "png" else {
            // Recordings go on the clipboard as a file, which Finder and chat apps paste as an attachment.
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.writeObjects([url as NSURL])
            return
        }
        guard let data = try? Data(contentsOf: url) else { return }
        copy(pngData: data)
    }

    public static func copy(pngData: Data) {
        let item = NSPasteboardItem()
        item.setData(pngData, forType: .png)
        let provider = TIFFProvider(pngData: pngData)
        item.setDataProvider(provider, forTypes: [.tiff])
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([item])
        TIFFProvider.current = provider
    }

    public static func copy(text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private final class TIFFProvider: NSObject, NSPasteboardItemDataProvider {
        static var current: TIFFProvider?
        let pngData: Data
        init(pngData: Data) { self.pngData = pngData }

        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            guard type == .tiff, let rep = NSBitmapImageRep(data: pngData),
                  let tiff = rep.representation(using: .tiff, properties: [.compressionMethod: NSBitmapImageRep.TIFFCompression.lzw]) else { return }
            item.setData(tiff, forType: .tiff)
        }

        func pasteboardFinishedWithDataProvider(_ pasteboard: NSPasteboard) {
            if TIFFProvider.current === self { TIFFProvider.current = nil }
        }
    }
}

/// What a drag carries: the file itself, plus the PNG bytes for apps that cannot or will not read the file
/// (Notes accepts a bare file URL from us and then inserts nothing). The bytes are only read if asked for.
public final class FileDragWriter: NSObject, NSPasteboardWriting {
    let url: URL

    public init(url: URL) {
        self.url = url
    }

    private var imageType: NSPasteboard.PasteboardType? {
        switch url.pathExtension.lowercased() {
        case "png": return .png
        case "jpg", "jpeg": return NSPasteboard.PasteboardType("public.jpeg")
        default: return nil
        }
    }

    public func writableTypes(for pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType] {
        [.fileURL] + (imageType.map { [$0] } ?? [])
    }

    public func writingOptions(forType type: NSPasteboard.PasteboardType, pasteboard: NSPasteboard) -> NSPasteboard.WritingOptions {
        type == .fileURL ? [] : .promised
    }

    public func pasteboardPropertyList(forType type: NSPasteboard.PasteboardType) -> Any? {
        if type == .fileURL { return (url as NSURL).pasteboardPropertyList(forType: .fileURL) }
        if type == imageType { return try? Data(contentsOf: url) }
        return nil
    }
}

/// A view that drags a real file out to other apps. Finder and friends receive a copy of `fileURL`.
open class FileDragSourceView: NSView, NSDraggingSource {
    public var fileURL: URL?
    /// Image shown under the pointer while dragging. Defaults to a snapshot of the view.
    public var dragImage: NSImage?
    /// Called when a drag ends; the argument is true if something accepted the file.
    public var onDragEnded: ((Bool) -> Void)?
    public var onDragStarted: (() -> Void)?
    public var onClick: (() -> Void)?
    public var onDoubleClick: (() -> Void)?

    private var mouseDownPoint: NSPoint?
    private var didDrag = false

    open override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    open override var mouseDownCanMoveWindow: Bool { false }

    open override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        didDrag = false
    }

    open override func mouseDragged(with event: NSEvent) {
        guard !didDrag, let start = mouseDownPoint, let url = fileURL else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 3 else { return }
        didDrag = true

        let item = NSDraggingItem(pasteboardWriter: FileDragWriter(url: url))
        item.setDraggingFrame(bounds, contents: dragImage ?? snapshot())
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        dragLog.debug("drag began: \(url.lastPathComponent, privacy: .public)")
        onDragStarted?()
    }

    open override func mouseUp(with event: NSEvent) {
        if !didDrag, mouseDownPoint != nil {
            if event.clickCount == 2, let onDoubleClick {
                onDoubleClick()
            } else if event.clickCount == 1 {
                onClick?()
            }
        }
        mouseDownPoint = nil
    }

    private func snapshot() -> NSImage {
        let image = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            image.addRepresentation(rep)
        }
        return image
    }

    // Copy only, so Finder never moves the file out of history.
    public func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    public func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        mouseDownPoint = nil
        dragLog.debug("drag ended, operation \(operation.rawValue), accepted \(operation != [])")
        onDragEnded?(operation != [])
    }
}
