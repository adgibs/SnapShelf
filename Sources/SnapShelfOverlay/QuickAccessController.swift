import AppKit
import Combine
import SnapShelfKit

/// Never takes focus: no key, no main, no app activation.
final class QuickAccessPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isFloatingPanel = true
        level = .statusBar // after isFloatingPanel, which resets the level
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        isMovable = false
        setAccessibilityLabel("SnapShelf captures")
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The stack of capture thumbnails in a screen corner. Each one stays until it is used or dismissed.
@MainActor
public final class QuickAccessController {
    public static let maxVisible = 5

    public var onCopy: ((CaptureItem) -> Void)?
    /// Returns true if the save worked.
    public var onSave: ((CaptureItem) -> Bool)?
    public var onAnnotate: ((CaptureItem) -> Void)?
    public var onPin: ((CaptureItem) -> Void)?

    private let settings: AppSettings
    private var panel: QuickAccessPanel?
    private var cards: [ThumbnailCard] = [] // oldest first, so the newest is drawn at the bottom
    private var dismissTimers: [UUID: DispatchWorkItem] = [:]
    private var screen: NSScreen?
    private var subscriptions = Set<AnyCancellable>()

    private let cardWidth: CGFloat = 200
    private let spacing: CGFloat = 10
    private let margin: CGFloat = 16
    private let padding: CGFloat = 14 // room for shadows inside the panel

    public init(settings: AppSettings) {
        self.settings = settings
        settings.$corner.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.layout() }
            .store(in: &subscriptions)
        settings.$autoDismissSeconds.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rescheduleAll() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.layout() }
            .store(in: &subscriptions)
    }

    public var visibleItems: [CaptureItem] { cards.map(\.item) }

    public func show(_ item: CaptureItem) {
        screen = NSScreen.underMouse
        if cards.contains(where: { $0.item.id == item.id }) {
            layout()
            return
        }
        guard let image = NSImage(contentsOf: item.thumbnailURL) ?? NSImage(contentsOf: item.fileURL) else { return }

        let aspect = CGFloat(item.pixelHeight) / CGFloat(max(item.pixelWidth, 1))
        let size = CGSize(width: cardWidth, height: min(max(cardWidth * aspect, 56), 140))
        let card = ThumbnailCard(item: item, image: image, size: size)
        card.onCopy = { [weak self] in
            self?.onCopy?(item)
            self?.dismiss(item.id)
        }
        card.onSave = { [weak self] in
            if self?.onSave?(item) == true { self?.dismiss(item.id) }
        }
        card.onAnnotate = { [weak self] in
            self?.onAnnotate?(item)
            self?.dismiss(item.id)
        }
        card.onPin = { [weak self] in
            self?.onPin?(item)
            self?.dismiss(item.id)
        }
        card.onClose = { [weak self] in self?.dismiss(item.id) }
        card.onSwipedAway = { [weak self] in self?.dismiss(item.id, animated: false) }
        card.onDragEnded = { [weak self] accepted in
            if accepted { self?.dismiss(item.id) }
        }
        card.onHoverChanged = { [weak self] hovering in
            if hovering { self?.cancelAutoDismiss(item.id) } else { self?.scheduleAutoDismiss(item.id) }
        }

        cards.append(card)
        while cards.count > QuickAccessController.maxVisible {
            removeCard(cards[0])
        }

        let panel = ensurePanel()
        panel.contentView?.addSubview(card)
        layout()
        card.alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            card.animator().alphaValue = 1
        }
        scheduleAutoDismiss(item.id)
    }

    public func dismiss(_ id: UUID, animated: Bool = true) {
        guard let card = cards.first(where: { $0.item.id == id }) else { return }
        cancelAutoDismiss(id)
        if animated {
            cards.removeAll { $0 === card }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                card.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                card.removeFromSuperview()
                self?.layout()
            })
        } else {
            removeCard(card)
            layout()
        }
    }

    public func dismissAll() {
        for card in cards { removeCard(card) }
        layout()
    }

    private func removeCard(_ card: ThumbnailCard) {
        cancelAutoDismiss(card.item.id)
        card.removeFromSuperview()
        cards.removeAll { $0 === card }
    }

    private func ensurePanel() -> QuickAccessPanel {
        if let panel { return panel }
        let panel = QuickAccessPanel()
        panel.contentView = NSView()
        self.panel = panel
        return panel
    }

    private func layout() {
        guard let panel else { return }
        guard !cards.isEmpty else {
            panel.orderOut(nil)
            return
        }
        let screen = (self.screen.flatMap { s in NSScreen.screens.first { $0 == s } }) ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let stackHeight = cards.reduce(0) { $0 + $1.frame.height } + spacing * CGFloat(cards.count - 1)
        let size = CGSize(width: cardWidth + padding * 2, height: stackHeight + padding * 2)
        let x = settings.corner == .bottomLeft
            ? visible.minX + margin - padding
            : visible.maxX - margin - cardWidth - padding
        panel.setFrame(CGRect(x: x, y: visible.minY + margin - padding, width: size.width, height: size.height), display: true)

        var y = padding
        for card in cards.reversed() {
            card.restingOrigin = CGPoint(x: padding, y: y)
            card.setFrameOrigin(card.restingOrigin)
            y += card.frame.height + spacing
        }
        panel.orderFrontRegardless()
    }

    // MARK: Auto-dismiss (one-shot; nothing runs when the setting is "never")

    private func scheduleAutoDismiss(_ id: UUID) {
        cancelAutoDismiss(id)
        let seconds = settings.autoDismissSeconds
        guard seconds > 0 else { return }
        let work = DispatchWorkItem { [weak self] in self?.dismiss(id) }
        dismissTimers[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds), execute: work)
    }

    private func cancelAutoDismiss(_ id: UUID) {
        dismissTimers.removeValue(forKey: id)?.cancel()
    }

    private func rescheduleAll() {
        for card in cards { scheduleAutoDismiss(card.item.id) }
    }
}
