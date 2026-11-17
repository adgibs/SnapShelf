import AppKit
import SnapShelfHistory
import SnapShelfKit
import SwiftUI

/// The menu bar item and its popover: capture commands plus draggable history.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let settings: AppSettings
    private let history: HistoryStore
    private let perform: (HotkeyAction) -> Void
    private let actions: HistoryActions
    private var previousApp: NSRunningApplication?
    private var stopSession: (() -> Void)?

    /// While a recording or scrolling capture runs, the icon becomes a stop button.
    func setSession(title: String?, stop: (() -> Void)?) {
        stopSession = title == nil ? nil : stop
        guard let button = statusItem.button else { return }
        if let title {
            button.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: title)
            button.contentTintColor = .systemRed
            button.toolTip = title
        } else {
            button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "SnapShelf")
            button.contentTintColor = nil
            button.toolTip = "SnapShelf"
        }
    }

    init(
        settings: AppSettings, history: HistoryStore,
        perform: @escaping (HotkeyAction) -> Void,
        open: @escaping (CaptureItem) -> Void,
        showSettings: @escaping () -> Void
    ) {
        self.settings = settings
        self.history = history
        self.perform = perform
        var close: () -> Void = {}
        actions = HistoryActions(
            open: { item in close(); open(item) },
            copy: { item in
                Clipboard.copyImage(at: item.fileURL)
                close()
                HUD.toast("Copied")
            },
            reveal: { item in
                close()
                NSWorkspace.shared.activateFileViewerSelecting([item.fileURL])
            },
            dragEnded: { _ in close() },
            clear: { history.clear() },
            settings: { close(); showSettings() },
            quit: { NSApp.terminate(nil) }
        )
        super.init()
        close = { [weak self] in self?.popover.performClose(nil) }

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "SnapShelf")
            button.target = self
            button.action = #selector(toggle)
            button.toolTip = "SnapShelf"
        }
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
    }

    @objc private func toggle() {
        if let stopSession {
            stopSession()
            return
        }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }
        let commands = [HotkeyAction.area, .window, .fullScreen, .scrollCapture, .record, .captureText, .reopenLast].map { action in
            MenuCommand(
                id: action.rawValue, title: action.title, symbol: action.symbolName,
                shortcut: settings.hotkeys[action]?.displayString
            ) { [weak self] in self?.run(action) }
        }
        popover.contentViewController = NSHostingController(
            rootView: HistoryMenuView(store: history, commands: commands, actions: actions)
        )
        previousApp = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    /// Closes the menu, hands focus back to the app the user was in, then starts the capture.
    private func run(_ action: HotkeyAction) {
        let previous = previousApp
        popover.performClose(nil)
        if action == .reopenLast {
            perform(action)
            return
        }
        previous?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [perform] in perform(action) }
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil
    }
}
