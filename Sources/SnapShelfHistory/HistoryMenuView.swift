import AppKit
import SnapShelfKit
import SwiftUI

/// A command row at the top of the menu.
public struct MenuCommand: Identifiable {
    public let id: String
    public let title: String
    public let symbol: String
    public let shortcut: String?
    public let action: () -> Void

    public init(id: String, title: String, symbol: String, shortcut: String?, action: @escaping () -> Void) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.shortcut = shortcut
        self.action = action
    }
}

public struct HistoryActions {
    public var open: (CaptureItem) -> Void
    public var copy: (CaptureItem) -> Void
    public var reveal: (CaptureItem) -> Void
    public var dragEnded: (Bool) -> Void
    public var delete: (CaptureItem) -> Void
    public var clear: () -> Void
    public var settings: () -> Void
    public var quit: () -> Void

    public init(
        open: @escaping (CaptureItem) -> Void, copy: @escaping (CaptureItem) -> Void,
        reveal: @escaping (CaptureItem) -> Void, dragEnded: @escaping (Bool) -> Void,
        delete: @escaping (CaptureItem) -> Void, clear: @escaping () -> Void, settings: @escaping () -> Void, quit: @escaping () -> Void
    ) {
        self.open = open
        self.copy = copy
        self.reveal = reveal
        self.dragEnded = dragEnded
        self.delete = delete
        self.clear = clear
        self.settings = settings
        self.quit = quit
    }
}

/// Wraps the AppKit drag source so a history row drags out as a file.
struct FileDragArea: NSViewRepresentable {
    let url: URL
    let image: NSImage?
    let onClick: () -> Void
    let onDragEnded: (Bool) -> Void

    func makeNSView(context: Context) -> FileDragSourceView {
        let view = FileDragSourceView()
        update(view)
        return view
    }

    func updateNSView(_ view: FileDragSourceView, context: Context) { update(view) }

    private func update(_ view: FileDragSourceView) {
        view.fileURL = url
        view.dragImage = image
        view.onClick = onClick
        view.onDragEnded = onDragEnded
        view.toolTip = "Drag into another app, or click to reopen"
    }
}

enum ThumbnailCache {
    static let cache = NSCache<NSURL, NSImage>()

    static func image(for item: CaptureItem) -> NSImage? {
        let key = item.thumbnailURL as NSURL
        if let hit = cache.object(forKey: key) { return hit }
        guard let image = NSImage(contentsOf: item.thumbnailURL) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

struct HistoryRow: View {
    let item: CaptureItem
    let actions: HistoryActions
    @State private var hovering = false
    /// True after the bin is clicked, while the row asks "Delete?".
    @State private var confirmingDelete = false

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f
    }()

    var body: some View {
        let thumb = ThumbnailCache.image(for: item)
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Group {
                    if let thumb {
                        Image(nsImage: thumb).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Image(systemName: "photo").foregroundStyle(.secondary)
                    }
                }
                .frame(width: 64, height: 42)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                .clipShape(RoundedRectangle(cornerRadius: 5))

                VStack(alignment: .leading, spacing: 2) {
                    Text(HistoryRow.timeFormatter.string(from: item.date))
                        .font(.callout)
                        .lineLimit(1)
                    Text("\(item.sizeDescription) · \(item.mode)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .overlay(
                FileDragArea(
                    url: item.fileURL, image: thumb,
                    onClick: { actions.open(item) }, onDragEnded: actions.dragEnded
                )
            )

            if confirmingDelete {
                // Asked in the row itself: an alert would close the menu.
                Button("Delete", role: .destructive) { actions.delete(item) }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .controlSize(.small)
                    .accessibilityLabel("Confirm delete")
                Button("Cancel") { confirmingDelete = false }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            } else {
                Button { actions.copy(item) } label: { Image(systemName: "doc.on.doc") }
                    .help("Copy")
                    .accessibilityLabel("Copy")
                Button { actions.reveal(item) } label: { Image(systemName: "folder") }
                    .help("Reveal in Finder")
                    .accessibilityLabel("Reveal in Finder")
                Button { confirmingDelete = true } label: { Image(systemName: "trash") }
                    .help("Delete from history")
                    .accessibilityLabel("Delete from history")
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(hovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .onHover { inside in
            hovering = inside
            // Moving away withdraws the question, so a stray click later cannot delete.
            if !inside { confirmingDelete = false }
        }
    }
}

struct CommandRow: View {
    let title: String
    let symbol: String
    let shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 18)
                Text(title)
                Spacer()
                if let shortcut {
                    Text(shortcut).foregroundStyle(.secondary).font(.callout.monospacedDigit())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(hovering ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The content of the menu bar popover: capture commands, recent captures, then Settings and Quit.
public struct HistoryMenuView: View {
    @ObservedObject var store: HistoryStore
    let commands: [MenuCommand]
    let actions: HistoryActions
    @State private var confirmingClear = false

    public init(store: HistoryStore, commands: [MenuCommand], actions: HistoryActions) {
        self.store = store
        self.commands = commands
        self.actions = actions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(commands) { command in
                CommandRow(title: command.title, symbol: command.symbol, shortcut: command.shortcut, action: command.action)
            }
            Divider().padding(.vertical, 4)

            HStack {
                Text("Recent captures").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !store.items.isEmpty {
                    if confirmingClear {
                        Text("Delete all \(store.items.count)?").font(.caption)
                        Button("Delete all", role: .destructive) {
                            confirmingClear = false
                            actions.clear()
                        }
                        .buttonStyle(.borderedProminent).tint(.red).controlSize(.mini)
                        Button("Cancel") { confirmingClear = false }
                            .buttonStyle(.bordered).controlSize(.mini)
                    } else {
                        Button("Clear") { confirmingClear = true }.buttonStyle(.borderless).font(.caption)
                    }
                }
            }
            .padding(.horizontal, 10)

            if store.items.isEmpty {
                Text("Captures you take will appear here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 18)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.items) { item in
                            HistoryRow(item: item, actions: actions)
                        }
                    }
                }
                .frame(height: min(CGFloat(store.items.count) * 52, 364))
            }

            Divider().padding(.vertical, 4)
            CommandRow(title: "Settings…", symbol: "gearshape", shortcut: "⌘,", action: actions.settings)
            CommandRow(title: "Quit SnapShelf", symbol: "power", shortcut: "⌘Q", action: actions.quit)
        }
        .padding(6)
        .frame(width: 320)
    }
}
