import Carbon.HIToolbox
import SnapShelfKit

/// Global hotkeys through Carbon's RegisterEventHotKey, which needs no Accessibility permission.
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    private var refs: [EventHotKeyRef] = []
    private var handlers: [UInt32: () -> Void] = [:]
    private var eventHandler: EventHandlerRef?
    private let signature: OSType = 0x534E_5348 // 'SNSH'

    private init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &id
            )
            if status == noErr { HotkeyCenter.shared.fire(id.id) }
            return noErr
        }, 1, &spec, nil, &eventHandler)
    }

    /// Replaces every registered hotkey. Returns the hotkeys the system refused.
    @discardableResult
    func register(_ bindings: [(Hotkey, () -> Void)]) -> [Hotkey] {
        unregisterAll()
        var failed: [Hotkey] = []
        for (index, binding) in bindings.enumerated() {
            let id = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                binding.0.keyCode, binding.0.modifiers, EventHotKeyID(signature: signature, id: id),
                GetApplicationEventTarget(), 0, &ref
            )
            if status == noErr, let ref {
                refs.append(ref)
                handlers[id] = binding.1
            } else {
                failed.append(binding.0)
            }
        }
        return failed
    }

    func unregisterAll() {
        for ref in refs { UnregisterEventHotKey(ref) }
        refs.removeAll()
        handlers.removeAll()
    }

    private func fire(_ id: UInt32) {
        handlers[id]?()
    }
}
