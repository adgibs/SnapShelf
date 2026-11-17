import AppKit
import WebKit

public enum WebCaptureError: LocalizedError {
    case loadFailed(String)
    case timedOut
    case snapshotFailed

    public var errorDescription: String? {
        switch self {
        case let .loadFailed(reason): return "The page could not be loaded: \(reason)"
        case .timedOut: return "The page took too long to load."
        case .snapshotFailed: return "The page loaded but could not be captured."
        }
    }
}

/// Captures a whole web page, including everything below the fold, by loading it in a hidden web view.
///
/// This is the one part of SnapShelf that uses the network: it fetches the page (and whatever the page
/// itself loads) and nothing else. The web view uses a throwaway data store, so no cookies, cache or
/// history are kept, and it does not share your browser's logins.
@MainActor
public final class WebPageCapturer: NSObject, WKNavigationDelegate {
    private var webView: WKWebView?
    private var window: NSWindow?
    private var loadError: Error?
    private var finished = false

    /// Tallest page captured, in points. Longer pages are cut off here.
    public static let maxHeight: CGFloat = 30_000

    public override init() {}

    public func capture(url: URL, width: CGFloat = 1280, timeout: TimeInterval = 30) async throws -> CapturedImage {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all

        let frame = CGRect(x: 0, y: 0, width: width, height: 900)
        let webView = WKWebView(frame: frame, configuration: configuration)
        webView.navigationDelegate = self
        // The view has to live in a window to lay out and draw, but the window is never shown.
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        self.webView = webView
        self.window = window
        defer {
            webView.stopLoading()
            webView.navigationDelegate = nil
            window.contentView = nil
            window.close()
            self.webView = nil
            self.window = nil
        }

        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout))
        let deadline = Date().addingTimeInterval(timeout)
        while !finished {
            if let loadError { throw WebCaptureError.loadFailed(loadError.localizedDescription) }
            if Date() > deadline { throw WebCaptureError.timedOut }
            try await Task.sleep(nanoseconds: 150_000_000)
        }
        if let loadError { throw WebCaptureError.loadFailed(loadError.localizedDescription) }

        // Let scripts settle, then grow the view to the page's full height so everything is "on screen".
        // The height is measured twice because pages often grow once their lower parts become visible.
        try await Task.sleep(nanoseconds: 800_000_000)
        var height = try await pageHeight(webView)
        for pause in [900_000_000, 500_000_000] as [UInt64] {
            let size = CGSize(width: width, height: height)
            window.setContentSize(size)
            webView.frame = CGRect(origin: .zero, size: size)
            try await Task.sleep(nanoseconds: pause)
            let measured = try await pageHeight(webView)
            if abs(measured - height) < 2 { break }
            height = measured
        }

        // Snapshot in bands: one very tall snapshot can exceed what the renderer will draw.
        let band: CGFloat = 4000
        var pieces: [(y: CGFloat, image: CGImage)] = []
        var y: CGFloat = 0
        while y < height {
            let rect = CGRect(x: 0, y: y, width: width, height: min(band, height - y))
            let config = WKSnapshotConfiguration()
            config.rect = rect
            config.afterScreenUpdates = true
            let image: NSImage = try await withCheckedThrowingContinuation { continuation in
                webView.takeSnapshot(with: config) { image, error in
                    if let image {
                        continuation.resume(returning: image)
                    } else {
                        continuation.resume(throwing: error ?? WebCaptureError.snapshotFailed)
                    }
                }
            }
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw WebCaptureError.snapshotFailed
            }
            pieces.append((y, cg))
            y += band
        }
        guard let first = pieces.first else { throw WebCaptureError.snapshotFailed }

        let scale = CGFloat(first.image.width) / width
        let pixelWidth = first.image.width
        let pixelHeight = Int((height * scale).rounded())
        guard let ctx = CGContext(
            data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { throw WebCaptureError.snapshotFailed }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        for piece in pieces {
            let top = Int((piece.y * scale).rounded())
            // CGContext's origin is bottom-left; pieces are positioned from the top.
            ctx.draw(piece.image, in: CGRect(
                x: 0, y: pixelHeight - top - piece.image.height, width: piece.image.width, height: piece.image.height
            ))
        }
        guard let result = ctx.makeImage() else { throw WebCaptureError.snapshotFailed }
        return CapturedImage(image: result, scale: scale)
    }

    private func pageHeight(_ webView: WKWebView) async throws -> CGFloat {
        let script = "Math.max(document.body ? document.body.scrollHeight : 0, document.documentElement.scrollHeight, document.documentElement.offsetHeight)"
        let value = try await webView.evaluateJavaScript(script)
        let height = (value as? NSNumber).map { CGFloat(truncating: $0) } ?? 900
        return min(max(height, 200), WebPageCapturer.maxHeight)
    }

    // MARK: WKNavigationDelegate

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished = true
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadError = error
        finished = true
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadError = error
        finished = true
    }

    /// Stay on the page: no downloads, no hand-offs to other apps.
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let scheme = navigationAction.request.url?.scheme?.lowercased() else { return .cancel }
        return ["http", "https", "about", "data", "blob"].contains(scheme) ? .allow : .cancel
    }
}
