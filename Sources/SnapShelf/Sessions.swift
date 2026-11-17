import AppKit
import SnapShelfCapture
import SnapShelfHistory
import SnapShelfKit

/// Screen recording and scrolling capture: the two captures that run until the user stops them.
extension CaptureCoordinator {
    static var recordingDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SnapShelf-recording", isDirectory: true)
    }

    /// Removes recordings left unfinished by a crash. Call once at launch.
    static func purgeUnfinishedRecordings() {
        try? FileManager.default.removeItem(at: recordingDirectory)
    }

    var sessionActive: Bool { recorder != nil || scrollTask != nil }

    func stopActiveSession() {
        if recorder != nil { stopRecording() }
        if scrollTask != nil { finishScrollCapture() }
    }

    /// Shared entry for both: stop if running, otherwise pick an area and start.
    func toggleSession(_ action: HotkeyAction) {
        if sessionActive {
            stopActiveSession()
            return
        }
        if selection.isActive {
            selection.cancel()
            return
        }
        guard !busy else { return }
        guard ScreenPermission.isGranted else {
            permissionWindow.show()
            return
        }
        selection.begin(mode: .area) { [weak self] result in
            guard let self, case let .area(displayID, rect)? = result else {
                HUD.hide()
                return
            }
            HUD.hide()
            if action == .record {
                self.startRecording(displayID: displayID, rect: rect)
            } else {
                self.startScrollCapture(displayID: displayID, rect: rect)
            }
        }
        HUD.show(action == .record
            ? "Drag the area to record, or press Return for the whole display"
            : "Drag over the area that scrolls")
    }

    private func stopHint(_ action: HotkeyAction) -> String {
        if let key = settings.hotkeys[action]?.displayString { return "press \(key) or click the menu bar icon" }
        return "click the menu bar icon"
    }

    // MARK: Recording

    func startRecording(displayID: CGDirectDisplayID, rect: CGRect) {
        let recorder = ScreenRecorder()
        let url = CaptureCoordinator.recordingDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        try? FileManager.default.createDirectory(at: CaptureCoordinator.recordingDirectory, withIntermediateDirectories: true)
        recorder.onStreamError = { [weak self] _ in
            DispatchQueue.main.async { self?.stopRecording() }
        }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await recorder.start(displayID: displayID, rect: rect, to: url)
                self.recorder = recorder
                onSessionChange?("Stop Recording")
                HUD.toast("Recording. To stop, \(stopHint(.record)).", seconds: 3)
                log.notice("recording started \(Int(recorder.pixelSize.width))x\(Int(recorder.pixelSize.height))")
            } catch {
                report(error)
            }
        }
    }

    private func stopRecording() {
        guard let recorder else { return }
        self.recorder = nil
        onSessionChange?(nil)
        let format = settings.recordingFormat
        let pattern = settings.fileNamePattern
        busy = true
        Task {
            defer { busy = false }
            do {
                let movie = try await recorder.stop()
                var file = movie
                var poster = MovieTools.firstFrame(of: movie)
                if format == .gif {
                    HUD.show("Converting to GIF…")
                    let gif = movie.deletingPathExtension().appendingPathExtension("gif")
                    try await Task.detached(priority: .userInitiated) {
                        try MovieTools.exportGIF(from: movie, to: gif)
                    }.value
                    try? FileManager.default.removeItem(at: movie)
                    file = gif
                    poster = poster ?? ImageCodec.load(gif)
                    HUD.hide()
                }
                guard let poster else { throw CaptureError.emptyImage }
                let item = try history.importFile(
                    at: file, poster: poster,
                    pixelWidth: Int(recorder.pixelSize.width), pixelHeight: Int(recorder.pixelSize.height),
                    scale: recorder.scale, mode: "recording", pattern: pattern
                )
                history.insert(item)
                afterCapture(item, forceOverlay: true)
                log.notice("recording saved as \(item.fileURL.pathExtension, privacy: .public)")
            } catch {
                HUD.hide()
                report(error)
            }
        }
    }

    // MARK: Scrolling capture

    func startScrollCapture(displayID: CGDirectDisplayID, rect: CGRect) {
        let stitcher = ScrollStitcher()
        self.stitcher = stitcher
        onSessionChange?("Finish Scrolling Capture")
        let hint = stopHint(.scrollCapture)
        HUD.show("Scroll down. To finish, \(hint).")
        scrollTask = Task { [weak self] in
            var shownHeight = 0
            while !Task.isCancelled {
                if let captured = try? await ScreenCapturer.captureDisplay(displayID, rect: rect) {
                    self?.scrollScale = captured.scale
                    let image = captured.image
                    // Matching a frame takes a few milliseconds; keep it off the main thread.
                    await Task.detached(priority: .userInitiated) { _ = stitcher.add(image) }.value
                    // Live feedback: the height grows as new rows are stitched on.
                    if stitcher.trailingMisses >= 4 {
                        HUD.show("Lost the place. Scroll back up a little until it catches up.", announce: stitcher.trailingMisses == 4)
                        shownHeight = 0
                    } else if stitcher.height != shownHeight {
                        shownHeight = stitcher.height
                        HUD.show("Captured \(shownHeight) px. To finish, \(hint).", announce: false)
                    }
                    if stitcher.isFull { break }
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    private func finishScrollCapture() {
        guard let task = scrollTask, let stitcher else { return }
        scrollTask = nil
        self.stitcher = nil
        task.cancel()
        HUD.hide()
        onSessionChange?(nil)
        busy = true
        Task {
            defer { busy = false }
            await task.value
            guard let image = stitcher.result() else {
                HUD.toast("Nothing was captured")
                return
            }
            do {
                let item = try await deliver(image, scale: scrollScale, mode: "scroll")
                log.notice("scrolling capture \(item.pixelWidth)x\(item.pixelHeight), placed \(stitcher.placedFrames), missed \(stitcher.missedFrames), trailing \(stitcher.trailingMisses)")
                if stitcher.trailingMisses > 2 {
                    HUD.toast("The capture lost its place before the end, so the image stops short.", seconds: 4)
                }
            } catch {
                report(error)
            }
        }
    }
}
