import AppKit
import Carbon.HIToolbox
import SwiftUI

extension KeyCombo {
    /// Builds a combo from a recorded keystroke. Returns nil for an unmodified key —
    /// binding a bare key would swallow it system-wide.
    init?(event: NSEvent) {
        var modifiers: UInt32 = 0
        if event.modifierFlags.contains(.control) { modifiers |= KeyCombo.control }
        if event.modifierFlags.contains(.option) { modifiers |= KeyCombo.option }
        if event.modifierFlags.contains(.shift) { modifiers |= KeyCombo.shift }
        if event.modifierFlags.contains(.command) { modifiers |= KeyCombo.command }
        guard modifiers != 0 else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers)
    }

    /// "⌥⌘C", in the order macOS renders modifiers.
    var displayString: String {
        var glyphs = ""
        if self.modifiers & KeyCombo.control != 0 { glyphs += "⌃" }
        if self.modifiers & KeyCombo.option != 0 { glyphs += "⌥" }
        if self.modifiers & KeyCombo.shift != 0 { glyphs += "⇧" }
        if self.modifiers & KeyCombo.command != 0 { glyphs += "⌘" }
        return glyphs + Self.keyLabel(for: self.keyCode)
    }

    /// `NSMenuItem.keyEquivalent` form of this combo.
    ///
    /// An open `NSMenu` matches key equivalents against its own items from inside its
    /// tracking loop — the only keyboard path that survives it, since that loop
    /// bypasses `NSApplication.sendEvent:` (and with it every local monitor) and
    /// menu-item views don't receive key events at all.
    var keyEquivalent: String {
        if let special = Self.keyEquivalentSpecials[self.keyCode] { return special }
        return Self.keyLabel(for: self.keyCode).lowercased()
    }

    var keyEquivalentModifierMask: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if self.modifiers & KeyCombo.control != 0 { flags.insert(.control) }
        if self.modifiers & KeyCombo.option != 0 { flags.insert(.option) }
        if self.modifiers & KeyCombo.shift != 0 { flags.insert(.shift) }
        if self.modifiers & KeyCombo.command != 0 { flags.insert(.command) }
        return flags
    }

    private static let keyEquivalentSpecials: [UInt32: String] = [
        UInt32(kVK_Space): " ",
        UInt32(kVK_Return): "\r",
        UInt32(kVK_Tab): "\t",
        UInt32(kVK_Escape): "\u{1B}",
        UInt32(kVK_Delete): "\u{8}",
        UInt32(kVK_ForwardDelete): "\u{7F}",
        UInt32(kVK_LeftArrow): String(UnicodeScalar(UInt32(NSLeftArrowFunctionKey))!),
        UInt32(kVK_RightArrow): String(UnicodeScalar(UInt32(NSRightArrowFunctionKey))!),
        UInt32(kVK_UpArrow): String(UnicodeScalar(UInt32(NSUpArrowFunctionKey))!),
        UInt32(kVK_DownArrow): String(UnicodeScalar(UInt32(NSDownArrowFunctionKey))!),
    ]

    private static let namedKeys: [UInt32: String] = [
        UInt32(kVK_Space): "Space",
        UInt32(kVK_Return): "↩",
        UInt32(kVK_Tab): "⇥",
        UInt32(kVK_Escape): "⎋",
        UInt32(kVK_Delete): "⌫",
        UInt32(kVK_ForwardDelete): "⌦",
        UInt32(kVK_LeftArrow): "←",
        UInt32(kVK_RightArrow): "→",
        UInt32(kVK_UpArrow): "↑",
        UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_Home): "↖",
        UInt32(kVK_End): "↘",
        UInt32(kVK_PageUp): "⇞",
        UInt32(kVK_PageDown): "⇟",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3",
        UInt32(kVK_F4): "F4", UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6",
        UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8", UInt32(kVK_F9): "F9",
        UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
    ]

    /// Asks the current keyboard layout what legend this key carries, so a Dvorak or
    /// AZERTY user sees the key they actually pressed rather than its QWERTY position.
    private static func keyLabel(for keyCode: UInt32) -> String {
        if let named = self.namedKeys[keyCode] { return named }

        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "?" }

        let layoutData = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var characters = [UniChar](repeating: 0, count: 4)
        var length = 0

        let status = layoutData.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return OSStatus(-1)
            }
            return UCKeyTranslate(
                layout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,  // unmodified: we want the key's own legend, not ⌥'s alternate glyph
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters)
        }
        guard status == noErr, length > 0 else { return "?" }
        return String(utf16CodeUnits: characters, count: length).uppercased()
    }
}

/// A click-to-record shortcut field.
///
/// Recording swallows every keystroke through a local monitor rather than a custom
/// first-responder view — the settings window has nothing else to type into, and it
/// keeps this to a native button instead of a hand-drawn control.
struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo?
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button(action: self.toggleRecording) {
                Text(self.label)
                    .frame(minWidth: 96)
                    .monospacedDigit()
            }
            if self.combo != nil, !self.isRecording {
                Button("Clear") { self.clear() }
                    .buttonStyle(.hoverBackground)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear { self.stopRecording() }
    }

    private var label: String {
        if self.isRecording { return "Press keys…" }
        return self.combo?.displayString ?? "Click to record"
    }

    private func toggleRecording() {
        if self.isRecording {
            self.stopRecording()
        } else {
            self.startRecording()
        }
    }

    private func startRecording() {
        guard self.monitor == nil else { return }
        self.isRecording = true
        self.monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            MainActor.assumeIsolated {
                if event.keyCode == UInt16(kVK_Escape) {
                    // Escape abandons recording and keeps whatever was bound before.
                    self.stopRecording()
                } else if let recorded = KeyCombo(event: event) {
                    self.combo = recorded
                    self.stopRecording()
                }
                // Anything else is a modifier-less press: ignored, keep listening.
            }
            return nil  // while recording, every keystroke is swallowed
        }
    }

    private func stopRecording() {
        if let monitor = self.monitor { NSEvent.removeMonitor(monitor) }
        self.monitor = nil
        self.isRecording = false
    }

    private func clear() {
        self.stopRecording()
        self.combo = nil
    }
}
