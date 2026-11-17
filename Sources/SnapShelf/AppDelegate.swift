import AppKit
import Combine
import SnapShelfAnnotate
import SnapShelfCapture
import SnapShelfHistory
import SnapShelfKit
import SnapShelfOverlay
import SnapShelfSettings
import os

let log = Logger(subsystem: "app.snapshelf.SnapShelf", category: "app")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings.shared
    private var history: HistoryStore!
    private var quickAccess: QuickAccessController!
    private var coordinator: CaptureCoordinator!
    private var statusItem: StatusItemController!
    private var settingsWindow: SettingsWindowController!
    private let permissionWindow = PermissionWindowController()
    private let pins = PinController()
    private var editors: [AnnotationEditor] = []
    /// Captures open in an editor or pinned, which history must not prune.
    private var inUse: [UUID] = []
    private var subscriptions = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()

        AnnotationEditor.purgeExports()
        CaptureCoordinator.purgeUnfinishedRecordings()
        history = HistoryStore()
        quickAccess = QuickAccessController(settings: settings)
        history.isInUse = { [weak self] id in
            guard let self else { return false }
            return self.quickAccess.visibleItems.contains { $0.id == id } || self.inUse.contains(id)
        }
        coordinator = CaptureCoordinator(
            settings: settings, history: history, quickAccess: quickAccess, permissionWindow: permissionWindow
        )
        settingsWindow = SettingsWindowController(settings: settings)
        statusItem = StatusItemController(
            settings: settings, history: history,
            perform: { [weak self] in self?.coordinator.perform($0) },
            open: { [weak self] in self?.quickAccess.show($0) },
            delete: { [weak self] item in
                // Gone from the shelf too, so no thumbnail is left pointing at a deleted file.
                self?.quickAccess.dismiss(item.id, animated: false)
                self?.history.remove(item)
            },
            clear: { [weak self] in
                self?.quickAccess.dismissAll()
                self?.history.clear()
            },
            showSettings: { [weak self] in self?.settingsWindow.show() }
        )

        coordinator.onSessionChange = { [weak self] title in
            self?.statusItem.setSession(title: title, stop: { self?.coordinator.stopActiveSession() })
        }

        quickAccess.onCopy = { item in
            Clipboard.copyImage(at: item.fileURL)
            HUD.toast("Copied")
        }
        quickAccess.onSave = { [weak self] item in self?.coordinator.save(item) ?? false }
        quickAccess.onAnnotate = { [weak self] item in self?.annotate(item) }
        quickAccess.onPin = { [weak self] item in self?.pin(item) }

        // Re-register hotkeys whenever they change; suspend them while Settings records a shortcut.
        settings.$hotkeys.combineLatest(settings.$isRecordingHotkey)
            .receive(on: RunLoop.main)
            .sink { [weak self] hotkeys, recording in self?.registerHotkeys(recording ? [:] : hotkeys) }
            .store(in: &subscriptions)

        log.notice("launched; screen recording granted: \(ScreenPermission.isGranted, privacy: .public)")
        // History expiry runs at launch, when the setting changes, at midnight and on wake. No timer.
        purgeExpiredHistory()
        settings.$historyExpiryDays.dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.purgeExpiredHistory() }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
            .merge(with: NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification))
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.purgeExpiredHistory() }
            .store(in: &subscriptions)

        if !ScreenPermission.isGranted {
            permissionWindow.show()
        }
        handleDebugArguments()
    }

    /// Automation: `open snapshelf://capture/area` (or window, screen, text), `snapshelf://reopen`, `snapshelf://settings`.
    /// `snapshelf://capture/area?x=10&y=10&w=300&h=200` captures that rectangle (points, main display) with no selection UI.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "snapshelf" {
            let target = url.pathComponents.dropFirst().first ?? ""
            switch (url.host ?? "", target) {
            case ("capture", "area"):
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                func value(_ name: String) -> CGFloat? {
                    query.first { $0.name == name }?.value.flatMap(Double.init).map { CGFloat($0) }
                }
                if let x = value("x"), let y = value("y"), let w = value("w"), let h = value("h") {
                    coordinator.captureArea(CGRect(x: x, y: y, width: w, height: h), displayID: CGMainDisplayID())
                } else {
                    coordinator.perform(.area)
                }
            case ("capture", "web"):
                // `?url=https://…` captures that page; without it, the address on the clipboard is used.
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                if let address = query.first(where: { $0.name == "url" })?.value {
                    coordinator.captureWebPage(from: address)
                } else {
                    coordinator.perform(.webPage)
                }
            case ("capture", "window"):
                // `?id=<window number>` captures that window directly, with no picker.
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                if let id = query.first(where: { $0.name == "id" })?.value.flatMap(UInt32.init) {
                    coordinator.captureWindow(id)
                } else {
                    coordinator.perform(.window)
                }
            case ("capture", "screen"): coordinator.perform(.fullScreen)
            case ("capture", "text"):
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                func value(_ name: String) -> CGFloat? {
                    query.first { $0.name == name }?.value.flatMap(Double.init).map { CGFloat($0) }
                }
                if let x = value("x"), let y = value("y"), let w = value("w"), let h = value("h") {
                    coordinator.recognizeText(displayID: CGMainDisplayID(), rect: CGRect(x: x, y: y, width: w, height: h))
                } else {
                    coordinator.perform(.captureText)
                }
            case ("record", _), ("capture", "scroll"):
                // With `?x=&y=&w=&h=` the session starts on that rectangle of the main display, with no selection UI.
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                func value(_ name: String) -> CGFloat? {
                    query.first { $0.name == name }?.value.flatMap(Double.init).map { CGFloat($0) }
                }
                let action: HotkeyAction = url.host == "record" ? .record : .scrollCapture
                if !coordinator.sessionActive, let x = value("x"), let y = value("y"), let w = value("w"), let h = value("h") {
                    let rect = CGRect(x: x, y: y, width: w, height: h)
                    if action == .record {
                        coordinator.startRecording(displayID: CGMainDisplayID(), rect: rect)
                    } else {
                        coordinator.startScrollCapture(displayID: CGMainDisplayID(), rect: rect)
                    }
                } else {
                    coordinator.perform(action)
                }
            case ("stop", _): coordinator.stopActiveSession()
            case ("reopen", _): coordinator.perform(.reopenLast)
            case ("settings", _): settingsWindow.show()
            case ("annotate", _): history.mostRecent.map(annotate)
            case ("pin", _): history.mostRecent.map(pin)
            default: break
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func purgeExpiredHistory() {
        let removed = history.removeExpired(days: settings.historyExpiryDays)
        if removed > 0 { log.notice("history expiry removed \(removed) capture(s)") }
    }

    private func registerHotkeys(_ hotkeys: [HotkeyAction: Hotkey]) {
        let bindings: [(Hotkey, () -> Void)] = hotkeys.map { action, hotkey in
            (hotkey, { [weak self] in self?.coordinator.perform(action) })
        }
        let failed = HotkeyCenter.shared.register(bindings)
        if !failed.isEmpty {
            HUD.toast("Shortcut in use elsewhere: \(failed.map(\.displayString).joined(separator: ", "))", seconds: 3)
        }
    }

    private func annotate(_ item: CaptureItem) {
        guard item.isStillImage else {
            HUD.toast("Recordings cannot be annotated")
            return
        }
        let editor = AnnotationEditor(
            item: item,
            onSave: { [weak self] image, scale in
                guard let self else { return }
                Task {
                    // The edited image becomes a capture of its own: in history, on the shelf, and in the save folder.
                    if let edited = try? await self.coordinator.deliver(image, scale: scale, mode: "edited", forceOverlay: true),
                       !self.settings.saveToFolder {
                        self.coordinator.save(edited)
                    }
                }
            },
            onClose: { [weak self] closed in
                self?.editors.removeAll { $0 === closed }
                if let index = self?.inUse.firstIndex(of: item.id) { self?.inUse.remove(at: index) }
            }
        )
        guard let editor else {
            HUD.toast("Could not open that capture")
            return
        }
        editors.append(editor)
        inUse.append(item.id)
        editor.show()
    }

    private func pin(_ item: CaptureItem) {
        guard item.isStillImage else {
            HUD.toast("Recordings cannot be pinned")
            return
        }
        pins.pin(item)
    }

    /// `--inject <image>` runs an image file through the after-capture pipeline, for testing without a capture.
    private func handleDebugArguments() {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--inject"), index + 1 < args.count,
              let image = ImageCodec.load(URL(fileURLWithPath: args[index + 1])) else { return }
        Task {
            _ = try? await coordinator.deliver(image, scale: 2, mode: "injected", forceOverlay: true)
        }
    }

    /// An accessory app shows no menu bar, but text fields still need the Edit shortcuts, and ⌘W / ⌘Q / ⌘, should work.
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit SnapShelf", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Delete", action: #selector(NSText.delete(_:)), keyEquivalent: "\u{8}"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        windowItem.submenu = window
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }

    @objc private func showSettings() {
        settingsWindow.show()
    }
}
