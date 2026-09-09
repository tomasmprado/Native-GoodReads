import AppKit
import Carbon.HIToolbox

/// Registers ⌥Space system-wide.
///
/// Carbon's RegisterEventHotKey is ancient but it's the only route that doesn't
/// require Accessibility permission — NSEvent's global monitor does, and asking
/// for that on first launch to run a search box is a bad trade.
final class HotKeyCenter {

    static let shared = HotKeyCenter()

    var onTrigger: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    private init() { }

    func register() {
        guard hotKeyRef == nil else { return }

        // Register the physical hotkey first. If another app already owns
        // ⌥Space this fails and leaves `hotKeyRef` untouched — installing the
        // event handler only after success means a failed attempt doesn't
        // leave a handler behind for `register()` to duplicate on retry.
        let id = EventHotKeyID(signature: OSType(0x47524453), id: 1)   // 'GRDS'
        let status = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(optionKey),
            id,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard status == noErr else {
            NSLog("Goodreads: couldn't register ⌥Space (error \(status)) — another app may own it.")
            return
        }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        // A C callback can't capture, so `self` travels through userData.
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData -> OSStatus in
                guard let userData else { return noErr }
                let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { center.onTrigger?() }
                return noErr
            },
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
        hotKeyRef = nil
        handlerRef = nil
    }
}
