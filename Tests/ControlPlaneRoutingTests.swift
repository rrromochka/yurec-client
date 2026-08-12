import Foundation

@main
private enum ControlPlaneRoutingTests {
    static func main() {
        testDirectRulesAreInjectedAfterSniff()
        testInjectionIsIdempotent()
        testMixedInboundBypassesItsProxyCatchAll()
        testEmptyInputLeavesConfigUntouched()
        testWrittenTunConfigPassesSingBoxCheckWhenAvailable()
        print("Control-plane routing tests passed")
    }

    private static func testDirectRulesAreInjectedAfterSniff() {
        var config = fixture()
        expect(
            ConfigTransformer.applyDirectDomains(
                [" Subscription.Example. ", "subscription.example"],
                to: &config
            ),
            "a missing control-plane rule must modify the runtime config"
        )

        let route = config["route"] as? [String: Any]
        let routeRules = route?["rules"] as? [[String: Any]]
        expect(routeRules?.count == 3, "one route rule must be added")
        expect(routeRules?[0]["action"] as? String == "sniff", "sniff must remain first")
        expect(
            routeRules?[1]["domain"] as? [String] == ["subscription.example"],
            "the normalized domain must be routed immediately after sniff"
        )
        expect(routeRules?[1]["action"] as? String == "route", "route must use modern action syntax")
        expect(routeRules?[1]["outbound"] as? String == "direct", "route must use direct")

        let dns = config["dns"] as? [String: Any]
        let dnsRules = dns?["rules"] as? [[String: Any]]
        expect(dnsRules?.count == 1, "one DNS rule must be added")
        expect(dnsRules?[0]["domain"] as? [String] == ["subscription.example"], "DNS rule must match")
        expect(dnsRules?[0]["server"] as? String == "bootstrap", "DNS must use direct resolver")
        expect(dnsRules?[0]["action"] as? String == "route", "DNS must use modern route action")
    }

    private static func testInjectionIsIdempotent() {
        var config = fixture()
        _ = ConfigTransformer.applyDirectDomains(["subscription.example"], to: &config)
        expect(
            !ConfigTransformer.applyDirectDomains(["subscription.example"], to: &config),
            "reapplying the same domain must not duplicate rules"
        )
    }

    private static func testMixedInboundBypassesItsProxyCatchAll() {
        var config = fixture()
        config["inbounds"] = [["type": "mixed", "tag": "mixed-in"]]
        var route = config["route"] as! [String: Any]
        var rules = route["rules"] as! [[String: Any]]
        rules.insert(["inbound": ["mixed-in"], "outbound": "proxy"], at: 0)
        route["rules"] = rules
        config["route"] = route

        _ = ConfigTransformer.applyDirectDomains(["subscription.example"], to: &config)
        let updatedRules = (config["route"] as? [String: Any])?["rules"] as? [[String: Any]]
        expect(
            updatedRules?.first?["domain"] as? [String] == ["subscription.example"],
            "the control-plane domain must precede mixed-in's proxy catch-all"
        )
        expect(
            updatedRules?.first?["inbound"] as? [String] == ["mixed-in"],
            "the early bypass must be scoped to the mixed inbound"
        )

        expect(
            !ConfigTransformer.applyDirectDomains(["subscription.example"], to: &config),
            "mixed and global direct rules must remain idempotent"
        )
    }

    private static func testEmptyInputLeavesConfigUntouched() {
        var config = fixture()
        let before = try! JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        expect(!ConfigTransformer.applyDirectDomains([], to: &config), "empty input must be ignored")
        let after = try! JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        expect(before == after, "empty input must leave the config byte-equivalent")
    }

    private static func testWrittenTunConfigPassesSingBoxCheckWhenAvailable() {
        let binaryCandidates = ["/opt/homebrew/bin/sing-box", "/usr/local/bin/sing-box"]
        guard let binary = binaryCandidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { return }

        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("control-plane-source-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let sourceData = try! JSONSerialization.data(
            withJSONObject: runnableFixture(),
            options: [.prettyPrinted, .sortedKeys]
        )
        try! sourceData.write(to: sourceURL, options: .atomic)

        let transformedURL = try! ConfigTransformer.makeTunConfig(
            from: sourceURL.path,
            directDomains: ["subscription.example"]
        )
        expect(transformedURL != nil, "direct routing must produce an ephemeral TUN config")
        guard let transformedURL else { return }
        defer { try? FileManager.default.removeItem(at: transformedURL) }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: binary)
        task.arguments = ["check", "-c", transformedURL.path]
        task.standardOutput = Pipe()
        let stderr = Pipe()
        task.standardError = stderr
        try! task.run()
        task.waitUntilExit()
        let errorText = String(
            data: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        expect(
            task.terminationStatus == 0,
            "sing-box must accept the transformed runtime config: \(errorText)"
        )
    }

    private static func fixture() -> [String: Any] {
        [
            "dns": [
                "servers": [
                    ["tag": "remote", "type": "tls", "server": "1.1.1.1", "detour": "proxy"],
                    ["tag": "bootstrap", "type": "udp", "server": "192.0.2.53", "detour": "direct"]
                ],
                "final": "remote"
            ],
            "outbounds": [
                ["type": "selector", "tag": "proxy", "outbounds": ["exit", "direct"]],
                ["type": "vless", "tag": "exit", "server": "vpn.example", "server_port": 443],
                ["type": "direct", "tag": "direct"]
            ],
            "route": [
                "final": "proxy",
                "rules": [
                    ["action": "sniff"],
                    ["protocol": "dns", "action": "hijack-dns"]
                ]
            ]
        ]
    }

    private static func runnableFixture() -> [String: Any] {
        [
            "log": ["level": "error"],
            "dns": [
                "servers": [
                    ["tag": "remote", "type": "tls", "server": "1.1.1.1", "detour": "proxy"],
                    ["tag": "bootstrap", "type": "udp", "server": "192.0.2.53", "detour": "direct"]
                ],
                "final": "remote"
            ],
            "inbounds": [
                [
                    "type": "tun",
                    "tag": "tun-in",
                    "address": ["172.19.0.1/30"],
                    "auto_route": true,
                    "strict_route": true,
                    "stack": "mixed"
                ]
            ],
            "outbounds": [
                ["type": "selector", "tag": "proxy", "outbounds": ["exit", "direct"], "default": "exit"],
                [
                    "type": "vless",
                    "tag": "exit",
                    "server": "vpn.example",
                    "server_port": 443,
                    "uuid": "00000000-0000-4000-8000-000000000000",
                    "domain_resolver": "bootstrap"
                ],
                ["type": "direct", "tag": "direct", "domain_resolver": "bootstrap"]
            ],
            "route": [
                "auto_detect_interface": true,
                "final": "proxy",
                "rules": [
                    ["action": "sniff"],
                    ["protocol": "dns", "action": "hijack-dns"]
                ]
            ]
        ]
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
