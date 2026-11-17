import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageFormat: String, CaseIterable, Codable, Identifiable {
    case png, jpeg
    public var id: String { rawValue }
    public var title: String { self == .png ? "PNG" : "JPEG" }
    public var fileExtension: String { self == .png ? "png" : "jpg" }
    public var utType: UTType { self == .png ? .png : .jpeg }
}

/// Encoding, decoding and scaling of capture images.
public enum ImageCodec {
    /// Encodes `image`. `scale` is recorded as DPI (72 × scale) so Retina captures open at point size.
    public static func encode(_ image: CGImage, format: ImageFormat, scale: CGFloat = 1, jpegQuality: Double = 0.9) -> Data? {
        let source = format == .jpeg ? (flattened(image) ?? image) : image
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, format.utType.identifier as CFString, 1, nil) else {
            return nil
        }
        var props: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 72.0 * Double(max(scale, 1)),
            kCGImagePropertyDPIHeight: 72.0 * Double(max(scale, 1)),
        ]
        if format == .jpeg { props[kCGImageDestinationLossyCompressionQuality] = jpegQuality }
        CGImageDestinationAddImage(dest, source, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    public static func write(_ image: CGImage, to url: URL, format: ImageFormat, scale: CGFloat = 1) throws {
        guard let data = encode(image, format: format, scale: scale) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: .atomic)
    }

    public static func load(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    public static func pixelSize(of url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return CGSize(width: w, height: h)
    }

    /// Scales `image` down so its longest side is at most `maxPixel`. Never scales up.
    public static func thumbnail(of image: CGImage, maxPixel: Int) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > maxPixel else { return image }
        let ratio = CGFloat(maxPixel) / CGFloat(longest)
        let w = max(1, Int((CGFloat(image.width) * ratio).rounded()))
        let h = max(1, Int((CGFloat(image.height) * ratio).rounded()))
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Composites onto white, for formats without alpha.
    static func flattened(_ image: CGImage) -> CGImage? {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return image
        default: break
        }
        guard let ctx = CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) ?? CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage()
    }
}

/// Reads a web address out of copied text.
public enum WebAddress {
    /// An http or https URL, or nil. "example.com/page" is accepted and treated as https.
    public static func parse(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count < 4000, !trimmed.contains(where: \.isWhitespace) else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host, host.contains("."), !host.hasPrefix("."), !host.hasSuffix("."),
              let url = components.url else { return nil }
        return url
    }
}

/// Turns the file name pattern into file names.
public enum FileNamer {
    public static let defaultPattern = "SnapShelf {date} at {time}"
    public static let tokens = ["{date}", "{time}", "{mode}", "{width}", "{height}"]

    public static func baseName(
        pattern: String, date: Date, mode: String, pixelWidth: Int, pixelHeight: Int,
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: date)
        formatter.dateFormat = "HH.mm.ss"
        let time = formatter.string(from: date)

        var name = pattern
            .replacingOccurrences(of: "{date}", with: day)
            .replacingOccurrences(of: "{time}", with: time)
            .replacingOccurrences(of: "{mode}", with: mode)
            .replacingOccurrences(of: "{width}", with: String(pixelWidth))
            .replacingOccurrences(of: "{height}", with: String(pixelHeight))
        name = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        name = name.components(separatedBy: .controlCharacters).joined()
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.count > 200 { name = String(name.prefix(200)) }
        return name.isEmpty ? "SnapShelf" : name
    }

    /// `directory/baseName.ext`, or `baseName 2.ext`, `baseName 3.ext`… if that is taken.
    public static func uniqueURL(directory: URL, baseName: String, ext: String, fileManager: FileManager = .default) -> URL {
        var candidate = directory.appendingPathComponent("\(baseName).\(ext)")
        var n = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName) \(n).\(ext)")
            n += 1
        }
        return candidate
    }
}

/// One capture kept in history. `fileURL` is always a PNG at native pixel resolution.
public struct CaptureItem: Codable, Identifiable, Equatable {
    public let id: UUID
    public let date: Date
    public let mode: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let scale: Double
    public let fileURL: URL
    public let thumbnailURL: URL

    public init(id: UUID, date: Date, mode: String, pixelWidth: Int, pixelHeight: Int, scale: Double, fileURL: URL, thumbnailURL: URL) {
        self.id = id
        self.date = date
        self.mode = mode
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.scale = scale
        self.fileURL = fileURL
        self.thumbnailURL = thumbnailURL
    }

    public var baseName: String { fileURL.deletingPathExtension().lastPathComponent }
    /// False for recordings (MP4, GIF), which cannot be annotated or pinned.
    public var isStillImage: Bool { fileURL.pathExtension.lowercased() == "png" }
    public var sizeDescription: String { "\(pixelWidth) × \(pixelHeight)" }
}

/// Saves a capture into the user's folder in the chosen format.
public enum SaveExporter {
    @discardableResult
    public static func save(_ item: CaptureItem, to folder: URL, format: ImageFormat, fileManager: FileManager = .default) throws -> URL {
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        guard item.isStillImage else {
            // Recordings are saved as they are.
            let dest = FileNamer.uniqueURL(directory: folder, baseName: item.baseName, ext: item.fileURL.pathExtension, fileManager: fileManager)
            try fileManager.copyItem(at: item.fileURL, to: dest)
            return dest
        }
        let dest = FileNamer.uniqueURL(directory: folder, baseName: item.baseName, ext: format.fileExtension, fileManager: fileManager)
        switch format {
        case .png:
            try fileManager.copyItem(at: item.fileURL, to: dest)
        case .jpeg:
            guard let image = ImageCodec.load(item.fileURL) else { throw CocoaError(.fileReadCorruptFile) }
            try ImageCodec.write(image, to: dest, format: .jpeg, scale: CGFloat(item.scale))
        }
        return dest
    }
}
