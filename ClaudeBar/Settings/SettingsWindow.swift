import AppKit
import SwiftUI

/// The app's only window. Single-instance: reopening brings the existing one forward
/// rather than stacking duplicates.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    /// - Parameter applyCombo: attempts the registration and returns a message to
    ///   show inline on failure, or nil on success. Registration lives with
    ///   `StatusItemController`, which owns the `HotKeyManager`.
    func show(applyCombo: @escaping (KeyCombo?) -> String?) {
        if let existing = self.window {
            self.bringForward(existing)
            return
        }

        let hostingView = NSHostingView(
            rootView: SettingsView(combo: HotKeyManager.saved, applyCombo: applyCombo))
        hostingView.frame.size = hostingView.fittingSize

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: hostingView.fittingSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "ClaudeBar Settings"
        window.contentView = hostingView
        // The controller decides the lifetime; without this the window is deallocated
        // on close and `windowWillClose` would be talking about freed memory.
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        self.window = window
        self.bringForward(window)
    }

    /// `.accessory` apps have no Dock icon and don't activate on their own, so the
    /// window would open behind whatever the user was looking at.
    private func bringForward(_ window: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { self.window = nil }
    }
}

struct SettingsView: View {
    @State var combo: KeyCombo?
    @State private var errorMessage: String?

    let applyCombo: (KeyCombo?) -> String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Keyboard Shortcut")
                .font(.system(size: 13, weight: .semibold))

            HStack(spacing: 10) {
                Text("Toggle panel:")
                    .font(.system(size: 12))
                ShortcutRecorder(combo: self.$combo)
            }

            if let errorMessage = self.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Press the shortcut from any app to show or hide the ClaudeBar panel.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 360, alignment: .leading)
        .onChange(of: self.combo) { _, newValue in
            self.errorMessage = self.applyCombo(newValue)
        }
    }
}
