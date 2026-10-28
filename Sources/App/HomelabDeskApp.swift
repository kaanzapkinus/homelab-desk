import AppKit
import Foundation

@main struct HomelabDeskApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = DeskApplicationDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
@MainActor final class DeskApplicationDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var windows: DesktopWindows?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel()
        let windows = DesktopWindows(model: model)
        self.model = model; self.windows = windows
        model.start()
        windows.show()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windows?.focus(); return true
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        let panels: Set<String> = ["overview", "memory", "disk", "connection", "services"]
        for url in urls where url.scheme == "homelabdesk" && url.host == "panel" {
            let path = String(url.path.dropFirst())
            guard url.query == nil, url.fragment == nil, panels.contains(path) else { continue }
            model?.navigate(to: path)
            windows?.focus()
        }
    }
    func applicationWillTerminate(_ notification: Notification) { model?.shutdown() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
