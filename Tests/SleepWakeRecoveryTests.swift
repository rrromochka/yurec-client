import Foundation

@main
private enum SleepWakeRecoveryTests {
    static func main() {
        testDisconnectedSessionIsNotCaptured()
        testSessionIsRestoredAtMostOnce()
        testNewSleepReplacesStalePendingState()
        print("Sleep/wake recovery tests passed")
    }

    private static func testDisconnectedSessionIsNotCaptured() {
        var state = SleepWakeRecoveryState()
        expect(
            !state.capture(isRunning: false, profilePath: "/tmp/profile.json", mode: .tun),
            "a disconnected client must not schedule wake recovery"
        )
        expect(state.takePendingSession() == nil, "no disconnected session may be restored")
    }

    private static func testSessionIsRestoredAtMostOnce() {
        var state = SleepWakeRecoveryState()
        let expected = RecoverableConnection(
            profilePath: "/tmp/profile.json",
            mode: .socks5(port: 2080)
        )
        expect(
            state.capture(
                isRunning: true,
                profilePath: expected.profilePath,
                mode: expected.mode
            ),
            "an active session must be captured"
        )
        expect(state.takePendingSession() == expected, "wake must restore the captured session")
        expect(state.takePendingSession() == nil, "duplicate wake notifications must be ignored")
    }

    private static func testNewSleepReplacesStalePendingState() {
        var state = SleepWakeRecoveryState()
        _ = state.capture(isRunning: true, profilePath: "/tmp/old.json", mode: .tun)
        expect(
            !state.capture(isRunning: false, profilePath: nil, mode: nil),
            "a later disconnected sleep must clear stale recovery state"
        )
        expect(state.takePendingSession() == nil, "stale sessions must not survive a later sleep")
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard condition() else { fatalError("\(message) (\(file):\(line))") }
    }
}
