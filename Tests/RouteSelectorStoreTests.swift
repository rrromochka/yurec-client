import Foundation

@main
private enum RouteSelectorStoreTests {
    static func main() throws {
        try testSelectorDiscovery()
        try testApplyingSelections()
        testPerProfilePersistenceAndFallback()
        print("RouteSelectorStore tests passed")
    }

    private static func testSelectorDiscovery() throws {
        let data = Data(
            """
            {
              "outbounds": [
                {"type":"direct","tag":"direct"},
                {
                  "type":"selector",
                  "tag":"proxy",
                  "outbounds":["Finland","USA","Finland","direct"],
                  "default":"Finland"
                },
                {
                  "type":"selector",
                  "tag":"media",
                  "outbounds":["one","two"],
                  "default":"missing"
                },
                {
                  "type":"selector",
                  "tag":"proxy",
                  "outbounds":["duplicate"]
                }
              ]
            }
            """.utf8
        )

        let selectors = try RouteSelectorConfig.selectors(in: data)
        expect(
            selectors == [
                RouteSelectorDescriptor(
                    tag: "proxy",
                    options: ["Finland", "USA", "direct"],
                    configDefault: "Finland"
                ),
                RouteSelectorDescriptor(
                    tag: "media",
                    options: ["one", "two"],
                    configDefault: nil
                )
            ],
            "selector discovery must preserve order, remove duplicate options/tags, and validate defaults"
        )
    }

    private static func testApplyingSelections() throws {
        let data = Data(
            """
            {
              "outbounds": [
                {
                  "type":"selector",
                  "tag":"proxy",
                  "outbounds":["Finland","USA"],
                  "default":"Finland"
                }
              ]
            }
            """.utf8
        )
        guard var config = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            fatalError("test fixture is invalid")
        }

        expect(
            RouteSelectorConfig.apply(defaults: ["proxy": "USA"], to: &config),
            "a valid different route must update the runtime config"
        )
        let outbounds = config["outbounds"] as? [[String: Any]]
        expect(outbounds?.first?["default"] as? String == "USA", "selected route must become default")

        expect(
            !RouteSelectorConfig.apply(defaults: ["proxy": "missing"], to: &config),
            "a stale route must be ignored"
        )
        let unchangedOutbounds = config["outbounds"] as? [[String: Any]]
        expect(
            unchangedOutbounds?.first?["default"] as? String == "USA",
            "invalid selection must not alter config"
        )
    }

    private static func testPerProfilePersistenceAndFallback() {
        let suiteName = "RouteSelectorStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("cannot create isolated defaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = RouteSelectorStore(defaults: defaults)
        let profileURL = URL(fileURLWithPath: "/tmp/test-profile.json")
        let original = RouteSelectorDescriptor(
            tag: "proxy",
            options: ["Finland", "USA"],
            configDefault: "Finland"
        )

        expect(
            store.selectedOption(for: original, profileURL: profileURL) == "Finland",
            "config default must be used before the user chooses a route"
        )
        store.setSelectedOption("USA", selectorTag: "proxy", profileURL: profileURL)
        expect(
            store.resolvedDefaults(for: profileURL, selectors: [original]) == ["proxy": "USA"],
            "user choice must persist per profile"
        )

        let refreshed = RouteSelectorDescriptor(
            tag: "proxy",
            options: ["Finland"],
            configDefault: "Finland"
        )
        expect(
            store.selectedOption(for: refreshed, profileURL: profileURL) == "Finland",
            "a removed route must fall back safely after subscription refresh"
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
