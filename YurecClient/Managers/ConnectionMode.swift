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

/// Minimal connection state captured before macOS goes to sleep.
///
/// Keeping this independent from `Profile` prevents a stale in-memory profile
/// object from being retained across a filesystem refresh while the machine is
/// asleep.
struct RecoverableConnection: Equatable {
    let profilePath: String
    let mode: ConnectionMode
}

/// One-shot state machine used by the sleep/wake lifecycle coordinator.
///
/// A wake notification may be delivered more than once. Consuming the pending
/// session ensures that only one reconnect attempt is scheduled for each sleep.
struct SleepWakeRecoveryState {
    private(set) var pendingSession: RecoverableConnection?

    @discardableResult
    mutating func capture(
        isRunning: Bool,
        profilePath: String?,
        mode: ConnectionMode?
    ) -> Bool {
        guard isRunning,
              let profilePath,
              !profilePath.isEmpty,
              let mode else {
            pendingSession = nil
            return false
        }
        pendingSession = RecoverableConnection(profilePath: profilePath, mode: mode)
        return true
    }

    mutating func takePendingSession() -> RecoverableConnection? {
        defer { pendingSession = nil }
        return pendingSession
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
