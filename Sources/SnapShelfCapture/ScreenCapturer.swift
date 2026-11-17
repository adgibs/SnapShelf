import AppKit
import ScreenCaptureKit

public enum CaptureError: LocalizedError {
    case permissionDenied
    case displayNotFound
    case windowNotFound
    case emptyImage

    public var errorDescription: String? {
        switch self {
        case .permissionDenied: return "SnapShelf does not have Screen Recording access."
        case .displayNotFound: return "That display is no longer available."
        case .windowNotFound: return "That window is no longer available."
        case .emptyImage: return "The capture came back empty."
        }
    }
}

public struct CapturedImage {
    public let image: CGImage
    /// Pixels per point of the source.
    public let scale: CGFloat
}

/// Screen Recording permission.
public enum ScreenPermission {
    public static var isGranted: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt the first time; afterwards it only reports the current state.
    @discardableResult
    public static func request() -> Bool { CGRequestScreenCaptureAccess() }

    public static func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Still captures through ScreenCaptureKit. SnapShelf's own windows are always left out.
public enum ScreenCapturer {
    /// Captures a display, or `rect` within it (points, origin at the display's top-left).
    public static func captureDisplay(_ displayID: CGDirectDisplayID, rect: CGRect? = nil, hideDesktopIcons: Bool = false) async throws -> CapturedImage {
        guard ScreenPermission.isGranted else { throw CaptureError.permissionDenied }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == pid }
        let filter: SCContentFilter
        if ownApps.isEmpty || hideDesktopIcons {
            // Leave windows out one by one: our own, and Finder's desktop icon layer if asked.
            let excluded = content.windows.filter { window in
                if window.owningApplication?.processID == pid { return true }
                return hideDesktopIcons
                    && window.owningApplication?.bundleIdentifier == "com.apple.finder"
                    && window.windowLayer < 0
            }
            filter = SCContentFilter(display: display, excludingWindows: excluded)
        } else {
            filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        }

        let scale = CGFloat(filter.pointPixelScale)
        let full = CGRect(x: 0, y: 0, width: CGFloat(display.width), height: CGFloat(display.height))
        let source = (rect ?? full).intersection(full)
        guard !source.isEmpty else { throw CaptureError.emptyImage }

        let config = SCStreamConfiguration()
        config.sourceRect = source
        config.width = max(1, Int((source.width * scale).rounded()))
        config.height = max(1, Int((source.height * scale).rounded()))
        config.showsCursor = false
        config.captureResolution = .best
        config.scalesToFit = false

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return CapturedImage(image: image, scale: scale)
    }

    /// Captures one window on a transparent background, without its shadow.
    public static func captureWindow(_ windowID: CGWindowID) async throws -> CapturedImage {
        guard ScreenPermission.isGranted else { throw CaptureError.permissionDenied }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.windowNotFound
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let size = filter.contentRect.size

        let config = SCStreamConfiguration()
        config.width = max(1, Int((size.width * scale).rounded()))
        config.height = max(1, Int((size.height * scale).rounded()))
        config.showsCursor = false
        config.captureResolution = .best
        config.ignoreShadowsSingleWindow = true
        config.shouldBeOpaque = false
        config.backgroundColor = .clear

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return CapturedImage(image: image, scale: scale)
    }
}
