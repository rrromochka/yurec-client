import Foundation

enum ConnectionMode: Equatable {
    case tun
    case socks5(port: Int)

    var displayName: String {
        switch self {
        case .tun:              return "TUN (Full VPN)"
        case .socks5(let p):   return "SOCKS5 (port \(p))"
        }
    }

    var requiresRoot: Bool {
        // Both modes run as root via sudo so that SOCKS5 can bind() over
        // root-owned TIME_WAIT sockets left by the previous TUN session.
        // Without this, non-root bind() fails for up to 60 s after TUN stops.
        return true
    }
}

/// Identifies one concrete sing-box session. The generation keeps sessions
/// distinct even if macOS later reuses the same process identifier.
struct ProcessSessionToken: Equatable {
    let generation: UInt64
    let pid: Int32
}

/// Owns the identity of the sing-box session represented by ProxyManager.
///
/// Process termination callbacks are asynchronous. A callback for a stopped
/// session can therefore reach the main queue after a replacement session has
/// already started. Matching the complete token prevents that stale callback
/// from clearing the replacement session's state.
struct ProcessSessionLifecycle {
    private var nextGeneration: UInt64 = 0
    private(set) var active: ProcessSessionToken?

    mutating func begin(pid: Int32) -> ProcessSessionToken {
        nextGeneration &+= 1
        let token = ProcessSessionToken(generation: nextGeneration, pid: pid)
        active = token
        return token
    }

    mutating func clear() {
        active = nil
    }

    /// Returns true only when `token` still owns the active session. A
    /// successful finish consumes that ownership exactly once.
    mutating func finish(_ token: ProcessSessionToken) -> Bool {
        guard active == token else { return false }
        active = nil
        return true
    }
}
