import Foundation

/// Defines which `sing-box` process lifecycle operations are safe for the app.
///
/// YurecClient may start a session only when no other `sing-box` process exists,
/// and may terminate only the process it launched and tracks itself. An external
/// process is never adopted or used as a termination target.
struct ProcessOwnershipPolicy {
    enum StartDecision: Equatable {
        case allowed
        case alreadyOwnsProcess(pid: Int32)
        case externalProcessesRunning(pids: [Int32])
    }

    static func startDecision(
        ownedPID: Int32?,
        discoveredPIDs: [Int32]
    ) -> StartDecision {
        if let ownedPID {
            return .alreadyOwnsProcess(pid: ownedPID)
        }

        let externalPIDs = Array(Set(discoveredPIDs)).sorted()
        guard externalPIDs.isEmpty else {
            return .externalProcessesRunning(pids: externalPIDs)
        }

        return .allowed
    }

    static func terminationTargets(ownedPID: Int32?) -> [Int32] {
        ownedPID.map { [$0] } ?? []
    }
}
