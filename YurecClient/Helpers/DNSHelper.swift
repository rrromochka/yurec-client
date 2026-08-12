import Foundation
import SystemConfiguration
import Darwin

/// Sets and resets DNS servers for all enabled network services.
/// Uses `sudo -n /usr/sbin/networksetup` (allowed without a password via
/// an already installed legacy upstream rule probed by SudoersManager).
enum DNSHelper {

    /// Waits until macOS reports a stable non-TUN primary network interface.
    ///
    /// Sleep/wake notifications arrive before Wi-Fi or Ethernet has necessarily
    /// reacquired its address. Starting a new TUN session in that interval can
    /// leave sing-box alive but unable to reach its outbound. Requiring several
    /// consecutive ready samples avoids both an arbitrary sleep and an external
    /// connectivity probe.
    static func waitForUsablePhysicalNetwork(
        timeout: TimeInterval = 20,
        stableSamples: Int = 3,
        sampleInterval: TimeInterval = 0.5
    ) -> Bool {
        let requiredSamples = max(1, stableSamples)
        let interval = max(0.05, sampleInterval)
        let deadline = Date().addingTimeInterval(max(0, timeout))
        var readySamples = 0

        repeat {
            if hasUsablePrimaryInterface() {
                readySamples += 1
                if readySamples >= requiredSamples { return true }
            } else {
                readySamples = 0
            }
            Thread.sleep(forTimeInterval: interval)
        } while Date() < deadline

        return false
    }

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

    private static func hasUsablePrimaryInterface() -> Bool {
        guard let interfaceName = primaryInterfaceName(),
              !interfaceName.hasPrefix("utun"),
              !interfaceName.hasPrefix("lo") else {
            return false
        }

        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let head = ifaddr else { return false }
        defer { freeifaddrs(head) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = head
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }
            guard String(cString: current.pointee.ifa_name) == interfaceName,
                  let address = current.pointee.ifa_addr else { continue }

            let flags = Int32(current.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0 else { continue }

            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                let value = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
                }
                let firstOctet = UInt8((value >> 24) & 0xff)
                let secondOctet = UInt8((value >> 16) & 0xff)
                let isUnusable = value == 0
                    || firstOctet == 127
                    || (firstOctet == 169 && secondOctet == 254)
                if !isUnusable { return true }
            case AF_INET6:
                let value = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    $0.pointee.sin6_addr.__u6_addr.__u6_addr8
                }
                let isUnspecified = value.0 == 0 && value.1 == 0 && value.2 == 0 && value.3 == 0
                    && value.4 == 0 && value.5 == 0 && value.6 == 0 && value.7 == 0
                    && value.8 == 0 && value.9 == 0 && value.10 == 0 && value.11 == 0
                    && value.12 == 0 && value.13 == 0 && value.14 == 0 && value.15 == 0
                let isLinkLocal = value.0 == 0xfe && (value.1 & 0xc0) == 0x80
                if !isUnspecified && !isLinkLocal { return true }
            default:
                continue
            }
        }
        return false
    }

    private static func primaryInterfaceName() -> String? {
        guard let store = SCDynamicStoreCreate(
            nil,
            "YurecClient.NetworkReadiness" as CFString,
            nil,
            nil
        ) else { return nil }

        for key in ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] {
            guard let value = SCDynamicStoreCopyValue(store, key as CFString)
                as? [String: Any],
                  let name = value[kSCDynamicStorePropNetPrimaryInterface as String] as? String,
                  !name.isEmpty else { continue }
            return name
        }
        return nil
    }

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
