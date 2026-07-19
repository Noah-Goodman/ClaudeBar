import AppKit
#if canImport(Sparkle)
import Sparkle
#endif

// Sparkle is an Xcode-project dependency only; `swift build` (the dev loop)
// compiles without it and simply gets no updater UI.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?
    #if canImport(Sparkle)
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    #endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if canImport(Sparkle)
        let updaterController = self.updaterController
        let onCheckForUpdates: (() -> Void)? = { updaterController.checkForUpdates(nil) }
        #else
        let onCheckForUpdates: (() -> Void)? = nil
        #endif
        self.statusItemController = StatusItemController(onCheckForUpdates: onCheckForUpdates)
    }
}

@main
enum ClaudeBarMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
