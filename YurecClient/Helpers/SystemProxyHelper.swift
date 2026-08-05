import Foundation

/// Sets and clears the macOS system-wide SOCKS5 proxy for all active network services.
///
/// Called by ProxyManager when SOCKS5 mode starts and stops, so that apps which
/// respect the macOS proxy settings (browsers, Electron apps, URLSession-based apps)
/// automatically route their traffic through sing-box without manual configuration.
///
/// During local development, `/usr/sbin/networksetup` may be covered by an
/// already installed upstream rule. Cambodgia build only probes that access;
/// the public release must use the constrained privileged helper.
enum SystemProxyHelper {

    private static let networksetup = "/usr/sbin/networksetup"

    // MARK: - Public

    static func enableSOCKS5(port: Int) {
        let services = activeServices()
        print("\(ProductIdentity.logPrefix) SystemProxyHelper: enabling SOCKS5 proxy port \(port) on: \(services)")
        for svc in services {
            run(["-setsocksfirewallproxy", svc, "127.0.0.1", "\(port)"])
            run(["-setsocksfirewallproxystate", svc, "on"])
        }
    }

    static func disableSOCKS5() {
        let services = activeServices()
        print("\(ProductIdentity.logPrefix) SystemProxyHelper: disabling SOCKS5 proxy on: \(services)")
        for svc in services {
            run(["-setsocksfirewallproxystate", svc, "off"])
        }
    }

    // MARK: - Private

    /// Returns names of all non-disabled network services.
    /// Lines starting with `*` are disabled; the first line is a header.
    private static func activeServices() -> [String] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: networksetup)
        task.arguments = ["-listallnetworkservices"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return [] }
        task.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return output
            .split(separator: "\n")
            .dropFirst()                    // skip header line
            .compactMap { line -> String? in
                let s = String(line)
                return (s.isEmpty || s.hasPrefix("*")) ? nil : s
            }
    }

    private static func run(_ args: [String]) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        task.arguments = ["-n", networksetup] + args
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        try? task.run()
        task.waitUntilExit()
    }
}
