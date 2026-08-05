import Foundation
import SystemConfiguration
import Darwin

/// Sets and resets DNS servers for all enabled network services.
/// Uses `sudo -n /usr/sbin/networksetup` (allowed without a password via
/// an already installed legacy upstream rule probed by SudoersManager).
enum DNSHelper {

    /// Returns true if at least one physical (non-TUN, non-loopback) interface
    /// has a globally-routable IPv6 address (i.e. not link-local fe80::/10).
    static func hasGlobalIPv6() -> Bool {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let head = ifaddr else { return false }
        defer { freeifaddrs(head) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = head
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            guard let addr = cur.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET6) else { continue }
            let name = String(cString: cur.pointee.ifa_name)
            guard !name.hasPrefix("utun"), !name.hasPrefix("lo") else { continue }
            let sin6 = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
            let b = sin6.sin6_addr.__u6_addr.__u6_addr8
            let isLinkLocal = (b.0 == 0xfe) && ((b.1 & 0xc0) == 0x80)
            if !isLinkLocal { return true }
        }
        return false
    }

    static func setDNS(_ server: String) {
        forEachEnabledService { name in
            runSudo("/usr/sbin/networksetup -setdnsservers \(shellQuote(name)) \(shellQuote(server))")
        }
    }

    static func resetDNS() {
        forEachEnabledService { name in
            runSudo("/usr/sbin/networksetup -setdnsservers \(shellQuote(name)) empty")
        }
    }

    // MARK: - Private

    /// Iterates over every enabled network service, passing its display name to block.
    private static func forEachEnabledService(_ block: (String) -> Void) {
        guard let prefs = SCPreferencesCreate(nil, ProductIdentity.displayName as CFString, nil),
              let services = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] else {
            print("[DNSHelper] failed to enumerate network services")
            return
        }
        for service in services {
            guard SCNetworkServiceGetEnabled(service),
                  let name = SCNetworkServiceGetName(service) as String? else { continue }
            block(name)
        }
    }

    private static func runSudo(_ cmd: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sudo -n \(cmd)"]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        try? task.run()
        task.waitUntilExit()
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
