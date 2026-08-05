import Foundation

/// Transforms a sing-box JSON config for SOCKS5 mode.
///
/// **Plain SOCKS5** (no apps selected — `routedProcessNames` is empty):
///   - Removes `tun` inbounds (no TUN needed)
///   - Replaces `socks`/`mixed` inbounds with a fresh `mixed` inbound on the given port
///   - Strips `fakeip` DNS entries (TUN-only feature)
///   - Routing unchanged — all traffic goes through proxy by default
///
/// **Hybrid TUN+SOCKS5** (apps selected — `routedProcessNames` is non-empty):
///   - Keeps the `tun` inbound so TUN captures all traffic for per-process routing
///   - Replaces `socks`/`mixed` inbounds with a fresh `mixed` inbound on the given port
///   - Keeps fakeip DNS (required for TUN)
///   - Selected apps → proxy outbound; route.final = "direct" (everything else bypasses VPN)
///
/// The `mixed` inbound type accepts both SOCKS5 and HTTP CONNECT on the same port,
/// allowing CLI tools to use `http_proxy`/`https_proxy` env vars without a separate port.
enum ConfigTransformer {

    enum Error: LocalizedError {
        case unreadable
        case invalidJSON
        var errorDescription: String? {
            switch self {
            case .unreadable:   return "Cannot read profile config file."
            case .invalidJSON:  return "Profile config is not valid JSON."
            }
        }
    }

    static func makeSocks5Config(
        from profilePath: String,
        port: Int,
        routedProcessNames: [String] = [],
        selectorDefaults: [String: String] = [:]
    ) throws -> URL {
        guard let data = FileManager.default.contents(atPath: profilePath) else {
            throw Error.unreadable
        }
        guard var config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Error.invalidJSON
        }

        RouteSelectorConfig.apply(defaults: selectorDefaults, to: &config)

        let hybridTun = !routedProcessNames.isEmpty

        // --- Inbounds ---
        var inbounds = (config["inbounds"] as? [[String: Any]]) ?? []
        if !hybridTun {
            // Plain SOCKS5: drop TUN inbound, no root-level network capture needed.
            inbounds.removeAll { ($0["type"] as? String) == "tun" }
        }
        // In hybrid TUN mode: keep the TUN inbound but strip legacy fields removed in sing-box 1.13.0.
        inbounds = inbounds.map { Self.sanitizeTunInbound($0) }
        inbounds.removeAll { ($0["type"] as? String) == "socks" || ($0["type"] as? String) == "mixed" }
        inbounds.insert([
            "type":        "mixed",
            "tag":         "mixed-in",
            "listen":      "127.0.0.1",
            "listen_port": port
        ], at: 0)
        config["inbounds"] = inbounds

        // --- DNS ---
        if !hybridTun {
            // Plain SOCKS5: strip fakeip (TUN-only feature).
            if var dns = config["dns"] as? [String: Any] {
                if var servers = dns["servers"] as? [[String: Any]] {
                    // Collect tags of fakeip servers before removing them so we can
                    // also remove any DNS rules that reference them. Without this, rules
                    // like {"query_type":["A","AAAA"],"server":"fakeip"} survive the
                    // cleanup and point at a non-existent server, breaking A/AAAA
                    // resolution — the root cause of sites like mail.google.com or
                    // Yandex failing in SOCKS5 mode.
                    let fakeipTags = Set(servers.compactMap { s -> String? in
                        guard (s["type"] as? String) == "fakeip" else { return nil }
                        return s["tag"] as? String
                    })

                    servers.removeAll { ($0["type"] as? String) == "fakeip" }
                    if servers.isEmpty {
                        servers = [["tag": "remote", "address": "tls://1.1.1.1", "detour": "proxy"]]
                    }
                    dns["servers"] = servers

                    if !fakeipTags.isEmpty, var rules = dns["rules"] as? [[String: Any]] {
                        rules.removeAll { ($0["server"] as? String).map { fakeipTags.contains($0) } ?? false }
                        dns["rules"] = rules
                    }
                }
                dns.removeValue(forKey: "fakeip")
                config["dns"] = dns
            }
        }
        // Hybrid TUN mode: keep fakeip DNS unchanged — TUN requires it.

        // --- Route ---
        if hybridTun {
            // Build routing rules for hybrid TUN+SOCKS5 mode.
            // `find_process = true` lets sing-box resolve the originating process name.
            var route = (config["route"] as? [String: Any]) ?? [:]
            let proxyOutbound = route["final"] as? String ?? "proxy"
            var rules = (route["rules"] as? [[String: Any]]) ?? []

            // Rule 2 — selected apps (including their helper processes) via TUN → proxy.
            rules.insert([
                "process_name": routedProcessNames,
                "outbound":     proxyOutbound
            ], at: 0)

            // Rule 1 — block QUIC (UDP port 443) for selected apps.
            // Chrome and Yandex Browser aggressively try QUIC/HTTP3 over UDP when they
            // don't detect a system proxy. TUN captures this UDP traffic but most proxies
            // can't relay UDP reliably, causing sites like mail.google.com or Yandex to
            // fail. Dropping UDP 443 here makes the browser fall back to TCP/TLS
            // immediately, which then flows normally via TUN → proxy (Rule 2 above).
            rules.insert([
                "process_name": routedProcessNames,
                "network":      "udp",
                "port":         [443],
                "outbound":     "block"
            ], at: 0)

            // Rule 0 — traffic arriving on the SOCKS5 inbound always goes to proxy.
            // This preserves the behaviour of apps (e.g. Telegram) that are manually
            // configured to use the local SOCKS5 proxy: they bypass TUN entirely and
            // connect directly to 127.0.0.1:port, so process_name rules never see them.
            // Without this rule they would fall through to route.final = "direct".
            rules.insert([
                "inbound":  ["mixed-in"],
                "outbound": proxyOutbound
            ], at: 0)

            route["rules"]        = rules
            route["find_process"] = true
            route["final"]        = "direct"  // unlisted apps bypass VPN
            config["route"] = route

            // Ensure "block" outbound exists — required for the QUIC-blocking rule above.
            // Most profiles already include it for ad-blocking; add it only when missing.
            if var outbounds = config["outbounds"] as? [[String: Any]] {
                if !outbounds.contains(where: { ($0["tag"] as? String) == "block" }) {
                    outbounds.append(["type": "block", "tag": "block"])
                    config["outbounds"] = outbounds
                }
            }
        }

        // When the host has no globally-routable IPv6 address, force IPv4-only DNS.
        // Without this, browsers receive AAAA records and attempt IPv6 via TUN;
        // sing-box accepts the TCP handshake locally then RSTs on failure, which
        // browsers surface as ERR_CONNECTION_RESET instead of a transparent IPv4
        // fallback (observed with Yandex/kinopoisk, Gmail, and similar dual-stack sites).
        // When IPv6 is available on the physical interface we leave the strategy
        // untouched so dual-stack connections work normally.
        if !DNSHelper.hasGlobalIPv6() {
            if var dns = config["dns"] as? [String: Any] {
                dns["strategy"] = "ipv4_only"
                config["dns"] = dns
            }
        }
        // Plain SOCKS5: routing unchanged (all traffic through proxy by default).

        // Write to temp file (deleted on stop)
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("yurec-socks5-\(UUID().uuidString).json")
        let outData = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try outData.write(to: out)
        return out
    }

    /// Sanitizes a profile config for plain TUN mode by stripping legacy inbound fields
    /// removed in sing-box 1.13.0 (`sniff`, `sniff_override_destination`, `domain_strategy`,
    /// `udp_timeout`). Returns the path to a sanitized temp file, or `nil` if the profile is
    /// already clean (so the caller can use the original file directly).
    static func makeTunConfig(
        from profilePath: String,
        selectorDefaults: [String: String] = [:]
    ) throws -> URL? {
        guard let data = FileManager.default.contents(atPath: profilePath) else {
            throw Error.unreadable
        }
        guard var config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Error.invalidJSON
        }

        let selectorsChanged = RouteSelectorConfig.apply(defaults: selectorDefaults, to: &config)
        let inbounds = (config["inbounds"] as? [[String: Any]]) ?? []
        let sanitized = inbounds.map { Self.sanitizeTunInbound($0) }
        let inboundsChanged = !zip(inbounds, sanitized).allSatisfy {
            NSDictionary(dictionary: $0.0).isEqual(to: $0.1)
        }
        guard selectorsChanged || inboundsChanged else {
            return nil  // nothing to change — use original file
        }
        if inboundsChanged {
            config["inbounds"] = sanitized
        }

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("yurec-tun-\(UUID().uuidString).json")
        let outData = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
        try outData.write(to: out)
        return out
    }

    // Removes legacy per-inbound fields deprecated in sing-box 1.11.0 and removed in 1.13.0.
    private static func sanitizeTunInbound(_ inbound: [String: Any]) -> [String: Any] {
        guard (inbound["type"] as? String) == "tun" else { return inbound }
        var clean = inbound
        clean.removeValue(forKey: "sniff")
        clean.removeValue(forKey: "sniff_override_destination")
        clean.removeValue(forKey: "domain_strategy")
        clean.removeValue(forKey: "udp_timeout")
        return clean
    }
}
