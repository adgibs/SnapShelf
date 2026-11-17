import AppKit
import SnapShelfKit

/// A small icon button that runs a closure.
final class IconButton: NSButton {
    private let handler: () -> Void

    init(symbol: String, label: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(frame: .zero)
        let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(config)
        imagePosition = .imageOnly
        isBordered = false
        bezelStyle = .regularSquare
        contentTintColor = .labelColor
        toolTip = label
        setAccessibilityLabel(label)
        target = self
        action = #selector(fire)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 26).isActive = true
        heightAnchor.constraint(equalToConstant: 26).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    @objc private func fire() { handler() }
}

/// One floating thumbnail: drag it out as a file, swipe it away, or use its hover buttons.
final class ThumbnailCard: FileDragSourceView {
    let item: CaptureItem

    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onAnnotate: (() -> Void)?
    var onPin: (() -> Void)?
    var onClose: (() -> Void)?
    var onSwipedAway: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?

    private let content = NSVisualEffectView()
    private let imageView = NSImageView()
    private let bar = NSVisualEffectView()
    private var swipeOffset: CGFloat = 0
    private var isSwiping = false
    /// Where the controller placed the card; swipes move it relative to this.
    var restingOrigin: CGPoint = .zero

    init(item: CaptureItem, image: NSImage, size: CGSize) {
        self.item = item
        super.init(frame: CGRect(origin: .zero, size: size))
        fileURL = item.fileURL
        dragImage = image

        wantsLayer = true
        layer?.masksToBounds = false
        shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.35)
            s.shadowBlurRadius = 8
            s.shadowOffset = NSSize(width: 0, height: -2)
            return s
        }()

        content.material = .popover
        content.blendingMode = .behindWindow
        content.state = .active
        content.wantsLayer = true
        content.layer?.cornerRadius = 10
        content.layer?.masksToBounds = true
        content.layer?.borderWidth = 0.5
        content.layer?.borderColor = NSColor.separatorColor.cgColor
        content.frame = bounds
        content.autoresizingMask = [.width, .height]
        addSubview(content)

        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.frame = content.bounds
        imageView.autoresizingMask = [.width, .height]
        imageView.setAccessibilityLabel("Capture, \(item.sizeDescription) pixels")
        content.addSubview(imageView)

        bar.material = .hudWindow
        bar.blendingMode = .withinWindow
        bar.state = .active
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 15
        bar.layer?.masksToBounds = true
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.isHidden = true

        let stack = NSStackView(views: [
            IconButton(symbol: "doc.on.doc", label: "Copy") { [weak self] in self?.onCopy?() },
            IconButton(symbol: "square.and.arrow.down", label: "Save") { [weak self] in self?.onSave?() },
            IconButton(symbol: "pencil.and.outline", label: "Annotate") { [weak self] in self?.onAnnotate?() },
            IconButton(symbol: "pin", label: "Pin") { [weak self] in self?.onPin?() },
            IconButton(symbol: "xmark", label: "Close") { [weak self] in self?.onClose?() },
        ])
        stack.orientation = .horizontal
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        addSubview(bar)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bar.topAnchor),
            stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            bar.centerXAnchor.constraint(equalTo: centerXAnchor),
            bar.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            content.layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    // Buttons take their own clicks; everything else on the card is the drag handle.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit is NSButton ? hit : self
    }

    override func mouseEntered(with event: NSEvent) {
        bar.isHidden = false
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        bar.isHidden = true
        onHoverChanged?(false)
    }

    // MARK: Swipe to dismiss (two-finger horizontal swipe)

    override func scrollWheel(with event: NSEvent) {
        guard event.hasPreciseScrollingDeltas, event.momentumPhase == [] else { return }
        switch event.phase {
        case .began:
            swipeOffset = 0
            isSwiping = false
        case .changed:
            if !isSwiping {
                guard abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return }
                isSwiping = true
            }
            swipeOffset += event.scrollingDeltaX
            setFrameOrigin(CGPoint(x: restingOrigin.x + swipeOffset, y: restingOrigin.y))
            alphaValue = max(0.2, 1 - abs(swipeOffset) / 160)
        case .ended, .cancelled:
            guard isSwiping else { return }
            isSwiping = false
            if abs(swipeOffset) > 60 {
                let direction: CGFloat = swipeOffset > 0 ? 1 : -1
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.15
                    animator().setFrameOrigin(CGPoint(x: restingOrigin.x + direction * 260, y: restingOrigin.y))
                    animator().alphaValue = 0
                }, completionHandler: { [weak self] in self?.onSwipedAway?() })
            } else {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.15
                    animator().setFrameOrigin(restingOrigin)
                    animator().alphaValue = 1
                }
            }
            swipeOffset = 0
        default:
            break
        }
    }
}
