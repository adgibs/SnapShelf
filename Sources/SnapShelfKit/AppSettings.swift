import Combine
import Foundation

public enum RecordingFormat: String, CaseIterable, Identifiable {
    case mp4, gif
    public var id: String { rawValue }
    public var title: String { self == .mp4 ? "MP4" : "GIF" }
}

public enum OverlayCorner: String, CaseIterable, Identifiable {
    case bottomLeft, bottomRight
    public var id: String { rawValue }
    public var title: String { self == .bottomLeft ? "Bottom left" : "Bottom right" }
}

/// User preferences, backed by UserDefaults.
public final class AppSettings: ObservableObject {
    public static let shared = AppSettings()

    private let defaults: UserDefaults

    private enum Key {
        static let copy = "copyToClipboard"
        static let save = "saveToFolder"
        static let overlay = "showOverlay"
        static let folder = "saveFolderPath"
        static let pattern = "fileNamePattern"
        static let format = "imageFormat"
        static let corner = "overlayCorner"
        static let autoDismiss = "autoDismissSeconds"
        static let hotkeys = "hotkeys"
        static let timer = "selfTimerSeconds"
        static let hideIcons = "hideDesktopIcons"
        static let expiry = "historyExpiryDays"
        static let recording = "recordingFormat"
    }

    public static let defaultSaveFolderPath = "~/Pictures/SnapShelf"

    @Published public var copyToClipboard: Bool { didSet { defaults.set(copyToClipboard, forKey: Key.copy) } }
    @Published public var saveToFolder: Bool { didSet { defaults.set(saveToFolder, forKey: Key.save) } }
    @Published public var showOverlay: Bool { didSet { defaults.set(showOverlay, forKey: Key.overlay) } }
    @Published public var saveFolderPath: String { didSet { defaults.set(saveFolderPath, forKey: Key.folder) } }
    @Published public var fileNamePattern: String { didSet { defaults.set(fileNamePattern, forKey: Key.pattern) } }
    @Published public var format: ImageFormat { didSet { defaults.set(format.rawValue, forKey: Key.format) } }
    @Published public var corner: OverlayCorner { didSet { defaults.set(corner.rawValue, forKey: Key.corner) } }
    /// 0 means never.
    @Published public var autoDismissSeconds: Int { didSet { defaults.set(autoDismissSeconds, forKey: Key.autoDismiss) } }
    /// Actions without an entry have no hotkey.
    @Published public var hotkeys: [HotkeyAction: Hotkey] { didSet { persistHotkeys() } }
    /// 0 means no delay.
    @Published public var selfTimerSeconds: Int { didSet { defaults.set(selfTimerSeconds, forKey: Key.timer) } }
    @Published public var hideDesktopIcons: Bool { didSet { defaults.set(hideDesktopIcons, forKey: Key.hideIcons) } }

    /// Captures older than this many days are deleted from history. 0 means keep until pushed out.
    @Published public var historyExpiryDays: Int { didSet { defaults.set(historyExpiryDays, forKey: Key.expiry) } }

    @Published public var recordingFormat: RecordingFormat { didSet { defaults.set(recordingFormat.rawValue, forKey: Key.recording) } }

    /// True while Settings is recording a shortcut; global hotkeys are suspended. Not persisted.
    @Published public var isRecordingHotkey = false

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        copyToClipboard = defaults.object(forKey: Key.copy) as? Bool ?? true
        saveToFolder = defaults.object(forKey: Key.save) as? Bool ?? false
        showOverlay = defaults.object(forKey: Key.overlay) as? Bool ?? true
        saveFolderPath = defaults.string(forKey: Key.folder) ?? AppSettings.defaultSaveFolderPath
        fileNamePattern = defaults.string(forKey: Key.pattern) ?? FileNamer.defaultPattern
        format = ImageFormat(rawValue: defaults.string(forKey: Key.format) ?? "") ?? .png
        corner = OverlayCorner(rawValue: defaults.string(forKey: Key.corner) ?? "") ?? .bottomLeft
        autoDismissSeconds = max(0, defaults.integer(forKey: Key.autoDismiss))
        selfTimerSeconds = max(0, defaults.integer(forKey: Key.timer))
        hideDesktopIcons = defaults.bool(forKey: Key.hideIcons)
        historyExpiryDays = max(0, defaults.integer(forKey: Key.expiry))
        recordingFormat = RecordingFormat(rawValue: defaults.string(forKey: Key.recording) ?? "") ?? .mp4

        if let data = defaults.data(forKey: Key.hotkeys),
           let stored = try? JSONDecoder().decode([String: Hotkey].self, from: data) {
            var map: [HotkeyAction: Hotkey] = [:]
            for (name, key) in stored {
                if let action = HotkeyAction(rawValue: name) { map[action] = key }
            }
            // Actions added in a later version get their default once.
            let known = Set(defaults.stringArray(forKey: Key.hotkeys + ".known") ?? [])
            for action in HotkeyAction.allCases where !known.contains(action.rawValue) && map[action] == nil {
                if !map.values.contains(action.defaultHotkey) { map[action] = action.defaultHotkey }
            }
            hotkeys = map
        } else {
            hotkeys = Dictionary(uniqueKeysWithValues: HotkeyAction.allCases.map { ($0, $0.defaultHotkey) })
        }
        defaults.set(HotkeyAction.allCases.map(\.rawValue), forKey: Key.hotkeys + ".known")
    }

    public var saveFolderURL: URL {
        URL(fileURLWithPath: (saveFolderPath as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Binds `hotkey` to `action`, taking it away from any other action that had it.
    public func setHotkey(_ hotkey: Hotkey?, for action: HotkeyAction) {
        var map = hotkeys
        if let hotkey {
            for (other, existing) in map where other != action && existing == hotkey {
                map[other] = nil
            }
        }
        map[action] = hotkey
        hotkeys = map
    }

    private func persistHotkeys() {
        let stored = Dictionary(uniqueKeysWithValues: hotkeys.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(stored) {
            defaults.set(data, forKey: Key.hotkeys)
        }
    }
}
