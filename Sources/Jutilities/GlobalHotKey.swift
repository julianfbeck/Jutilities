import AppKit
import Carbon

@MainActor
final class GlobalHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?

    func register(action: @escaping () -> Void) -> Bool {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let instance = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in instance.action?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { return false }
        let identifier = EventHotKeyID(signature: 0x4A55544C, id: 1)
        let registered = RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(cmdKey | shiftKey), identifier,
                                            GetApplicationEventTarget(), 0, &hotKey) == noErr
        if !registered, let handler { RemoveEventHandler(handler); self.handler = nil }
        return registered
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        if let handler { RemoveEventHandler(handler); self.handler = nil }
        action = nil
    }
}
