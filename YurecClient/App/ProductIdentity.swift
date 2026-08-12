import Foundation

/// Product-specific identity for the Cambodgia downstream build.
///
/// Keep these values in one place so the downstream can coexist with the
/// upstream YurecClient without sharing profiles, logs, defaults or runtime
/// files.
enum ProductIdentity {
    static let displayName = "Cambodgia YurecClient"
    static let bundleIdentifier = "ru.rom-gorodnichev.cambodgia.yurecclient"
    static let runtimeNamespace = "cambodgia-yurecclient"
    static let logPrefix = "[Cambodgia YurecClient]"
    static let binaryPathDefaultsKey = "singBoxBinaryPath"

    static func applicationSupportDirectory(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent(displayName, isDirectory: true)
    }

    static func profilesDirectory(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        applicationSupportDirectory(homeDirectory: homeDirectory)
            .appendingPathComponent("Profiles", isDirectory: true)
    }

    static func logsDirectory(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(displayName, isDirectory: true)
    }

    /// Read-only source used by the explicit migration action. The downstream
    /// never watches, edits or removes files in this upstream directory.
    static func upstreamProfilesDirectory(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent(".singbox", isDirectory: true)
            .appendingPathComponent("profiles", isDirectory: true)
    }

    static func temporaryConfigURL(kind: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(runtimeNamespace)-\(kind)-\(UUID().uuidString).json")
    }

    /// Returns the subscription host that must remain reachable independently
    /// from the selected exit. The value is derived from per-profile state and
    /// is never hard-coded into the application or persisted in generated files.
    static func subscriptionDirectRouteDomains(subscriptionURL: URL?) -> [String] {
        guard let host = subscriptionURL?.host?
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased(),
              !host.isEmpty else {
            return []
        }
        return [host]
    }
}

struct ProfileImportSummary: Equatable {
    let imported: Int
    let skippedExisting: Int
}

enum ProfileImporter {
    enum ImportError: LocalizedError {
        case sourceNotFound
        case invalidProfile(String)

        var errorDescription: String? {
            switch self {
            case .sourceNotFound:
                return "No YurecClient profiles were found to import."
            case .invalidProfile(let name):
                return "YurecClient profile \"\(name)\" is not a valid JSON object."
            }
        }
    }

    static func preparePrivateDirectory(
        at directory: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    static func secureProfile(
        at url: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func validateProfile(at url: URL) throws {
        guard url.pathExtension.lowercased() == "json",
              let data = try? Data(contentsOf: url),
              (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
            throw ImportError.invalidProfile(url.lastPathComponent)
        }
    }

    /// Copies profile snapshots from upstream storage. Existing destination
    /// files are skipped and the source tree is strictly read-only.
    static func importProfiles(
        from sourceDirectory: URL,
        to destinationDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> ProfileImportSummary {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ImportError.sourceNotFound
        }

        let sourceProfiles = try fileManager.contentsOfDirectory(
            at: sourceDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            guard url.pathExtension.lowercased() == "json",
                  let values = try? url.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                  ) else {
                return false
            }
            return values.isRegularFile == true && values.isSymbolicLink != true
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !sourceProfiles.isEmpty else { throw ImportError.sourceNotFound }
        try sourceProfiles.forEach(validateProfile)
        try preparePrivateDirectory(at: destinationDirectory, fileManager: fileManager)

        var imported = 0
        var skippedExisting = 0
        for source in sourceProfiles {
            let destination = destinationDirectory.appendingPathComponent(source.lastPathComponent)
            if fileManager.fileExists(atPath: destination.path) {
                skippedExisting += 1
                continue
            }

            do {
                try fileManager.copyItem(at: source, to: destination)
                try secureProfile(at: destination, fileManager: fileManager)
                imported += 1
            } catch {
                try? fileManager.removeItem(at: destination)
                throw error
            }
        }

        return ProfileImportSummary(imported: imported, skippedExisting: skippedExisting)
    }
}
