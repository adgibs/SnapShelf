import AppKit
import SnapShelfKit
import SwiftUI

/// The drag handle in the toolbar: renders the edited image to a file as the drag starts.
struct ExportDragHandle: NSViewRepresentable {
    let prepare: () -> URL?

    final class Handle: FileDragSourceView {
        var prepare: (() -> URL?)?

        override func mouseDown(with event: NSEvent) {
            fileURL = prepare?()
            super.mouseDown(with: event)
        }

        override func draw(_ dirtyRect: NSRect) {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
            guard let image = NSImage(systemSymbolName: "square.and.arrow.up.on.square", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else { return }
            let tinted = NSImage(size: image.size, flipped: false) { rect in
                image.draw(in: rect)
                NSColor.labelColor.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: CGRect(
                x: (bounds.width - image.size.width) / 2, y: (bounds.height - image.size.height) / 2,
                width: image.size.width, height: image.size.height
            ))
        }
    }

    func makeNSView(context: Context) -> Handle {
        let view = Handle()
        view.prepare = prepare
        view.toolTip = "Drag the edited image into another app"
        view.setAccessibilityLabel("Drag edited image")
        return view
    }

    func updateNSView(_ view: Handle, context: Context) { view.prepare = prepare }
}

struct EditorToolbar: View {
    @ObservedObject var model: EditorModel
    let copy: () -> Void
    let save: () -> Void
    let prepareDrag: () -> URL?

    var body: some View {
        HStack(spacing: 10) {
            Picker("Tool", selection: $model.tool) {
                ForEach(Tool.allCases) { tool in
                    Image(systemName: tool.symbol)
                        .help(tool.title)
                        .accessibilityLabel(tool.title)
                        .tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            ColorPicker("Colour", selection: Binding(
                get: { Color(nsColor: model.color) },
                set: { model.color = NSColor($0) }
            ))
            .labelsHidden()
            .help("Colour")

            Slider(value: $model.width, in: (1 * model.scale)...(12 * model.scale))
                .frame(width: 90)
                .help("Line width and text size")
                .accessibilityLabel("Line width")

            Spacer(minLength: 8)

            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(!model.canUndo)
                .help("Undo")
                .accessibilityLabel("Undo")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(!model.canRedo)
                .help("Redo")
                .accessibilityLabel("Redo")

            ExportDragHandle(prepare: prepareDrag)
                .frame(width: 30, height: 24)
            Button("Copy", action: copy)
            Button("Save", action: save).keyboardShortcut("s")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// One annotation window. `onSave` receives the rendered image.
@MainActor
public final class AnnotationEditor: NSObject, NSWindowDelegate {
    private let model: EditorModel
    private let canvas: AnnotationCanvas
    private let window: NSWindow
    private let baseName: String
    private let onSave: (CGImage, CGFloat) -> Void
    private let onClose: (AnnotationEditor) -> Void
    private var lastExportFolder: URL?

    /// Where drag exports are written. Emptied at launch and as each editor moves on.
    public static var exportDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("SnapShelf-drag", isDirectory: true)
    }

    /// Removes every leftover drag export. Call once at launch.
    public static func purgeExports() {
        try? FileManager.default.removeItem(at: exportDirectory)
    }

    public init?(item: CaptureItem, onSave: @escaping (CGImage, CGFloat) -> Void, onClose: @escaping (AnnotationEditor) -> Void) {
        guard let image = ImageCodec.load(item.fileURL) else { return nil }
        model = EditorModel(image: image, scale: CGFloat(item.scale))
        canvas = AnnotationCanvas(model: model)
        baseName = item.baseName
        self.onSave = onSave
        self.onClose = onClose

        let screen = NSScreen.underMouse.visibleFrame
        let pointSize = CGSize(width: CGFloat(image.width) / model.scale, height: CGFloat(image.height) / model.scale)
        let size = CGSize(
            width: min(max(pointSize.width + 32, 860), screen.width * 0.9),
            height: min(max(pointSize.height + 32 + 44, 480), screen.height * 0.9)
        )
        window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
        )
        super.init()

        let toolbar = NSHostingView(rootView: EditorToolbar(
            model: model,
            copy: { [weak self] in self?.copy() },
            save: { [weak self] in self?.save() },
            prepareDrag: { [weak self] in self?.exportToTemporaryFile() }
        ))
        let container = NSView()
        for view in [toolbar, canvas] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(view)
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: container.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window.contentView = container
        window.title = "Annotate — \(item.baseName)"
        window.minSize = CGSize(width: 860, height: 360)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
    }

    public func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
    }

    public func windowWillClose(_ notification: Notification) {
        removeLastExport()
        onClose(self)
    }

    private func removeLastExport() {
        if let folder = lastExportFolder { try? FileManager.default.removeItem(at: folder) }
        lastExportFolder = nil
    }

    private func rendered() -> CGImage? {
        canvas.finishEditing()
        return model.render()
    }

    private func copy() {
        guard let image = rendered(), let data = ImageCodec.encode(image, format: .png, scale: model.scale) else { return }
        Clipboard.copy(pngData: data)
    }

    private func save() {
        guard let image = rendered() else { return }
        onSave(image, model.scale)
    }

    private func exportToTemporaryFile() -> URL? {
        // Runs on every press of the drag handle, so the previous export is removed first.
        removeLastExport()
        guard let image = rendered() else { return nil }
        let folder = AnnotationEditor.exportDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        lastExportFolder = folder
        let url = folder.appendingPathComponent("\(baseName) edited.png")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try ImageCodec.write(image, to: url, format: .png, scale: model.scale)
            return url
        } catch {
            return nil
        }
    }
}
