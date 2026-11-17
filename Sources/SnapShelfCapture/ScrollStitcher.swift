import CoreGraphics
import Foundation

/// Builds one tall image from frames of the same area captured while its content scrolls.
///
/// Each new frame is located inside the image built so far, and any rows it shows below the current
/// bottom are appended. Locating against the built image, not only the previous frame, means a frame
/// that could not be placed does not break the chain, and scrolling back up (or the bounce at the end
/// of a page) adds nothing instead of confusing the result.
public final class ScrollStitcher {
    public private(set) var width = 0
    public private(set) var frameHeight = 0
    /// Rows collected so far.
    public private(set) var height = 0
    /// Frames that could not be placed.
    public private(set) var missedFrames = 0
    /// Frames in a row, up to the latest, that could not be placed. Non-zero at the end means the
    /// capture lost its place and the image stops short.
    public private(set) var trailingMisses = 0
    public private(set) var placedFrames = 0

    private var pixels = Data()            // RGBA, `width * 4` bytes per row
    private var signatures: [UInt8] = []   // `blocks` bytes per collected row
    private var lastTop = 0                // where the last placed frame's top row sits in the image
    private let blocks = 24
    private let segments = 16
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
        let frameSignatures = makeSignatures(of: bytes, width: frame.width, height: frame.height)

        if height == 0 {
            width = frame.width
            frameHeight = frame.height
            pixels = bytes
            signatures = frameSignatures
            height = frame.height
            lastTop = 0
            placedFrames = 1
            return frame.height
        }
        guard frame.width == width, frame.height == frameHeight else { return 0 }
        guard let top = locate(frameSignatures, bytes) else {
            missedFrames += 1
            trailingMisses += 1
            return 0
        }
        trailingMisses = 0
        placedFrames += 1
        lastTop = top
        let newRows = min(top + frameHeight - height, maxHeight - height)
        guard newRows > 0 else { return 0 }
        let start = (frameHeight - (top + frameHeight - height)) * rowBytes
        pixels.append(bytes.subdata(in: start..<(start + newRows * rowBytes)))
        signatures.append(contentsOf: frameSignatures[((frameHeight - (top + frameHeight - height)) * blocks)..<((frameHeight - (top + frameHeight - height) + newRows) * blocks)])
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
    private func makeSignatures(of bytes: Data, width: Int, height: Int) -> [UInt8] {
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

    /// Where the frame's top row sits in the image built so far, or nil if it cannot be placed.
    ///
    /// Two passes. Row fingerprints cheaply rule out most positions. The survivors are scored on exact
    /// pixels, cell by cell: each row is cut into `segments` pieces and a position scores the share of
    /// pieces that are identical. Scoring pieces, not whole rows, is what lets a scroll bar thumb, a hover
    /// highlight or a sticky header differ without sinking the match; exact pixels are what tell one line
    /// of a list from the next. Flat pieces (blank background) are left out, since they match anywhere.
    ///
    /// Known limit: an app that redraws its content differently while it moves (browsers draw in-between
    /// frames at fractional offsets, which softens every edge) gives no identical pieces, so frames
    /// captured mid-scroll are not placed; only frames captured at rest are.
    private func locate(_ frameSignatures: [UInt8], _ frameBytes: Data) -> Int? {
        let h = frameHeight
        let rowBytes = width * 4
        let minOverlap = max(8, h / 6)
        let lowest = max(0, height - 3 * h)
        let highest = height - minOverlap
        guard highest >= lowest else { return nil }

        var candidates: [Int] = []
        signatures.withUnsafeBufferPointer { built in
            frameSignatures.withUnsafeBufferPointer { cur in
                for top in lowest...highest {
                    let overlap = min(h, height - top)
                    let step = max(1, overlap / 48)
                    var hits = 0, tried = 0
                    var y = 0
                    while y < overlap {
                        let a = (top + y) * blocks, b = y * blocks
                        var close = 0
                        for k in 0..<blocks where abs(Int(built[a + k]) - Int(cur[b + k])) <= 6 { close += 1 }
                        // A few slices may differ: a scroll bar, a highlight under the pointer.
                        if close >= blocks - 3 { hits += 1 }
                        tried += 1
                        y += step
                    }
                    if Double(hits) / Double(tried) >= 0.6 { candidates.append(top) }
                }
            }
        }
        guard !candidates.isEmpty else { return nil }

        let segmentBytes = max(4, (width / segments) * 4)
        var best: (top: Int, score: Double)?
        pixels.withUnsafeBytes { (builtRaw: UnsafeRawBufferPointer) in
            frameBytes.withUnsafeBytes { (curRaw: UnsafeRawBufferPointer) in
                guard let built = builtRaw.baseAddress, let cur = curRaw.baseAddress else { return }
                for top in candidates {
                    let overlap = min(h, height - top)
                    let step = max(1, overlap / 96)
                    var equal = 0, informative = 0, equalAll = 0, all = 0
                    var y = 0
                    while y < overlap {
                        let a = built + (top + y) * rowBytes
                        let b = cur + y * rowBytes
                        for s in 0..<segments {
                            let offset = s * segmentBytes
                            guard offset + segmentBytes <= rowBytes else { break }
                            let same = memcmp(a + offset, b + offset, segmentBytes) == 0
                            all += 1
                            if same { equalAll += 1 }
                            // Flat if every pixel equals its neighbour.
                            let flat = memcmp(b + offset, b + offset + 4, segmentBytes - 4) == 0
                            if !flat {
                                informative += 1
                                if same { equal += 1 }
                            }
                        }
                        y += step
                    }
                    // A nearly blank view has too little detail to go on; then every piece counts.
                    let score = informative * 20 >= all
                        ? Double(equal) / Double(informative)
                        : Double(equalAll) / Double(max(all, 1))
                    guard score >= 0.5 else { continue }
                    if let current = best {
                        let better = score > current.score + 0.0001
                        // Equal scores (a blank or perfectly repeating view): stay nearest the last position.
                        let tie = abs(score - current.score) <= 0.0001 && abs(top - lastTop) < abs(current.top - lastTop)
                        if better || tie { best = (top, score) }
                    } else {
                        best = (top, score)
                    }
                }
            }
        }
        return best?.top
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
