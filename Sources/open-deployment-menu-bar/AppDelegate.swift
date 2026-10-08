import AppKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?

    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before the preferences store first reads a token, so the moved tokens are picked up.
        TokenMigration.move(from: KeychainTokenStore(location: .loginKeychain), to: KeychainTokenStore())
        statusController = StatusItemController()
        statusController?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        statusController?.stop()
    }
}
