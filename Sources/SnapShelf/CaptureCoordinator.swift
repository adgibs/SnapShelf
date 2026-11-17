import AppKit
import SnapShelfCapture
import SnapShelfHistory
import SnapShelfKit
import SnapShelfOverlay
import os

/// Runs a capture from hotkey to finished file: permission check, selection, capture, then the after-capture actions.
@MainActor
final class CaptureCoordinator {
    let settings: AppSettings
    let history: HistoryStore
    private let quickAccess: QuickAccessController
    let permissionWindow: PermissionWindowController
    let selection = SelectionOverlay()
    var busy = false

    // Running sessions (see Sessions.swift).
    var recorder: ScreenRecorder?
    var scrollTask: Task<Void, Never>?
    var stitcher: ScrollStitcher?
    var scrollScale: CGFloat = 1
    /// Called with a "stop" title when a recording or scrolling capture starts, and nil when it ends.
    var onSessionChange: ((String?) -> Void)?

    init(settings: AppSettings, history: HistoryStore, quickAccess: QuickAccessController, permissionWindow: PermissionWindowController) {
        self.settings = settings
        self.history = history
        self.quickAccess = quickAccess
        self.permissionWindow = permissionWindow
    }

    func perform(_ action: HotkeyAction) {
        if action == .reopenLast {
            reopenLast()
            return
        }
        if action == .webPage {
            captureWebPage(from: NSPasteboard.general.string(forType: .string) ?? "")
            return
        }
        if action == .record || action == .scrollCapture {
            toggleSession(action)
            return
        }
        if sessionActive {
            HUD.toast("Finish the current recording first")
            return
        }
        // Pressing a capture hotkey again while selecting cancels the selection.
        if selection.isActive {
            selection.cancel()
            return
        }
        guard !busy else { return }
        guard ScreenPermission.isGranted else {
            permissionWindow.show()
            return
        }

        let started = CFAbsoluteTimeGetCurrent()
        defer {
            let ms = (CFAbsoluteTimeGetCurrent() - started) * 1000
            log.notice("\(action.rawValue, privacy: .public): hotkey to overlay \(ms, format: .fixed(precision: 1), privacy: .public) ms")
        }
        let timer = settings.selfTimerSeconds
        let hideIcons = settings.hideDesktopIcons
        switch action {
        case .fullScreen:
            let displayID = NSScreen.underMouse.displayID
            busy = true
            HUD.countdown(seconds: timer) { [weak self] in
                self?.run(mode: "screen") { try await ScreenCapturer.captureDisplay(displayID, hideDesktopIcons: hideIcons) }
            }
        case .area:
            selection.begin(mode: .area) { [weak self] result in
                guard let self, case let .area(displayID, rect)? = result else { return }
                self.busy = true
                HUD.countdown(seconds: timer) {
                    self.run(mode: "area") { try await ScreenCapturer.captureDisplay(displayID, rect: rect, hideDesktopIcons: hideIcons) }
                }
            }
        case .window:
            selection.begin(mode: .window) { [weak self] result in
                guard let self, case let .window(windowID)? = result else { return }
                self.busy = true
                HUD.countdown(seconds: timer) {
                    self.run(mode: "window") { try await ScreenCapturer.captureWindow(windowID) }
                }
            }
        case .captureText:
            selection.begin(mode: .area) { [weak self] result in
                guard let self, case let .area(displayID, rect)? = result else { return }
                self.recognizeText(displayID: displayID, rect: rect)
            }
        case .reopenLast, .record, .scrollCapture, .webPage:
            break
        }
    }

    /// Captures the whole of a web page, below the fold included, from an address. Uses the network.
    func captureWebPage(from text: String) {
        guard !busy, !sessionActive else { return }
        guard let url = WebAddress.parse(text) else {
            HUD.toast("Copy the page's address first (⌘L, ⌘C in your browser), then try again.", seconds: 4)
            return
        }
        busy = true
        HUD.show("Loading \(url.host ?? "page")…")
        Task {
            defer { busy = false }
            do {
                let captured = try await WebPageCapturer().capture(url: url)
                HUD.hide()
                let item = try await deliver(captured.image, scale: captured.scale, mode: "web")
                log.notice("web page captured \(item.pixelWidth)x\(item.pixelHeight)")
            } catch {
                HUD.toast(error.localizedDescription, seconds: 4)
                log.error("web capture failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Reads the text in a rectangle of the screen and puts it on the clipboard. Nothing is saved to history.
    func recognizeText(displayID: CGDirectDisplayID, rect: CGRect) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let captured = try await ScreenCapturer.captureDisplay(displayID, rect: rect)
                let text = try await TextRecognizer.recognize(in: captured.image)
                if text.isEmpty {
                    HUD.toast("No text found in that area", seconds: 2.5)
                } else {
                    Clipboard.copy(text: text)
                    let lines = text.split(separator: "\n").count
                    HUD.toast("Copied \(lines) line\(lines == 1 ? "" : "s") of text to the clipboard", seconds: 2.5)
                }
                log.notice("capture text: \(text.count) characters")
            } catch {
                report(error)
            }
        }
    }

    /// Captures a known rectangle without the selection UI (used by the URL scheme).
    func captureArea(_ rect: CGRect, displayID: CGDirectDisplayID) {
        guard !busy, !selection.isActive else { return }
        guard ScreenPermission.isGranted else {
            permissionWindow.show()
            return
        }
        let hideIcons = settings.hideDesktopIcons
        run(mode: "area") { try await ScreenCapturer.captureDisplay(displayID, rect: rect, hideDesktopIcons: hideIcons) }
    }

    func captureWindow(_ windowID: CGWindowID) {
        guard !busy, !selection.isActive else { return }
        run(mode: "window") { try await ScreenCapturer.captureWindow(windowID) }
    }

    private func run(mode: String, capture: @escaping () async throws -> CapturedImage) {
        busy = true
        Task {
            defer { busy = false }
            do {
                let t0 = CFAbsoluteTimeGetCurrent()
                let captured = try await capture()
                let t1 = CFAbsoluteTimeGetCurrent()
                let item = try await deliver(captured.image, scale: captured.scale, mode: mode)
                log.notice("captured \(mode, privacy: .public) \(item.pixelWidth)x\(item.pixelHeight) scale \(item.scale): capture \((t1 - t0) * 1000, format: .fixed(precision: 0), privacy: .public) ms, file \((CFAbsoluteTimeGetCurrent() - t1) * 1000, format: .fixed(precision: 0), privacy: .public) ms")
            } catch {
                report(error)
            }
        }
    }

    /// Files the image in history and runs the after-capture actions. Also used for edited images.
    @discardableResult
    func deliver(_ image: CGImage, scale: CGFloat, mode: String, forceOverlay: Bool = false) async throws -> CaptureItem {
        let store = history
        let pattern = settings.fileNamePattern
        // PNG encoding of a full Retina display takes a moment; keep it off the main thread.
        let item = try await Task.detached(priority: .userInitiated) {
            try store.write(image: image, scale: scale, mode: mode, pattern: pattern)
        }.value
        store.insert(item)
        afterCapture(item, forceOverlay: forceOverlay)
        return item
    }

    /// The after-capture actions from Settings.
    func afterCapture(_ item: CaptureItem, forceOverlay: Bool = false) {
        if settings.copyToClipboard { Clipboard.copyImage(at: item.fileURL) }
        if settings.saveToFolder { save(item, announce: false) }
        if settings.showOverlay || forceOverlay { quickAccess.show(item) }
    }

    @discardableResult
    func save(_ item: CaptureItem, announce: Bool = true) -> Bool {
        do {
            let url = try SaveExporter.save(item, to: settings.saveFolderURL, format: settings.format)
            if announce { HUD.toast("Saved to \(url.deletingLastPathComponent().lastPathComponent)") }
            return true
        } catch {
            HUD.toast("Could not save: \(error.localizedDescription)", seconds: 3)
            return false
        }
    }

    func reopenLast() {
        guard let item = history.mostRecent else {
            HUD.toast("No captures yet")
            return
        }
        quickAccess.show(item)
    }

    func report(_ error: Error) {
        log.error("capture failed: \(String(describing: error), privacy: .public)")
        if case CaptureError.permissionDenied = error {
            permissionWindow.show()
        } else if !ScreenPermission.isGranted {
            permissionWindow.show()
        } else {
            HUD.toast("Capture failed: \(error.localizedDescription)", seconds: 3)
        }
    }
}
