import AppKit
import Combine

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var menuController: StatusMenuController!
    private var cancellables = Set<AnyCancellable>()
    private var sleepWakeRecovery = SleepWakeRecoveryState()
    private var recoveryGeneration: UInt = 0

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

        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        workspaceNotifications.addObserver(
            self,
            selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )
        workspaceNotifications.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        if !ProxyManager.shared.isRunning,
           UserDefaults.standard.bool(forKey: "autoConnectOnLaunch"),
           let profile = ProfileManager.shared.activeProfile {
            ProxyManager.shared.start(profilePath: profile.path.path)
        }

        print("[YurecClient] applicationDidFinishLaunching: done")
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        ProxyManager.shared.forceCleanup()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        return false
    }

    @objc private func systemWillSleep(_ notification: Notification) {
        recoveryGeneration &+= 1
        let proxy = ProxyManager.shared
        guard sleepWakeRecovery.capture(
            isRunning: proxy.isRunning,
            profilePath: ProfileManager.shared.activeProfile?.path.path,
            mode: proxy.currentMode
        ) else { return }

        print("[YurecClient] system will sleep: stopping the owned connection")
        proxy.stop()
    }

    @objc private func systemDidWake(_ notification: Notification) {
        guard let session = sleepWakeRecovery.takePendingSession() else { return }
        let generation = recoveryGeneration
        print("[YurecClient] system did wake: waiting for the physical network")

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let networkReady = DNSHelper.waitForUsablePhysicalNetwork()
            DispatchQueue.main.async {
                guard let self,
                      self.recoveryGeneration == generation,
                      !ProxyManager.shared.isRunning else { return }
                guard networkReady else {
                    print("[YurecClient] wake recovery skipped: physical network did not become ready")
                    return
                }

                ProxyManager.shared.start(
                    profilePath: session.profilePath,
                    mode: session.mode
                )
                print(
                    "[YurecClient] wake recovery finished: running="
                        + "\(ProxyManager.shared.isRunning)"
                )
            }
        }
    }
}
