import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // `--dock` runs with a Dock icon, which lets UI automation tools see the app.
    app.setActivationPolicy(CommandLine.arguments.contains("--dock") ? .regular : .accessory)
    // The delegate is held weakly by NSApplication; keep it alive for the life of the process.
    withExtendedLifetime(delegate) {
        app.run()
    }
}
