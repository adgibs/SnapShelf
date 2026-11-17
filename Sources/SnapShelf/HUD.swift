import AppKit

/// A small non-activating message near the top of the screen. It is one of our windows, so it never shows in captures.
@MainActor
enum HUD {
    private static var panel: NSPanel?
    private static var label: NSTextField?
    private static var hideWork: DispatchWorkItem?
    private static var countdown: Timer?

    private static func ensurePanel() -> (NSPanel, NSTextField) {
        if let panel, let label { return (panel, label) }
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.level = .statusBar
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true

        let text = NSTextField(labelWithString: "")
        text.font = .systemFont(ofSize: 14, weight: .medium)
        text.textColor = .labelColor
        text.alignment = .center
        text.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 18),
            text.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -18),
            text.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
        ])
        p.contentView = effect
        panel = p
        label = text
        return (p, text)
    }

    private static func present(_ message: String, announce: Bool = true) {
        let (panel, label) = ensurePanel()
        label.stringValue = message
        let width = max(120, label.intrinsicContentSize.width + 36)
        let screen = NSScreen.underMouse.visibleFrame
        panel.setFrame(CGRect(x: screen.midX - width / 2, y: screen.maxY - 90, width: width, height: 40), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        guard announce else { return }
        NSAccessibility.post(element: panel, notification: .announcementRequested, userInfo: [
            .announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ])
    }

    /// Shows a message until `hide()` or the next toast.
    static func show(_ message: String, announce: Bool = true) {
        hideWork?.cancel()
        present(message, announce: announce)
    }

    static func hide() {
        hideWork?.cancel()
        panel?.orderOut(nil)
    }

    static func toast(_ message: String, seconds: Double = 1.8) {
        hideWork?.cancel()
        present(message)
        let work = DispatchWorkItem { panel?.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Counts down on screen, then calls `completion`. The timer exists only while counting.
    static func countdown(seconds: Int, completion: @escaping () -> Void) {
        guard seconds > 0 else {
            completion()
            return
        }
        hideWork?.cancel()
        countdown?.invalidate()
        var remaining = seconds
        present("Capturing in \(remaining)…")
        countdown = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
            MainActor.assumeIsolated {
                remaining -= 1
                if remaining > 0 {
                    present("Capturing in \(remaining)…")
                } else {
                    timer.invalidate()
                    countdown = nil
                    panel?.orderOut(nil)
                    completion()
                }
            }
        }
    }
}
