import Foundation

@main
private enum ProcessOwnershipPolicyTests {
    static func main() {
        permitsAFirstOwnedSession()
        rejectsAnAlreadyOwnedSession()
        rejectsExternalSessionsWithoutAdoptingThem()
        terminatesOnlyTheOwnedProcess()
        print("Process ownership policy tests passed")
    }

    private static func permitsAFirstOwnedSession() {
        expect(
            ProcessOwnershipPolicy.startDecision(ownedPID: nil, discoveredPIDs: []) == .allowed,
            "an idle host must permit a new owned session"
        )
    }

    private static func rejectsAnAlreadyOwnedSession() {
        expect(
            ProcessOwnershipPolicy.startDecision(ownedPID: 101, discoveredPIDs: [])
                == .alreadyOwnsProcess(pid: 101),
            "the app must not start a second session while it owns one"
        )
    }

    private static func rejectsExternalSessionsWithoutAdoptingThem() {
        expect(
            ProcessOwnershipPolicy.startDecision(
                ownedPID: nil,
                discoveredPIDs: [404, 202, 404]
            ) == .externalProcessesRunning(pids: [202, 404]),
            "external sessions must be reported deterministically and never adopted"
        )
    }

    private static func terminatesOnlyTheOwnedProcess() {
        expect(
            ProcessOwnershipPolicy.terminationTargets(ownedPID: 303) == [303],
            "stop must target only the process launched by this app"
        )
        expect(
            ProcessOwnershipPolicy.terminationTargets(ownedPID: nil).isEmpty,
            "stop must have no target when the app owns no process"
        )
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard condition() else {
            fatalError("\(message) (\(file):\(line))")
        }
    }
}
