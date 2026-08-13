import AppKit
import Combine

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var menuController: StatusMenuController!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[YurecClient] applicationDidFinishLaunching: start")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        print("[YurecClient] statusItem created")

        print("[YurecClient] building StatusMenuController...")
        menuController = StatusMenuController(statusItem: statusItem)
        print("[YurecClient] StatusMenuController ready")

        print("[YurecClient] detecting existing process...")
        ProxyManager.shared.detectExistingProcess()
        print("[YurecClient] detectExistingProcess dispatched")

        if !ProxyManager.shared.isRunning,
           UserDefaults.standard.bool(forKey: "autoConnectOnLaunch"),
           let profile = ProfileManager.shared.activeProfile {
            _ = ProxyManager.shared.start(profilePath: profile.path.path)
        }

        print("[YurecClient] applicationDidFinishLaunching: done")
    }

    func applicationWillTerminate(_ notification: Notification) {
        ProxyManager.shared.forceCleanup()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        return false
    }
}
