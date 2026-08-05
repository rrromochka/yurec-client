import Foundation
import Combine
import AppKit
import IOKit

struct Profile: Identifiable, Equatable {
    let id: UUID
    let name: String
    let path: URL

    init(path: URL) {
        self.id = UUID()
        self.name = path.deletingPathExtension().lastPathComponent
        self.path = path
    }
}

class ProfileManager: ObservableObject {
    static let shared = ProfileManager()

    @Published var profiles: [Profile] = []
    @Published var activeProfile: Profile?

    private let profilesDir: URL
    private var fsEventStream: FSEventStreamRef?

    private init() {
        profilesDir = ProductIdentity.profilesDirectory()
        createProfilesDirIfNeeded()
        loadProfiles()
        restoreActiveProfile()
        startWatching()
    }

    // MARK: - Directory Setup

    private func createProfilesDirIfNeeded() {
        try? ProfileImporter.preparePrivateDirectory(at: profilesDir)
    }

    // MARK: - Profile Loading

    func loadProfiles() {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: profilesDir,
            includingPropertiesForKeys: nil
        ) else { return }

        let jsonFiles = contents
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        let newProfiles = jsonFiles.map { Profile(path: $0) }

        // Всегда вызывается из main queue (init + FSEvents через DispatchQueue.main)
        // Обновляем синхронно, чтобы restoreActiveProfile() видел актуальный список
        profiles = newProfiles
        if let active = activeProfile,
           !newProfiles.contains(where: { $0.path == active.path }) {
            activeProfile = newProfiles.first
            persistActiveProfile()
        }
    }

    private func restoreActiveProfile() {
        let stored = UserDefaults.standard.string(forKey: "activeProfilePath")
        if let stored = stored, let url = URL(string: stored) {
            activeProfile = profiles.first(where: { $0.path == url }) ?? profiles.first
        } else {
            activeProfile = profiles.first
        }
        persistActiveProfile()
    }

    func setActiveProfile(_ profile: Profile) {
        activeProfile = profile
        persistActiveProfile()
    }

    /// Ищет профиль по пути к файлу и делает его активным.
    func activateProfileByPath(_ path: String) {
        guard let match = profiles.first(where: { $0.path.path == path }) else { return }
        setActiveProfile(match)
    }

    private func persistActiveProfile() {
        UserDefaults.standard.set(activeProfile?.path.absoluteString, forKey: "activeProfilePath")
    }

    // MARK: - Profile CRUD

    func addProfile(from sourceURL: URL) throws {
        do {
            try ProfileImporter.validateProfile(at: sourceURL)
        } catch {
            throw ProfileError.invalidProfile
        }
        let destination = profilesDir.appendingPathComponent(sourceURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            throw ProfileError.alreadyExists
        }
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destination)
            try ProfileImporter.secureProfile(at: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Copies upstream YurecClient profile snapshots into downstream storage.
    /// Source files and upstream settings are never modified or removed.
    func importUpstreamProfiles() throws -> ProfileImportSummary {
        let summary = try ProfileImporter.importProfiles(
            from: ProductIdentity.upstreamProfilesDirectory(),
            to: profilesDir
        )
        loadProfiles()
        return summary
    }

    func removeProfile(_ profile: Profile) throws {
        setSubscriptionURL(nil, for: profile)
        try FileManager.default.removeItem(at: profile.path)
    }

    func createNewProfile(name: String) throws {
        let fileName = name.hasSuffix(".json") ? name : "\(name).json"
        let destination = profilesDir.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: destination.path) {
            throw ProfileError.alreadyExists
        }
        let template = emptyProfileTemplate()
        do {
            try template.write(to: destination, atomically: true, encoding: .utf8)
            try ProfileImporter.secureProfile(at: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    func openInEditor(_ profile: Profile) {
        NSWorkspace.shared.open(profile.path)
    }

    // MARK: - Subscription Support

    func subscriptionURL(for profile: Profile) -> URL? {
        guard let stored = UserDefaults.standard.string(forKey: subscriptionKey(for: profile)) else { return nil }
        return URL(string: stored)
    }

    private func setSubscriptionURL(_ url: URL?, for profile: Profile) {
        if let url = url {
            UserDefaults.standard.set(url.absoluteString, forKey: subscriptionKey(for: profile))
        } else {
            UserDefaults.standard.removeObject(forKey: subscriptionKey(for: profile))
        }
    }

    private func subscriptionKey(for profile: Profile) -> String {
        "subscriptionURL_\(profile.path.absoluteString)"
    }

    func addProfileFromSubscription(name: String, subscriptionURL: URL) async throws {
        let fileName = name.hasSuffix(".json") ? name : "\(name).json"
        let destination = profilesDir.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: destination.path) {
            throw ProfileError.alreadyExists
        }
        let raw = try await fetchData(from: subscriptionURL)
        let configData = try SubscriptionParser.buildSingboxConfig(from: raw)
        do {
            try configData.write(to: destination, options: .atomic)
            try ProfileImporter.secureProfile(at: destination)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        let profile = Profile(path: destination)
        setSubscriptionURL(subscriptionURL, for: profile)
    }

    func refreshProfile(_ profile: Profile) async throws {
        guard let url = subscriptionURL(for: profile) else {
            throw ProfileError.noSubscriptionURL
        }
        let raw = try await fetchData(from: url)
        let configData = try SubscriptionParser.buildSingboxConfig(from: raw)
        try configData.write(to: profile.path, options: .atomic)
        try ProfileImporter.secureProfile(at: profile.path)
    }

    private func fetchData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        if let hwid = Self.hardwareUUID() {
            request.setValue(hwid, forHTTPHeaderField: "x-hwid")
        }
        request.setValue("macOS",                                            forHTTPHeaderField: "x-device-os")
        request.setValue(Self.osVersion(),                                   forHTTPHeaderField: "x-ver-os")
        request.setValue(Self.deviceModel(),                                 forHTTPHeaderField: "x-device-model")
        request.setValue("CambodgiaYurecClient/1.0 (macOS; \(Self.osVersion()))", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw ProfileError.downloadFailed
        }
        return data
    }

    static func hardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { IOObjectRelease(service) }
        guard service != 0 else { return nil }
        let ref = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)
        return ref?.takeRetainedValue() as? String
    }

    private static func osVersion() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    private static func deviceModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "Mac" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    // MARK: - Per-Profile Settings

    static let defaultSocks5Port = 2080

    func socks5Port(for profile: Profile) -> Int {
        let key = "socks5Port_\(profile.path.absoluteString)"
        let stored = UserDefaults.standard.integer(forKey: key)
        return stored > 0 ? stored : ProfileManager.defaultSocks5Port
    }

    func setSocks5Port(_ port: Int, for profile: Profile) {
        UserDefaults.standard.set(port, forKey: "socks5Port_\(profile.path.absoluteString)")
    }

    private func emptyProfileTemplate() -> String {
        """
        {
          "log": {
            "level": "info",
            "timestamp": true
          },
          "dns": {
            "servers": [
              {
                "tag": "remote",
                "address": "tls://1.1.1.1"
              }
            ]
          },
          "inbounds": [],
          "outbounds": [
            {
              "type": "direct",
              "tag": "direct"
            },
            {
              "type": "block",
              "tag": "block"
            }
          ],
          "route": {
            "final": "direct"
          }
        }
        """
    }

    // MARK: - FSEvents

    private func startWatching() {
        let paths = [profilesDir.path] as CFArray
        var ctx = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info = info else { return }
            let manager = Unmanaged<ProfileManager>.fromOpaque(info).takeUnretainedValue()
            manager.loadProfiles()
        }

        fsEventStream = FSEventStreamCreate(
            nil,
            callback,
            &ctx,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        )

        if let stream = fsEventStream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream = fsEventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}

enum ProfileError: LocalizedError {
    case alreadyExists
    case downloadFailed
    case noSubscriptionURL
    case invalidProfile

    var errorDescription: String? {
        switch self {
        case .alreadyExists: return "A profile with that name already exists."
        case .downloadFailed: return "Failed to download profile from the subscription URL."
        case .noSubscriptionURL: return "This profile has no subscription URL."
        case .invalidProfile: return "The selected profile is not a valid sing-box JSON object."
        }
    }
}
