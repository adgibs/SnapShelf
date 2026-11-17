import AppKit
import SnapShelfKit

/// A capture floating above every window: borderless, resizable from its edges, with adjustable opacity.
final class PinPanel: NSPanel {
    var onClose: (() -> Void)?
    /// Held in memory so the pin keeps working after history prunes the file.
    private let pngData: Data

    init(image: NSImage, pointSize: CGSize, pngData: Data) {
        self.pngData = pngData
        super.init(
            contentRect: CGRect(origin: .zero, size: pointSize),
            styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false
        )
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentAspectRatio = pointSize
        minSize = CGSize(width: 60, height: 60 * pointSize.height / max(pointSize.width, 1))

        let view = NSImageView(image: image)
        view.imageScaling = .scaleAxesIndependently
        view.wantsLayer = true
        view.layer?.cornerRadius = 6
        view.layer?.masksToBounds = true
        view.layer?.borderWidth = 0.5
        view.layer?.borderColor = NSColor.separatorColor.cgColor
        view.setAccessibilityLabel("Pinned capture")
        contentView = view

        let menu = NSMenu()
        for percent in [100, 75, 50, 25] {
            let item = NSMenuItem(title: "Opacity \(percent)%", action: #selector(setOpacity(_:)), keyEquivalent: "")
            item.tag = percent
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Copy", action: #selector(copyImage), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Close", action: #selector(closePin), keyEquivalent: "").target = self
        view.menu = menu
    }

    override var canBecomeKey: Bool { true }

    @objc private func setOpacity(_ sender: NSMenuItem) { alphaValue = CGFloat(sender.tag) / 100 }
    @objc private func copyImage() { Clipboard.copy(pngData: pngData) }
    @objc private func closePin() { close() }

    // Scroll over the pin to change its opacity.
    override func scrollWheel(with event: NSEvent) {
        alphaValue = min(1, max(0.15, alphaValue + event.scrollingDeltaY * 0.01))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close() } else { super.keyDown(with: event) }
    }

    override func close() {
        super.close()
        onClose?()
    }
}

@MainActor
public final class PinController {
    private var pins: [PinPanel] = []

    public init() {}

    public func pin(_ item: CaptureItem) {
        guard let data = try? Data(contentsOf: item.fileURL), let image = NSImage(data: data) else { return }
        let scale = max(item.scale, 1)
        var size = CGSize(width: CGFloat(item.pixelWidth) / scale, height: CGFloat(item.pixelHeight) / scale)
        let screen = NSScreen.underMouse.visibleFrame
        let shrink = min(1, screen.width * 0.6 / size.width, screen.height * 0.6 / size.height)
        size = CGSize(width: size.width * shrink, height: size.height * shrink)

        let panel = PinPanel(image: image, pointSize: size, pngData: data)
        let offset = CGFloat(pins.count % 6) * 24
        panel.setFrameOrigin(CGPoint(x: screen.midX - size.width / 2 + offset, y: screen.midY - size.height / 2 - offset))
        panel.onClose = { [weak self, weak panel] in self?.pins.removeAll { $0 === panel } }
        pins.append(panel)
        panel.orderFrontRegardless()
    }
}
