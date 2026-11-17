import AppKit
import SnapShelfCapture
import SwiftUI

final class PermissionModel: ObservableObject {
    @Published var granted = ScreenPermission.isGranted
    /// True once the system prompt has been shown, so we can explain the relaunch.
    @Published var requested = false

    func refresh() {
        granted = ScreenPermission.isGranted
    }
}

struct PermissionView: View {
    @ObservedObject var model: PermissionModel
    let relaunch: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: model.granted ? "checkmark.shield.fill" : "lock.shield")
                    .font(.system(size: 34))
                    .foregroundStyle(model.granted ? .green : .accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.granted ? "Screen Recording access is on" : "SnapShelf needs Screen Recording access")
                        .font(.headline)
                    Text(model.granted ? "You're ready to capture." : "Without it, macOS only lets apps capture an empty desktop.")
                        .foregroundStyle(.secondary)
                }
            }

            if !model.granted {
                Text("""
                macOS treats every screenshot tool as screen recording. SnapShelf uses the access only \
                when you press a capture hotkey, to read the pixels of the area, window or display you \
                pick. Nothing is recorded in the background, and nothing leaves this Mac: the app has no \
                network access.
                """)
                .fixedSize(horizontal: false, vertical: true)

                Text("""
                1. Click Grant Access, or open System Settings › Privacy & Security › Screen & System \
                Audio Recording.
                2. Turn on SnapShelf.
                3. Relaunch SnapShelf so the change takes effect.
                """)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if model.requested {
                    Label("Access still looks off. If you have already turned it on, relaunch SnapShelf.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack {
                if model.granted {
                    Spacer()
                    Button("Done", action: close).keyboardShortcut(.defaultAction)
                } else {
                    Button("Open System Settings") {
                        model.requested = true
                        ScreenPermission.openSystemSettings()
                    }
                    Button("Relaunch SnapShelf", action: relaunch)
                    Spacer()
                    Button("Grant Access") {
                        ScreenPermission.request()
                        model.requested = true
                        model.refresh()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 500)
    }
}

@MainActor
final class PermissionWindowController {
    private var window: NSWindow?
    private let model = PermissionModel()
    private var observer: NSObjectProtocol?

    func show() {
        model.refresh()
        if window == nil {
            let view = PermissionView(model: model, relaunch: { PermissionWindowController.relaunch() }, close: { [weak self] in
                self?.window?.close()
            })
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = "Welcome to SnapShelf"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.center()
            window = w
            // Re-check when the user comes back from System Settings; no polling.
            observer = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.model.refresh() }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }
}
