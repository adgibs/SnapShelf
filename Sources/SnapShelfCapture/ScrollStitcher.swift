import CoreGraphics
import Foundation

/// Builds one tall image from frames of the same area captured while its content scrolls down.
/// Each new frame is matched against the previous one to find how far the content moved; only the newly
/// revealed rows are appended.
public final class ScrollStitcher {
    public private(set) var width = 0
    public private(set) var frameHeight = 0
    /// Rows collected so far.
    public private(set) var height = 0
    /// Frames that could not be matched to the previous one (usually scrolled too fast).
    public private(set) var missedFrames = 0

    private var pixels = Data()           // RGBA, `width * 4` bytes per row
    private var lastSignatures: [UInt8] = []
    private var lastFrame = Data()
    private let blocks = 24
    private let maxHeight: Int

    public init(maxHeight: Int = 40_000) {
        self.maxHeight = maxHeight
    }

    public var isFull: Bool { height >= maxHeight }

    /// Adds a frame. Returns the number of new rows it contributed.
    @discardableResult
    public func add(_ frame: CGImage) -> Int {
        guard let bytes = ScrollStitcher.rgba(frame) else { return 0 }
        let rowBytes = frame.width * 4
        let signatures = signatures(of: bytes, width: frame.width, height: frame.height)

        if height == 0 {
            width = frame.width
            frameHeight = frame.height
            pixels = bytes
            height = frame.height
            lastSignatures = signatures
            lastFrame = bytes
            return frame.height
        }
        guard frame.width == width, frame.height == frameHeight, !isFull else { return 0 }
        guard let shift = offset(from: lastSignatures, to: signatures, previousPixels: lastFrame, currentPixels: bytes) else {
            missedFrames += 1
            return 0
        }
        lastSignatures = signatures
        lastFrame = bytes
        guard shift > 0 else { return 0 }
        let newRows = min(shift, maxHeight - height)
        let start = (frameHeight - shift) * rowBytes
        pixels.append(bytes.subdata(in: start..<(start + newRows * rowBytes)))
        height += newRows
        return newRows
    }

    public func result() -> CGImage? {
        guard height > 0, let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    // MARK: Matching

    /// One small fingerprint per row: the average brightness of `blocks` horizontal slices.
    private func signatures(of bytes: Data, width: Int, height: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: height * blocks)
        let blockWidth = max(1, width / blocks)
        bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt8.self)
            for y in 0..<height {
                let row = y * width * 4
                for b in 0..<blocks {
                    let x0 = min(b * blockWidth, width - 1)
                    let x1 = min(x0 + blockWidth, width)
                    var sum = 0
                    var x = x0
                    while x < x1 {
                        let i = row + x * 4
                        sum += Int(p[i]) + Int(p[i + 1]) * 2 + Int(p[i + 2])
                        x += 2
                    }
                    let samples = max(1, (x1 - x0 + 1) / 2)
                    out[y * blocks + b] = UInt8(sum / (samples * 4))
                }
            }
        }
        return out
    }

    /// How many rows the content moved up between two frames, or nil if they do not line up.
    ///
    /// Two passes. The fingerprints cheaply rule out most shifts. The survivors are then compared pixel for
    /// pixel, because lists, tables and lines of text repeat at a fixed pitch and their fingerprints look
    /// alike at every multiple of it; only the exact pixels tell row 98 from row 118.
    private func offset(from previous: [UInt8], to current: [UInt8], previousPixels: Data, currentPixels: Data) -> Int? {
        let h = frameHeight
        let rowBytes = width * 4
        let minOverlap = max(8, h / 6)
        var candidates: [Int] = []
        previous.withUnsafeBufferPointer { prev in
            current.withUnsafeBufferPointer { cur in
                func rowsMatch(_ a: Int, _ b: Int) -> Bool {
                    let pa = a * blocks, pb = b * blocks
                    for k in 0..<blocks where abs(Int(prev[pa + k]) - Int(cur[pb + k])) > 4 { return false }
                    return true
                }
                for shift in 0...(h - minOverlap) {
                    let overlap = h - shift
                    let step = max(1, overlap / 48)
                    var hits = 0, tried = 0
                    var y = 0
                    while y < overlap {
                        if rowsMatch(y + shift, y) { hits += 1 }
                        tried += 1
                        y += step
                    }
                    // Sticky headers and footers never move, so a perfect score is not required.
                    if Double(hits) / Double(tried) >= 0.72 { candidates.append(shift) }
                }
            }
        }
        guard !candidates.isEmpty else { return nil }

        var best: (shift: Int, score: Double)?
        previousPixels.withUnsafeBytes { (prev: UnsafeRawBufferPointer) in
            currentPixels.withUnsafeBytes { (cur: UnsafeRawBufferPointer) in
                guard let p = prev.baseAddress, let c = cur.baseAddress else { return }
                for shift in candidates {
                    let overlap = h - shift
                    let step = max(1, overlap / 96)
                    var hits = 0, tried = 0
                    var y = 0
                    while y < overlap {
                        if memcmp(p + (y + shift) * rowBytes, c + y * rowBytes, rowBytes) == 0 { hits += 1 }
                        tried += 1
                        y += step
                    }
                    let score = Double(hits) / Double(tried)
                    if score >= 0.6, score > (best?.score ?? 0) + 0.0001 { best = (shift, score) }
                }
            }
        }
        return best?.shift
    }

    private static func rgba(_ image: CGImage) -> Data? {
        let width = image.width, height = image.height
        var data = Data(count: width * height * 4)
        let ok = data.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? data : nil
    }
}
