import AppKit
import Combine

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var menuController: StatusMenuController!
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("\(ProductIdentity.logPrefix) applicationDidFinishLaunching: start")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        print("\(ProductIdentity.logPrefix) statusItem created")

        print("\(ProductIdentity.logPrefix) building StatusMenuController...")
        menuController = StatusMenuController(statusItem: statusItem)
        print("\(ProductIdentity.logPrefix) StatusMenuController ready")

        print("\(ProductIdentity.logPrefix) detecting existing process...")
        ProxyManager.shared.detectExistingProcess()
        print("\(ProductIdentity.logPrefix) detectExistingProcess completed")

        if !ProxyManager.shared.isRunning,
           UserDefaults.standard.bool(forKey: "autoConnectOnLaunch"),
           let profile = ProfileManager.shared.activeProfile {
            _ = ProxyManager.shared.start(profilePath: profile.path.path)
        }

        print("\(ProductIdentity.logPrefix) applicationDidFinishLaunching: done")
    }

    func applicationWillTerminate(_ notification: Notification) {
        ProxyManager.shared.forceCleanup()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        return false
    }
}
