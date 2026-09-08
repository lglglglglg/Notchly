import Carbon.HIToolbox

final class HotKeyRegistrar {
    private let keyCode: UInt32
    private let modifiers: UInt32
    private let action: () -> Void
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    init(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.action = action
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }

    func register() throws {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handlerStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            Self.handleEvent,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handler
        )
        guard handlerStatus == noErr else { throw HotKeyError.installHandler(handlerStatus) }

        let identifier = EventHotKeyID(signature: OSType(0x4E544348), id: 1) // "NTCH"
        let registerStatus = RegisterEventHotKey(keyCode, modifiers, identifier, GetEventDispatcherTarget(), 0, &hotKey)
        guard registerStatus == noErr else { throw HotKeyError.register(registerStatus) }
    }

    private static let handleEvent: EventHandlerUPP = { _, _, userData in
        guard let userData else { return noErr }
        let registrar = Unmanaged<HotKeyRegistrar>.fromOpaque(userData).takeUnretainedValue()
        // Carbon delivers hot-key events through the application's main event dispatcher.
        registrar.action()
        return noErr
    }
}

enum HotKeyError: Error { case installHandler(OSStatus), register(OSStatus) }
