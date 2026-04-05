import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        self.statusItemController = StatusItemController()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { await CLISession.shared.reset() }
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
