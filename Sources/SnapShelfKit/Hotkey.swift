import AppKit

/// A global hotkey: a virtual key code plus Carbon modifier flags.
public struct Hotkey: Codable, Equatable, Hashable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    // Carbon modifier masks (cmdKey, shiftKey, optionKey, controlKey).
    public static let command: UInt32 = 0x0100
    public static let shift: UInt32 = 0x0200
    public static let option: UInt32 = 0x0800
    public static let control: UInt32 = 0x1000

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    public static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= command }
        if flags.contains(.shift) { result |= shift }
        if flags.contains(.option) { result |= option }
        if flags.contains(.control) { result |= control }
        return result
    }

    /// For example "⌃⇧4".
    public var displayString: String {
        var s = ""
        if modifiers & Hotkey.control != 0 { s += "⌃" }
        if modifiers & Hotkey.option != 0 { s += "⌥" }
        if modifiers & Hotkey.shift != 0 { s += "⇧" }
        if modifiers & Hotkey.command != 0 { s += "⌘" }
        return s + Hotkey.keyName(for: keyCode)
    }

    public static func isFunctionKey(_ keyCode: UInt32) -> Bool {
        [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111].contains(keyCode)
    }

    public static func keyName(for keyCode: UInt32) -> String {
        keyNames[keyCode] ?? "Key \(keyCode)"
    }

    private static let keyNames: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7",
        27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
        36: "↩", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
        45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space", 50: "`", 51: "⌫", 53: "⎋",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7",
        100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
}

/// Everything that can be bound to a global hotkey.
public enum HotkeyAction: String, CaseIterable, Codable, Identifiable {
    case area, window, fullScreen, reopenLast, captureText, record, scrollCapture, webPage

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .area: return "Capture Area"
        case .window: return "Capture Window"
        case .fullScreen: return "Capture Full Screen"
        case .reopenLast: return "Reopen Last Capture"
        case .captureText: return "Capture Text"
        case .record: return "Record Screen"
        case .scrollCapture: return "Scrolling Capture"
        case .webPage: return "Capture Web Page"
        }
    }

    public var symbolName: String {
        switch self {
        case .area: return "rectangle.dashed"
        case .window: return "macwindow"
        case .fullScreen: return "display"
        case .reopenLast: return "arrow.uturn.backward"
        case .captureText: return "text.viewfinder"
        case .record: return "record.circle"
        case .scrollCapture: return "arrow.up.and.down.text.horizontal"
        case .webPage: return "globe"
        }
    }

    public var defaultHotkey: Hotkey {
        let mods = Hotkey.control | Hotkey.shift
        switch self {
        case .fullScreen: return Hotkey(keyCode: 20, modifiers: mods) // ⌃⇧3
        case .area: return Hotkey(keyCode: 21, modifiers: mods)       // ⌃⇧4
        case .window: return Hotkey(keyCode: 23, modifiers: mods)     // ⌃⇧5
        case .reopenLast: return Hotkey(keyCode: 15, modifiers: mods) // ⌃⇧R
        case .captureText: return Hotkey(keyCode: 17, modifiers: mods) // ⌃⇧T
        case .record: return Hotkey(keyCode: 22, modifiers: mods)      // ⌃⇧6
        case .scrollCapture: return Hotkey(keyCode: 26, modifiers: mods) // ⌃⇧7
        case .webPage: return Hotkey(keyCode: 28, modifiers: mods)       // ⌃⇧8
        }
    }
}
