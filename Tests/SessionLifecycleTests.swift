import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct SessionLifecycleTests {
    static func main() {
        staleTerminationCannotClearReplacement()
        pidReuseStillProducesDistinctSessions()
        activeTerminationIsConsumedExactlyOnce()
        print("SessionLifecycleTests: PASS")
    }

    private static func staleTerminationCannotClearReplacement() {
        var lifecycle = ProcessSessionLifecycle()
        let stopped = lifecycle.begin(pid: 101)
        lifecycle.clear()
        let replacement = lifecycle.begin(pid: 202)

        expect(!lifecycle.finish(stopped), "a stopped session must not own its replacement")
        expect(lifecycle.active == replacement, "stale termination must preserve the replacement")
        expect(lifecycle.finish(replacement), "the replacement must handle its own termination")
    }

    private static func pidReuseStillProducesDistinctSessions() {
        var lifecycle = ProcessSessionLifecycle()
        let first = lifecycle.begin(pid: 303)
        lifecycle.clear()
        let reusedPID = lifecycle.begin(pid: 303)

        expect(first != reusedPID, "generation must distinguish a reused PID")
        expect(!lifecycle.finish(first), "an old generation with the same PID must be stale")
        expect(lifecycle.active == reusedPID, "PID reuse must not lose the active session")
    }

    private static func activeTerminationIsConsumedExactlyOnce() {
        var lifecycle = ProcessSessionLifecycle()
        let session = lifecycle.begin(pid: 404)

        expect(lifecycle.finish(session), "the active session must finish")
        expect(lifecycle.active == nil, "finishing must clear active ownership")
        expect(!lifecycle.finish(session), "a duplicate callback must be ignored")
    }
}
