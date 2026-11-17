import AppKit
import SnapShelfKit

public enum SelectionMode {
    case area, window
}

public enum SelectionResult {
    /// `rect` is in points with its origin at the display's top-left corner.
    case area(displayID: CGDirectDisplayID, rect: CGRect)
    case window(windowID: CGWindowID)
}

/// An on-screen window as the window server reports it (global coordinates, origin top-left of the main display).
struct WindowInfo {
    let id: CGWindowID
    let bounds: CGRect

    /// Normal app windows, front to back, without SnapShelf's own.
    static func snapshot() -> [WindowInfo] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let pid = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info in
            guard let number = info[kCGWindowNumber as String] as? Int,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let owner = info[kCGWindowOwnerPID as String] as? Int, owner != Int(pid),
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= 40, bounds.height >= 40 else { return nil }
            if let alpha = info[kCGWindowAlpha as String] as? Double, alpha <= 0.01 { return nil }
            return WindowInfo(id: CGWindowID(number), bounds: bounds)
        }
    }
}

/// Full-screen selection UI: drag out an area, or pick a window. One panel per display.
@MainActor
public final class SelectionOverlay {
    private var panels: [SelectionPanel] = []
    private var completion: ((SelectionResult?) -> Void)?

    public init() {}

    public var isActive: Bool { !panels.isEmpty }

    public func begin(mode: SelectionMode, completion: @escaping (SelectionResult?) -> Void) {
        guard panels.isEmpty else { return }
        self.completion = completion
        let windows = mode == .window ? WindowInfo.snapshot() : []
        let mouseScreen = NSScreen.underMouse
        var keyPanel: SelectionPanel?

        for screen in NSScreen.screens {
            let panel = SelectionPanel()
            let view = SelectionView(
                frame: CGRect(origin: .zero, size: screen.frame.size),
                mode: mode, displayID: screen.displayID, scale: screen.backingScaleFactor,
                displayBounds: CGDisplayBounds(screen.displayID), windows: windows
            )
            view.onFinish = { [weak self] result in self?.finish(result) }
            panel.contentView = view
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
            panels.append(panel)
            if screen == mouseScreen { keyPanel = panel }
        }
        // Key without activating the app, so Esc reaches us and the frontmost app keeps its look.
        (keyPanel ?? panels.first)?.makeKey()
        (keyPanel?.contentView as? SelectionView)?.pointerMoved()
        NSCursor.crosshair.set()
    }

    public func cancel() {
        if isActive { finish(nil) }
    }

    private func finish(_ result: SelectionResult?) {
        guard !panels.isEmpty else { return }
        for panel in panels { panel.orderOut(nil) }
        panels.removeAll()
        NSCursor.arrow.set()
        let done = completion
        completion = nil
        done?(result)
    }
}

final class SelectionPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        animationBehavior = .none
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true
        isMovable = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class SelectionView: NSView {
    var onFinish: ((SelectionResult?) -> Void)?

    private let mode: SelectionMode
    private let displayID: CGDirectDisplayID
    private let scale: CGFloat
    private let displayBounds: CGRect
    private let windows: [WindowInfo]

    private let dimLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    private let labelLayer = CATextLayer()

    private var dragStart: CGPoint?
    private var selection: CGRect?
    private var hoveredWindow: WindowInfo?

    init(frame: CGRect, mode: SelectionMode, displayID: CGDirectDisplayID, scale: CGFloat, displayBounds: CGRect, windows: [WindowInfo]) {
        self.mode = mode
        self.displayID = displayID
        self.scale = scale
        self.displayBounds = displayBounds
        self.windows = windows
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsScale = scale

        dimLayer.fillRule = .evenOdd
        dimLayer.fillColor = NSColor.black.withAlphaComponent(mode == .area ? 0.3 : 0.18).cgColor
        borderLayer.fillColor = mode == .area ? nil : NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor
        borderLayer.strokeColor = mode == .area ? NSColor.white.cgColor : NSColor.controlAccentColor.cgColor
        borderLayer.lineWidth = mode == .area ? 1 : 2
        labelLayer.contentsScale = scale
        labelLayer.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        labelLayer.fontSize = 11
        labelLayer.foregroundColor = NSColor.white.cgColor
        labelLayer.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        labelLayer.cornerRadius = 4
        labelLayer.alignmentMode = .center
        labelLayer.isHidden = true
        for sub in [dimLayer, borderLayer, labelLayer] {
            sub.actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull(), "hidden": NSNull(), "contents": NSNull()]
            layer?.addSublayer(sub)
        }
        redraw()

        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
            owner: self, userInfo: nil
        ))
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    // MARK: Input

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish?(nil) }
    }

    override func cancelOperation(_ sender: Any?) { onFinish?(nil) }
    override func rightMouseDown(with event: NSEvent) { onFinish?(nil) }

    override func mouseEntered(with event: NSEvent) {
        window?.makeKey()
        NSCursor.crosshair.set()
    }

    override func mouseExited(with event: NSEvent) {
        if mode == .window {
            hoveredWindow = nil
            redraw()
        }
    }

    override func mouseMoved(with event: NSEvent) {
        NSCursor.crosshair.set()
        if mode == .window { updateHover(at: convert(event.locationInWindow, from: nil)) }
    }

    /// Updates the window highlight from the current pointer position (used right after the overlay opens).
    func pointerMoved() {
        guard mode == .window, let window else { return }
        updateHover(at: convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch mode {
        case .area:
            dragStart = snap(p)
            selection = nil
            redraw()
        case .window:
            updateHover(at: p)
            if let hit = hoveredWindow { onFinish?(.window(windowID: hit.id)) }
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard mode == .area, let start = dragStart else { return }
        let p = snap(convert(event.locationInWindow, from: nil))
        selection = CGRect(
            x: min(start.x, p.x), y: min(start.y, p.y),
            width: abs(p.x - start.x), height: abs(p.y - start.y)
        )
        redraw()
    }

    override func mouseUp(with event: NSEvent) {
        guard mode == .area else { return }
        dragStart = nil
        if let rect = selection, rect.width * scale >= 2, rect.height * scale >= 2 {
            onFinish?(.area(displayID: displayID, rect: rect))
        } else {
            // A click without a drag: keep selecting.
            selection = nil
            redraw()
        }
    }

    /// Clamps to the display and snaps to whole pixels.
    private func snap(_ p: CGPoint) -> CGPoint {
        let x = min(max(p.x, 0), bounds.width)
        let y = min(max(p.y, 0), bounds.height)
        return CGPoint(x: (x * scale).rounded() / scale, y: (y * scale).rounded() / scale)
    }

    private func updateHover(at point: CGPoint) {
        let global = CGPoint(x: point.x + displayBounds.minX, y: point.y + displayBounds.minY)
        let hit = windows.first { $0.bounds.contains(global) }
        if hit?.id != hoveredWindow?.id {
            hoveredWindow = hit
            redraw()
        }
    }

    // MARK: Drawing

    private func redraw() {
        let highlighted: CGRect?
        switch mode {
        case .area:
            highlighted = selection
        case .window:
            highlighted = hoveredWindow.map {
                $0.bounds.offsetBy(dx: -displayBounds.minX, dy: -displayBounds.minY)
            }
        }

        let dim = CGMutablePath()
        dim.addRect(bounds)
        if let rect = highlighted { dim.addRect(rect) }
        dimLayer.frame = bounds
        dimLayer.path = dim

        borderLayer.frame = bounds
        if let rect = highlighted {
            borderLayer.path = CGPath(rect: rect.insetBy(dx: -0.5, dy: -0.5), transform: nil)
            let text = "\(Int((rect.width * scale).rounded())) × \(Int((rect.height * scale).rounded()))"
            let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            let textSize = (text as NSString).size(withAttributes: [.font: font])
            let size = CGSize(width: ceil(textSize.width) + 12, height: ceil(textSize.height) + 4)
            var origin = CGPoint(x: rect.maxX - size.width, y: rect.maxY + 6)
            if origin.y + size.height > bounds.height { origin.y = rect.maxY - size.height - 6 }
            origin.x = min(max(origin.x, 4), bounds.width - size.width - 4)
            labelLayer.string = text
            labelLayer.frame = CGRect(origin: origin, size: size)
            labelLayer.isHidden = false
        } else {
            borderLayer.path = nil
            labelLayer.isHidden = true
        }
    }
}
