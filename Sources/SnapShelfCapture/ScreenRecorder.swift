import AVFoundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Records a display, or a rectangle of it, to an H.264 MP4. Video only; SnapShelf's own windows are left out.
public final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var sessionStarted = false
    private let queue = DispatchQueue(label: "app.snapshelf.recorder")

    public private(set) var pixelSize: CGSize = .zero
    public private(set) var scale: CGFloat = 1
    /// Called if the stream stops by itself (display unplugged, permission revoked).
    public var onStreamError: ((Error) -> Void)?

    public override init() {}

    /// `rect` is in points with its origin at the display's top-left; nil records the whole display.
    public func start(displayID: CGDirectDisplayID, rect: CGRect?, to url: URL, framesPerSecond: Int = 30) async throws {
        guard ScreenPermission.isGranted else { throw CaptureError.permissionDenied }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == pid }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let pointScale = CGFloat(filter.pointPixelScale)
        let full = CGRect(x: 0, y: 0, width: CGFloat(display.width), height: CGFloat(display.height))
        let source = (rect ?? full).intersection(full)
        guard source.width >= 8, source.height >= 8 else { throw CaptureError.emptyImage }

        // H.264 needs even dimensions.
        let width = max(2, Int((source.width * pointScale).rounded()) / 2 * 2)
        let height = max(2, Int((source.height * pointScale).rounded()) / 2 * 2)

        let config = SCStreamConfiguration()
        config.sourceRect = source
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
        config.showsCursor = true
        config.queueDepth = 6
        config.pixelFormat = kCVPixelFormatType_32BGRA

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let bitRate = min(max(width * height * 4, 2_000_000), 40_000_000)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitRate,
                AVVideoExpectedSourceFrameRateKey: framesPerSecond,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw CaptureError.emptyImage }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CaptureError.emptyImage }

        self.writer = writer
        self.input = input
        sessionStarted = false
        pixelSize = CGSize(width: width, height: height)
        scale = pointScale

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, let writer, let input,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete else { return }
        if !sessionStarted {
            writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
            sessionStarted = true
        }
        if input.isReadyForMoreMediaData { input.append(sampleBuffer) }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStreamError?(error)
    }

    /// Stops and finishes the file. Throws if nothing was recorded.
    @discardableResult
    public func stop() async throws -> URL {
        try? await stream?.stopCapture()
        stream = nil
        guard let writer, let input else { throw CaptureError.emptyImage }
        self.writer = nil
        self.input = nil
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [sessionStarted] in
                guard sessionStarted else {
                    writer.cancelWriting()
                    continuation.resume(throwing: CaptureError.emptyImage)
                    return
                }
                // The screen only sends frames when something changes, so hold the last one until now.
                // Otherwise a recording of a still screen would end at its last change.
                writer.endSession(atSourceTime: CMClockGetTime(CMClockGetHostTimeClock()))
                input.markAsFinished()
                writer.finishWriting {
                    if writer.status == .completed {
                        continuation.resume(returning: writer.outputURL)
                    } else {
                        continuation.resume(throwing: writer.error ?? CaptureError.emptyImage)
                    }
                }
            }
        }
    }
}

/// Stills and GIFs from a recorded movie.
public enum MovieTools {
    public static func firstFrame(of url: URL, maxPixel: CGFloat = 960) -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        return try? generator.copyCGImage(at: .zero, actualTime: nil)
    }

    /// Converts a movie to an animated GIF. Blocking; call off the main thread.
    public static func exportGIF(from movie: URL, to gif: URL, framesPerSecond: Double = 12, maxPixel: CGFloat = 960) throws {
        let asset = AVURLAsset(url: movie)
        let duration = CMTimeGetSeconds(asset.duration)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        generator.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 60)
        generator.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 60)

        let frameCount = max(1, Int((max(duration, 0) * framesPerSecond).rounded(.up)))
        guard let dest = CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString, frameCount, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / framesPerSecond]] as CFDictionary
        var written = 0
        var last: CGImage?
        for index in 0..<frameCount {
            let time = CMTime(seconds: Double(index) / framesPerSecond, preferredTimescale: 600)
            // A frame that cannot be decoded repeats the previous one so timing stays right.
            if let frame = (try? generator.copyCGImage(at: time, actualTime: nil)) ?? last {
                CGImageDestinationAddImage(dest, frame, frameProps)
                last = frame
                written += 1
            }
        }
        guard written > 0, CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}
