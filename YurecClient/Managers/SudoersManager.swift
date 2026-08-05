import Foundation

/// Read-only compatibility probe for the legacy upstream sudoers rule.
///
/// The Cambodgia downstream must not create, overwrite or remove
/// `/etc/sudoers.d/yurec`: it is shared with upstream and grants permissions
/// that are too broad for a public release. A constrained privileged helper
/// will replace this temporary development-only compatibility path.
enum SudoersManager {

    // MARK: - Public API

    /// True when sudo allows running binaryPath without a password.
    /// Uses `sudo -n -l` — works regardless of file permissions on the rule.
    static func isInstalled(for binaryPath: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        task.arguments = ["-n", "-l", binaryPath]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return false }
        task.waitUntilExit()
        let allowed = task.terminationStatus == 0
        print("\(ProductIdentity.logPrefix) LegacySudoers: isInstalled(\((binaryPath as NSString).lastPathComponent)) = \(allowed)")
        return allowed
    }
}
