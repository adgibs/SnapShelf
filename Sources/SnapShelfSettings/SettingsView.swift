import AppKit
import ServiceManagement
import SnapShelfKit
import SwiftUI

/// Click, then press a shortcut. Esc cancels, Delete clears.
struct HotkeyRecorder: View {
    @ObservedObject var settings: AppSettings
    let action: HotkeyAction
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: toggle) {
                Text(recording ? "Press shortcut…" : (settings.hotkeys[action]?.displayString ?? "None"))
                    .font(.body.monospacedDigit())
                    .frame(minWidth: 110)
            }
            .accessibilityLabel("\(action.title) shortcut")
            if settings.hotkeys[action] != nil, !recording {
                Button {
                    settings.setHotkey(nil, for: action)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Remove shortcut")
                .accessibilityLabel("Remove \(action.title) shortcut")
            }
        }
        .onDisappear(perform: stop)
    }

    private func toggle() {
        recording ? stop() : start()
    }

    private func start() {
        recording = true
        settings.isRecordingHotkey = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let code = UInt32(event.keyCode)
            let mods = Hotkey.carbonModifiers(from: event.modifierFlags)
            if code == 53, mods == 0 { // Esc
                stop()
                return nil
            }
            if code == 51 || code == 117, mods == 0 { // Delete
                settings.setHotkey(nil, for: action)
                stop()
                return nil
            }
            // Needs ⌘, ⌃ or ⌥ (or a function key) so plain typing is never swallowed.
            let strong = mods & (Hotkey.command | Hotkey.control | Hotkey.option) != 0
            guard strong || Hotkey.isFunctionKey(code) else {
                NSSound.beep()
                return nil
            }
            settings.setHotkey(Hotkey(keyCode: code, modifiers: mods), for: action)
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        settings.isRecordingHotkey = false
    }
}

final class LaunchAtLogin: ObservableObject {
    @Published var isEnabled = SMAppService.mainApp.status == .enabled
    @Published var error: String?

    func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}

public struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @StateObject private var launchAtLogin = LaunchAtLogin()

    public init(settings: AppSettings) {
        self.settings = settings
    }

    private var namePreview: String {
        FileNamer.baseName(pattern: settings.fileNamePattern, date: Date(), mode: "area", pixelWidth: 1280, pixelHeight: 720)
            + "." + settings.format.fileExtension
    }

    public var body: some View {
        Form {
            Section("Hotkeys") {
                ForEach(HotkeyAction.allCases) { action in
                    LabeledContent(action.title) {
                        HotkeyRecorder(settings: settings, action: action)
                    }
                }
            }

            Section("After capture") {
                Toggle("Copy to clipboard", isOn: $settings.copyToClipboard)
                Toggle("Show quick access overlay", isOn: $settings.showOverlay)
                Toggle("Save to folder", isOn: $settings.saveToFolder)
                LabeledContent("Save folder") {
                    HStack {
                        Text(settings.saveFolderPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(.secondary)
                        Button("Choose…", action: chooseFolder)
                    }
                }
                TextField("File name", text: $settings.fileNamePattern)
                Text("Preview: \(namePreview)\nTokens: \(FileNamer.tokens.joined(separator: " "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Format", selection: $settings.format) {
                    ForEach(ImageFormat.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section("Capture") {
                Picker("Self-timer", selection: $settings.selfTimerSeconds) {
                    Text("Off").tag(0)
                    Text("3 seconds").tag(3)
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                }
                Toggle("Hide desktop icons while capturing", isOn: $settings.hideDesktopIcons)
            }

            Section("Quick access overlay") {
                Picker("Position", selection: $settings.corner) {
                    ForEach(OverlayCorner.allCases) { Text($0.title).tag($0) }
                }
                Picker("Dismiss automatically", selection: Binding(
                    get: { settings.autoDismissSeconds > 0 },
                    set: { settings.autoDismissSeconds = $0 ? 10 : 0 }
                )) {
                    Text("Never").tag(false)
                    Text("After a delay").tag(true)
                }
                if settings.autoDismissSeconds > 0 {
                    Stepper(value: $settings.autoDismissSeconds, in: 1...600) {
                        Text("Dismiss after \(settings.autoDismissSeconds) seconds")
                    }
                }
            }

            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.set($0) }
                ))
                if let error = launchAtLogin.error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 640)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = settings.saveFolderURL
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            settings.saveFolderPath = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }
}

@MainActor
public final class SettingsWindowController {
    private var window: NSWindow?
    private let settings: AppSettings

    public init(settings: AppSettings) {
        self.settings = settings
    }

    public func show() {
        if window == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(settings: settings)))
            w.title = "SnapShelf Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
