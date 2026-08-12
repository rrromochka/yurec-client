import SwiftUI
import AppKit

struct ProfilesTabView: View {
    @ObservedObject private var profileManager = ProfileManager.shared
    @ObservedObject private var routingStore = AppRoutingStore.shared
    @State private var selectedProfileID: UUID?
    @State private var showNewProfileSheet = false
    @State private var showAddSubscriptionSheet = false
    @State private var refreshingProfileID: UUID?
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var socks5PortText: String = ""
    // Per-profile app routing state
    @State private var profileOverride: Bool = false
    @State private var profileEntries: [AppRoutingEntry] = []

    var selectedProfile: Profile? {
        profileManager.profiles.first(where: { $0.id == selectedProfileID })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Profile list
            List(profileManager.profiles, selection: $selectedProfileID) { profile in
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile.name).font(.body)
                    Text(profile.path.path).font(.caption).foregroundColor(.secondary)
                }
                .tag(profile.id)
            }
            .frame(minHeight: 120)
            .border(Color(NSColor.separatorColor))
            .onChange(of: selectedProfileID) { _ in loadSettingsForSelected() }

            // Per-profile settings
            if let profile = selectedProfile {
                Divider()
                profileSettings(for: profile)
            }

            // Bottom toolbar
            HStack(spacing: 8) {
                Button("Add...") { pickFile() }
                Button("Add from URL...") { showAddSubscriptionSheet = true }
                Button("Remove") { removeSelected() }.disabled(selectedProfileID == nil)
                Button("Open in Editor") { openSelected() }.disabled(selectedProfileID == nil)
                Spacer()
                Button("New Profile...") { showNewProfileSheet = true }
            }
        }
        .sheet(isPresented: $showNewProfileSheet) {
            NewProfileSheet(isPresented: $showNewProfileSheet) { name in
                createProfile(name: name)
            }
        }
        .sheet(isPresented: $showAddSubscriptionSheet) {
            AddSubscriptionSheet(isPresented: $showAddSubscriptionSheet) { name, url in
                addFromSubscription(name: name, url: url)
            }
        }
        .alert("Error", isPresented: $showError, presenting: errorMessage) { _ in
            Button("OK") {}
        } message: { msg in Text(msg) }
    }

    // MARK: - Per-profile settings panel

    @ViewBuilder
    private func profileSettings(for profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Port
            VStack(alignment: .leading, spacing: 4) {
                Text("Settings for \"\(profile.name)\"")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack(spacing: 8) {
                    Text("SOCKS5 Port:")
                    TextField("2080", text: $socks5PortText)
                        .frame(width: 70)
                        .onSubmit { savePort() }
                    Text("(used in SOCKS5 mode)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            // Subscription section
            if let subURL = profileManager.subscriptionURL(for: profile) {
                Divider()
                subscriptionSection(for: profile, url: subURL)
            }

            Divider()

            // App routing override section
            appRoutingSection(for: profile)
        }
    }

    @ViewBuilder
    private func subscriptionSection(for profile: Profile, url: URL) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Subscription")
                .font(.caption)
                .foregroundColor(.secondary)
            HStack(spacing: 8) {
                Text(url.absoluteString)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundColor(.secondary)
                Spacer()
                if refreshingProfileID == profile.id {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 50, height: 20)
                } else {
                    Button("Update") { refreshSubscription(profile) }
                        .controlSize(.small)
                        .disabled(refreshingProfileID != nil)
                }
            }
        }
    }

    @ViewBuilder
    private func appRoutingSection(for profile: Profile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header + override toggle
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("App Routing · SOCKS5")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if !profileOverride {
                        Text("Using global defaults")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                Toggle("Override global", isOn: $profileOverride)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: profileOverride) { value in
                        routingStore.setOverridesGlobal(value, for: profile)
                        if value && profileEntries.isEmpty {
                            // Seed profile list with current global entries as a starting point
                            profileEntries = routingStore.globalEntries
                            routingStore.setEntries(profileEntries, for: profile)
                        }
                    }
            }

            if profileOverride {
                // Editable profile-specific list
                AppRoutingListView(
                    entries: profileEntries,
                    onAdd: { addProfileApp(for: profile) },
                    onRemove: { id in
                        profileEntries.removeAll { $0.id == id }
                        routingStore.setEntries(profileEntries, for: profile)
                    }
                )
                .frame(minHeight: 80)
            } else {
                // Read-only view of inherited global list
                inheritedGlobalView
            }

            reconnectNoteIfNeeded
        }
        .padding(.bottom, 4)
    }

    // Read-only list showing the global entries the profile inherits
    @ViewBuilder
    private var inheritedGlobalView: some View {
        let globals = routingStore.globalEntries
        if globals.isEmpty {
            Text("No global defaults configured — go to General to add apps.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(spacing: 0) {
                ForEach(globals) { entry in
                    HStack(spacing: 8) {
                        Image(nsImage: entry.icon(size: 16))
                            .resizable().frame(width: 16, height: 16)
                        Text(entry.displayName).font(.callout)
                        Spacer()
                        Text("inherited")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color(NSColor.tertiaryLabelColor).opacity(0.15))
                            .clipShape(Capsule())
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    if entry.id != globals.last?.id { Divider() }
                }
            }
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
            )
        }
    }

    @ViewBuilder
    private var reconnectNoteIfNeeded: some View {
        let proxy = ProxyManager.shared
        if proxy.isRunning, case .socks5 = proxy.currentMode {
            Label("Changes take effect after reconnecting SOCKS5.", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Profile actions

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            do { try profileManager.addProfile(from: url) }
            catch { present(error) }
        }
    }

    private func removeSelected() {
        guard let profile = selectedProfile else { return }
        do {
            try profileManager.removeProfile(profile)
            selectedProfileID = nil
        } catch { present(error) }
    }

    private func openSelected() {
        guard let profile = selectedProfile else { return }
        profileManager.openInEditor(profile)
    }

    private func createProfile(name: String) {
        do { try profileManager.createNewProfile(name: name) }
        catch { present(error) }
    }

    private func addFromSubscription(name: String, url: URL) {
        Task {
            do {
                try await profileManager.addProfileFromSubscription(name: name, subscriptionURL: url)
            } catch {
                await MainActor.run { present(error) }
            }
        }
    }

    private func refreshSubscription(_ profile: Profile) {
        refreshingProfileID = profile.id
        let previousSelectors = RouteSelectorStore.shared.selectors(for: profile.path)
        let previousSelections = RouteSelectorStore.shared.persistedSelectionSnapshot(
            for: previousSelectors,
            profileURL: profile.path
        )
        Task {
            do {
                try await profileManager.refreshProfile(profile)
                let refreshedSelectors = RouteSelectorStore.shared.selectors(for: profile.path)
                let fallbacks = RouteSelectorStore.shared.reconcileSelectionsAfterRefresh(
                    previousSelections: previousSelections,
                    refreshedSelectors: refreshedSelectors,
                    profileURL: profile.path
                )
                await MainActor.run {
                    if restartActiveConnectionIfNeeded(for: profile) {
                        presentRefreshFallbacks(fallbacks)
                    }
                }
            } catch {
                await MainActor.run { present(error) }
            }
            await MainActor.run { refreshingProfileID = nil }
        }
    }

    private func restartActiveConnectionIfNeeded(for profile: Profile) -> Bool {
        let proxy = ProxyManager.shared
        guard proxy.isRunning,
              let mode = proxy.currentMode,
              profileManager.activeProfile?.path.standardizedFileURL
                == profile.path.standardizedFileURL else {
            return true
        }

        proxy.stop()
        proxy.start(profilePath: profile.path.path, mode: mode)
        guard proxy.isRunning else {
            errorMessage = "The subscription was updated, but the active connection could not be restarted."
            showError = true
            return false
        }
        return true
    }

    private func presentRefreshFallbacks(_ fallbacks: [RouteSelectionFallback]) {
        guard !fallbacks.isEmpty else { return }
        let message = fallbacks.map { fallback in
            if let replacement = fallback.fallbackOption {
                return "\"\(fallback.unavailableOption)\" is no longer available. "
                    + "The route changed to \"\(replacement)\"."
            }
            return "\"\(fallback.unavailableOption)\" is no longer available. "
                + "The refreshed profile no longer provides that route selector."
        }.joined(separator: "\n")

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Route Changed After Update"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
        showError = true
    }

    // MARK: - Settings load/save

    private func loadSettingsForSelected() {
        guard let profile = selectedProfile else {
            socks5PortText = ""
            profileOverride = false
            profileEntries = []
            return
        }
        socks5PortText = "\(profileManager.socks5Port(for: profile))"
        profileOverride = routingStore.overridesGlobal(for: profile)
        profileEntries = routingStore.entries(for: profile)
    }

    private func savePort() {
        guard let profile = selectedProfile,
              let port = Int(socks5PortText), port > 0, port < 65536 else { return }
        profileManager.setSocks5Port(port, for: profile)
    }

    // MARK: - App routing helpers

    private func addProfileApp(for profile: Profile) {
        let new = pickAppsForRouting(existing: profileEntries)
        profileEntries.append(contentsOf: new)
        routingStore.setEntries(profileEntries, for: profile)
    }
}

// MARK: - Add Subscription Sheet

struct AddSubscriptionSheet: View {
    @Binding var isPresented: Bool
    var onAdd: (String, URL) -> Void

    @State private var urlText = ""
    @State private var name = ""
    @State private var nameEdited = false

    private var parsedURL: URL? {
        let trimmed = urlText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Subscription").font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Subscription URL").font(.caption).foregroundColor(.secondary)
                TextField("https://...", text: $urlText)
                    .frame(width: 360)
                    .onChange(of: urlText) { _ in suggestName() }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Profile Name").font(.caption).foregroundColor(.secondary)
                TextField("Name", text: $name)
                    .frame(width: 360)
                    .onChange(of: name) { _ in nameEdited = true }
            }

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Add") { submit() }
                    .disabled(parsedURL == nil || name.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.return)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func suggestName() {
        guard !nameEdited, let url = parsedURL else { return }
        name = url.host ?? ""
        nameEdited = false
    }

    private func submit() {
        guard let url = parsedURL else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }
        isPresented = false
        onAdd(trimmedName, url)
    }
}

// MARK: - New Profile Sheet

struct NewProfileSheet: View {
    @Binding var isPresented: Bool
    var onCreate: (String) -> Void
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Profile").font(.headline)
            TextField("Profile name", text: $name).frame(width: 260)
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                Button("Create") {
                    isPresented = false
                    onCreate(name)
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.return)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}
