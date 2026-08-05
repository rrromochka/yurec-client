import AppKit
import Combine

private final class RouteSelectionMenuValue: NSObject {
    let profileURL: URL
    let selectorTag: String
    let option: String

    init(profileURL: URL, selectorTag: String, option: String) {
        self.profileURL = profileURL
        self.selectorTag = selectorTag
        self.option = option
    }
}

class StatusMenuController: NSObject {
    private let statusItem: NSStatusItem
    private var cancellables = Set<AnyCancellable>()

    private let proxyManager = ProxyManager.shared
    private let profileManager = ProfileManager.shared

    // MARK: - Connecting animation state
    // We track a "pending" target mode so the connecting icon shows immediately
    // after the user taps a menu item, before ProxyManager finishes start().
    private var pendingMode: ConnectionMode?
    private var pulseTimer: Timer?

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        super.init()
        setupBindings()
        applyIconState(derivedState())
        buildMenu()
    }

    // MARK: - Bindings

    private func setupBindings() {
        proxyManager.$isRunning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRunning in
                guard let self else { return }
                // When isRunning turns true, process is launched — clear pending.
                if isRunning { self.pendingMode = nil }
                self.applyIconState(self.derivedState())
                self.buildMenu()
            }
            .store(in: &cancellables)

        proxyManager.$currentMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.applyIconState(self.derivedState())
            }
            .store(in: &cancellables)

        profileManager.$profiles
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.buildMenu() }
            .store(in: &cancellables)

        profileManager.$activeProfile
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.buildMenu() }
            .store(in: &cancellables)

        proxyManager.$singBoxVersion
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.buildMenu() }
            .store(in: &cancellables)
    }

    // MARK: - Icon state machine

    /// Derives the current visual state from ProxyManager + local pending state.
    private func derivedState() -> StatusBarIconState {
        StatusBarIconState(
            isRunning:    proxyManager.isRunning,
            isConnecting: pendingMode != nil,
            mode:         pendingMode ?? proxyManager.currentMode
        )
    }

    /// Crossfades to the new icon and manages the connecting pulse.
    private func applyIconState(_ state: StatusBarIconState) {
        crossfade(to: StatusBarIconProvider.image(for: state))
        state.isConnecting ? startPulse() : stopPulse()
    }

    // MARK: - Crossfade transition

    /// Replaces the button image with a 0.15 s CATransition fade.
    ///
    /// CATransition on the button's backing layer is the lightest way to get a
    /// true crossfade in NSStatusBar — no extra views, no alpha hacks.
    /// `wantsLayer` is set lazily and is idempotent after the first call.
    private func crossfade(to image: NSImage) {
        guard let button = statusItem.button else { return }
        button.wantsLayer = true

        if let layer = button.layer {
            let t = CATransition()
            t.type = .fade
            t.duration = 0.15
            t.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(t, forKey: kCATransition)
        }

        button.image = image
        button.alphaValue = 1.0
    }

    // MARK: - Pulse animation (connecting states)

    /// Alpha pulse 1.0 ↔ 0.5, animated over 0.55 s with easeInEaseOut.
    /// NSAnimationContext gives a smooth organic fade rather than a hard jump.
    /// RunLoop.common keeps the timer firing while the menu is open.
    private func startPulse() {
        guard pulseTimer == nil else { return }
        var bright = true
        let timer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in
            guard let button = self?.statusItem.button else { return }
            bright.toggle()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.55
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                button.animator().alphaValue = bright ? 1.0 : 0.5
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pulseTimer = timer
    }

    private func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        // Restore alpha with a short ease-out so the pulse doesn't cut off abruptly.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            statusItem.button?.animator().alphaValue = 1.0
        }
    }

    // MARK: - Menu Construction

    func buildMenu() {
        let menu = NSMenu()

        // Profile label
        let profileName = profileManager.activeProfile?.name ?? "None"
        let profileLabel = NSMenuItem(title: "Profile: \(profileName)", action: nil, keyEquivalent: "")
        profileLabel.isEnabled = false
        menu.addItem(profileLabel)

        // Profiles submenu
        let profilesItem = NSMenuItem(title: "Profiles", action: nil, keyEquivalent: "")
        let profilesSubmenu = NSMenu(title: "Profiles")
        for profile in profileManager.profiles {
            let item = NSMenuItem(
                title: profile.name,
                action: #selector(selectProfile(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = profile
            if profile.id == profileManager.activeProfile?.id {
                item.state = .on
            }
            profilesSubmenu.addItem(item)
        }
        if profileManager.profiles.isEmpty {
            let empty = NSMenuItem(title: "No profiles", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            profilesSubmenu.addItem(empty)
        }
        profilesItem.submenu = profilesSubmenu
        menu.addItem(profilesItem)

        // Route selector(s), discovered from standard sing-box selector outbounds.
        if let profile = profileManager.activeProfile {
            let selectors = RouteSelectorStore.shared.selectors(for: profile.path)
            if !selectors.isEmpty {
                let routesItem = NSMenuItem(title: "Route", action: nil, keyEquivalent: "")
                let routesSubmenu = NSMenu(title: "Route")

                if selectors.count == 1, let selector = selectors.first {
                    addRouteOptions(selector, profile: profile, to: routesSubmenu)
                } else {
                    for selector in selectors {
                        let selectorItem = NSMenuItem(title: selector.tag, action: nil, keyEquivalent: "")
                        let selectorSubmenu = NSMenu(title: selector.tag)
                        addRouteOptions(selector, profile: profile, to: selectorSubmenu)
                        selectorItem.submenu = selectorSubmenu
                        routesSubmenu.addItem(selectorItem)
                    }
                }

                routesItem.submenu = routesSubmenu
                menu.addItem(routesItem)
            }
        }

        menu.addItem(.separator())

        // Connection status label
        let statusTitle: String
        if proxyManager.isRunning, let mode = proxyManager.currentMode {
            statusTitle = "Connected · \(mode.displayName)"
        } else {
            statusTitle = "Disconnected"
        }
        let statusLabel = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusLabel.isEnabled = false
        menu.addItem(statusLabel)

        let hasProfile = profileManager.activeProfile != nil
        let port = profileManager.activeProfile.map { profileManager.socks5Port(for: $0) }
            ?? ProfileManager.defaultSocks5Port
        let activeMode = proxyManager.currentMode

        // SOCKS5 connect (always visible; checkmark when active)
        let socks5Item = NSMenuItem(
            title: "SOCKS5  (port \(port))",
            action: #selector(connectSocks5),
            keyEquivalent: ""
        )
        socks5Item.target = self
        socks5Item.isEnabled = hasProfile
        if case .socks5 = activeMode { socks5Item.state = .on }
        menu.addItem(socks5Item)

        // TUN connect (always visible; checkmark when active)
        let tunItem = NSMenuItem(
            title: "TUN  (full VPN)",
            action: #selector(connectTun),
            keyEquivalent: ""
        )
        tunItem.target = self
        tunItem.isEnabled = hasProfile
        if activeMode == .tun { tunItem.state = .on }
        menu.addItem(tunItem)

        // Disconnect (only when running)
        if proxyManager.isRunning {
            let disconnectItem = NSMenuItem(title: "Disconnect", action: #selector(disconnect), keyEquivalent: "")
            disconnectItem.target = self
            menu.addItem(disconnectItem)
        }

        menu.addItem(.separator())

        // Logs
        let logsItem = NSMenuItem(title: "Open Logs", action: #selector(openLogs), keyEquivalent: "")
        logsItem.target = self
        menu.addItem(logsItem)

        // Settings
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        // Version info
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        let sbVersion = proxyManager.singBoxVersion
        let sbPart = sbVersion.isEmpty ? "sing-box: not found" : "sing-box \(sbVersion)"
        let versionTitle = "YurecClient \(appVersion)  ·  \(sbPart)"
        let versionItem = NSMenuItem(title: versionTitle, action: nil, keyEquivalent: "")
        versionItem.isEnabled = false
        menu.addItem(versionItem)

        // Quit
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func addRouteOptions(
        _ selector: RouteSelectorDescriptor,
        profile: Profile,
        to menu: NSMenu
    ) {
        let selected = RouteSelectorStore.shared.selectedOption(for: selector, profileURL: profile.path)
        for option in selector.options {
            let item = NSMenuItem(
                title: option,
                action: #selector(selectRoute(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = RouteSelectionMenuValue(
                profileURL: profile.path,
                selectorTag: selector.tag,
                option: option
            )
            item.state = option == selected ? .on : .off
            menu.addItem(item)
        }
    }

    // MARK: - Actions

    @objc private func selectProfile(_ sender: NSMenuItem) {
        guard let profile = sender.representedObject as? Profile else { return }
        let wasRunning = proxyManager.isRunning
        let previousMode = proxyManager.currentMode
        if wasRunning { proxyManager.stop() }
        profileManager.setActiveProfile(profile)
        if wasRunning, let mode = previousMode {
            let port = profileManager.socks5Port(for: profile)
            let mode2: ConnectionMode = (mode == .tun) ? .tun : .socks5(port: port)
            beginConnect(to: mode2, profile: profile)
        }
    }

    @objc private func selectRoute(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? RouteSelectionMenuValue,
              let profile = profileManager.activeProfile,
              profile.path.standardizedFileURL == value.profileURL.standardizedFileURL else {
            return
        }

        let selectors = RouteSelectorStore.shared.selectors(for: profile.path)
        guard let selector = selectors.first(where: { $0.tag == value.selectorTag }),
              selector.options.contains(value.option),
              RouteSelectorStore.shared.selectedOption(for: selector, profileURL: profile.path) != value.option else {
            return
        }

        RouteSelectorStore.shared.setSelectedOption(
            value.option,
            selectorTag: value.selectorTag,
            profileURL: profile.path
        )

        let previousMode = proxyManager.currentMode
        if proxyManager.isRunning {
            proxyManager.stop()
        }
        buildMenu()
        if let mode = previousMode {
            beginConnect(to: mode, profile: profile)
        }
    }

    @objc private func connectSocks5() {
        guard let profile = profileManager.activeProfile else { showNoProfileAlert(); return }
        if case .socks5 = proxyManager.currentMode { return }
        if proxyManager.isRunning { proxyManager.stop() }
        let port = profileManager.socks5Port(for: profile)
        beginConnect(to: .socks5(port: port), profile: profile)
    }

    @objc private func connectTun() {
        guard let profile = profileManager.activeProfile else { showNoProfileAlert(); return }
        if proxyManager.currentMode == .tun { return }
        if proxyManager.isRunning { proxyManager.stop() }
        beginConnect(to: .tun, profile: profile)
    }

    @objc private func disconnect() {
        pendingMode = nil
        stopPulse()
        proxyManager.stop()
    }

    /// Shows the connecting icon immediately, then calls proxyManager.start().
    /// If start() fails synchronously (returns with isRunning still false),
    /// pendingMode is cleared and the off icon is restored.
    private func beginConnect(to mode: ConnectionMode, profile: Profile) {
        pendingMode = mode
        applyIconState(derivedState())
        proxyManager.start(profilePath: profile.path.path, mode: mode)
        if !proxyManager.isRunning {
            pendingMode = nil
            applyIconState(derivedState())
        }
    }

    @objc private func openLogs() {
        let logFile = ProxyManager.singBoxLogURL
        if FileManager.default.fileExists(atPath: logFile.path) {
            NSWorkspace.shared.activateFileViewerSelecting([logFile])
        } else {
            NSWorkspace.shared.open(logFile.deletingLastPathComponent())
        }
    }

    @objc private func openSettings() {
        SettingsWindowController.shared.showWindow()
    }

    @objc private func quitApp() {
        proxyManager.stop()
        NSApplication.shared.terminate(nil)
    }

    private func showNoProfileAlert() {
        let alert = NSAlert()
        alert.messageText = "No Profile Selected"
        alert.informativeText = "Please create or select a profile in Settings before enabling."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
