import AppKit
import Carbon.HIToolbox

/// Carbon's `RegisterEventHotKey` is still the only way to claim a system-wide
/// shortcut without an Accessibility prompt, and — unlike an `NSEvent` global
/// monitor — it *consumes* the keystroke so it doesn't also reach the frontmost
/// app. Every Electron app on the machine ends up calling it for the same reason.
@MainActor
final class HotKeyManager {
    enum RegistrationError: Error, CustomStringConvertible {
        /// -9868. Sequoia refuses combos modified only by shift and/or option, so
        /// key-loggers can't observe alternate characters like ⇧⌥O (Ø) in passwords.
        case rejectedModifiers
        case noModifier
        case failed(OSStatus)

        var description: String {
            switch self {
            case .rejectedModifiers:
                return "macOS won't allow a shortcut using only ⇧ and ⌥. Add ⌘ or ⌃."
            case .noModifier:
                return "Add at least one modifier key."
            case .failed(let status):
                return "Couldn't register that shortcut (error \(status)). Another app may already use it."
            }
        }
    }

    private static let signature: OSType = 0x4342_484B  // 'CBHK'
    private static let defaultsKey = "togglePanelHotKey"

    private var eventHandler: EventHandlerRef?
    private var hotKeyRef: EventHotKeyRef?

    /// The combo the user configured, whether or not it is registered right now —
    /// `suspend()` drops the registration but keeps this so `resume()` can restore it.
    private(set) var combo: KeyCombo?

    var onFire: (() -> Void)?

    // No deinit: a nonisolated one can't touch this actor's state under Swift 6, and
    // the manager lives as long as the process does (StatusItemController owns it,
    // AppDelegate owns that), so the registration is reclaimed at exit regardless.

    // MARK: - Persistence

    static var saved: KeyCombo? {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey) else { return nil }
            return try? JSONDecoder().decode(KeyCombo.self, from: data)
        }
        set {
            guard let newValue, let data = try? JSONEncoder().encode(newValue) else {
                UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
                return
            }
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    // MARK: - Registration

    func register(_ combo: KeyCombo) throws {
        guard combo.hasModifier else { throw RegistrationError.noModifier }
        self.releaseHotKey()
        try self.installHandlerIfNeeded()
        try self.claim(combo)
        self.combo = combo
    }

    func unregister() {
        self.releaseHotKey()
        self.combo = nil
    }

    /// Drop the system registration but remember the combo.
    ///
    /// `NSMenu` runs a modal tracking loop while the panel is open, which starves
    /// Carbon hotkey delivery: the press isn't discarded, it's *queued*, and lands
    /// the moment the menu closes — reopening the panel the user just dismissed.
    /// Unregistering for the duration means there is nothing to queue.
    /// `StatusItemController` watches for the same combo with a local monitor instead.
    func suspend() {
        self.releaseHotKey()
    }

    func resume() {
        guard let combo = self.combo, self.hotKeyRef == nil else { return }
        // A combo that registered once will almost always register again; if the OS
        // refuses now, the shortcut is simply inert until Settings sets it again.
        try? self.claim(combo)
    }

    // MARK: - Carbon plumbing

    private func installHandlerIfNeeded() throws {
        guard self.eventHandler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            claudeBarHotKeyHandler,
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &self.eventHandler)
        guard status == noErr else { throw RegistrationError.failed(status) }
    }

    private func claim(_ combo: KeyCombo) throws {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            combo.keyCode,
            combo.modifiers,
            EventHotKeyID(signature: Self.signature, id: 1),
            GetApplicationEventTarget(),
            0,
            &ref)
        guard status == noErr, let ref else {
            throw status == -9868 ? RegistrationError.rejectedModifiers : RegistrationError.failed(status)
        }
        self.hotKeyRef = ref
    }

    private func releaseHotKey() {
        guard let ref = self.hotKeyRef else { return }
        UnregisterEventHotKey(ref)
        self.hotKeyRef = nil
    }

    fileprivate func fire() {
        self.onFire?()
    }
}

/// Carbon hands back a bare C function pointer, so the manager travels as `userData`
/// rather than being captured. Carbon dispatches this on the main thread, which is
/// what makes `assumeIsolated` sound here — the same idiom `StatusItemController`
/// already uses for `NSMenuDelegate` callbacks.
private func claudeBarHotKeyHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let userData else { return noErr }
    let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated { manager.fire() }
    return noErr
}
