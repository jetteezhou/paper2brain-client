import Carbon.HIToolbox

/// A global hot key (Idea2do's GlobalHotKey; ⌃⌥空格 by default): Carbon hot keys need no Accessibility permission and fire only for this combination.
@MainActor
final class GlobalHotKey {
    static let displayName = "⌃⌥空格"

    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private let id: UInt32

    init?(key: Int = kVK_Space, modifiers: Int = controlKey | optionKey, id: UInt32 = 1, action: @escaping () -> Void) {
        self.action = action
        self.id = id
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            let target = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
            var pressed = EventHotKeyID()  // every instance hears every hot key: act only on its own
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            guard pressed.id == target.id else { return OSStatus(eventNotHandledErr) }
            Task { @MainActor in target.action() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { return nil }
        let hotKeyID = EventHotKeyID(signature: OSType(0x7032_626A), id: id)  // 'p2bj'
        guard RegisterEventHotKey(UInt32(key), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0, &hotKey) == noErr else {
            RemoveEventHandler(handler); handler = nil
            return nil
        }
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil; handler = nil
    }
}
