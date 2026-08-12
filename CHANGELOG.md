# Changelog

## [Unreleased] — Cambodgia downstream

### Features

- **Profile-driven route selector** — standard sing-box `selector` outbounds
  are exposed in the status menu and persisted per profile and selector tag.
- **Explicit Yurec profile import** — valid upstream profile files can be
  copied as independent snapshots without changing their source.

### Bug Fixes

- **Live subscription refresh** — updating the active subscription now restarts
  sing-box in the same connection mode so the downloaded config takes effect
  immediately. If an explicitly selected route was revoked, the stale choice is
  cleared, the refreshed profile's safe fallback is applied, and the user is
  notified about the route change.
- **Reliable route switching** — profile, route and connection-mode changes now
  wait for the app's previous sing-box session to exit before launching its
  replacement, preventing a stale TUN session from racing the restart.

### Security and isolation

- The downstream app now uses bundle ID
  `ru.rom-gorodnichev.cambodgia.yurecclient`, a separate product name,
  `UserDefaults` domain, Application Support profile directory, log directory,
  runtime config prefix and subscription User-Agent.
- Profile directories use mode `0700`; profiles, downloaded configs and
  temporary runtime configs use mode `0600`.
- Cambodgia YurecClient no longer adopts or globally terminates external
  `sing-box` processes. A second VPN connection is refused without modifying
  the session owned by upstream YurecClient or another application.
- The downstream only probes an already installed legacy upstream sudoers rule.
  It cannot create, overwrite or remove the shared system record.
- Product-isolation and route-selector tests pass; the complete unsigned Debug
  application builds successfully with Xcode 27.

### Known release blocker

- Local development may still reuse upstream's broad passwordless sudoers
  mechanism when it already exists. It must be replaced by a constrained
  privileged helper before a public downstream release.

## [1.2.1] — 2026-06-06

### Improvements

- **HTTP proxy on the same port** — the SOCKS5 inbound is now a `mixed` inbound that accepts both SOCKS5 and HTTP CONNECT on the same port. CLI tools (e.g. `codex`, `curl`, `git`) can now route through the proxy using standard `http_proxy`/`https_proxy` environment variables without a separate port. Existing SOCKS5 integrations (Telegram, etc.) continue to work unchanged.

---

## [1.2.0] — 2026-05-22

### Bug Fixes

- **SOCKS5 hybrid: ERR_CONNECTION_RESET on dual-stack sites (Yandex, Gmail, Kinopoisk, etc.)** — in hybrid TUN+SOCKS5 mode (`route.final = "direct"`) browsers use Happy Eyeballs and race IPv4/IPv6 connections simultaneously. sing-box accepted the IPv6 TCP handshake locally via TUN, then sent a TCP RST when it could not forward the connection outbound (no global IPv6 on the machine). Because the RST arrived after the handshake, browsers treated it as a server-side reset rather than an unreachable address and did not fall back to IPv4. Fix: at config generation time the client checks whether any physical interface has a globally-routable IPv6 address (`DNSHelper.hasGlobalIPv6()`); if not, `dns.strategy` is set to `ipv4_only` so AAAA records are never returned to clients and no IPv6 connection is attempted. On dual-stack networks the strategy is left unchanged and IPv6 works normally.

---

## [1.1.1] — 2026-05-22

### Bug Fixes

- **sing-box 1.13.x compatibility** — fixed fatal startup error with sing-box 1.13.4 and later. These versions enforce removal of legacy inbound-level fields (`sniff`, `sniff_override_destination`, `domain_strategy`, `udp_timeout`) that were deprecated in 1.11.0. YurecClient now strips these fields automatically from any profile at launch — both from subscription-generated configs and from manually crafted profiles. Minimum supported sing-box version: **1.11.0**.

### Improvements

- **sing-box version in menu** — the context menu now shows YurecClient and sing-box versions (e.g. `YurecClient 1.1.1 · sing-box 1.13.12`) as a non-interactive label at the bottom

---

## [1.1.0] — 2026-05-22

### Features

- **Subscriptions** — add a profile from a subscription URL via Add from URL... in the Profiles tab. Supported protocols: VLESS (including XTLS Reality), VMess, Shadowsocks, Trojan, Hysteria2. Response formats: base64-encoded URI list, plain-text URI list, ready-made sing-box JSON
- **Subscription update** — each subscription profile stores its source URL; Update button re-downloads and overwrites the config while preserving per-profile settings (SOCKS5 port, App Routing)
- **HWID device identification** — subscription requests include `x-hwid`, `x-device-os`, `x-ver-os`, `x-device-model` HTTP headers for device tracking in the management panel (compatible with Remnawave)

### Improvements

- **Generated config format** — subscription-generated configs now use the modern sing-box API: `address` array instead of `inet4_address`, `stack: mixed`, `action: hijack-dns`, `ip_is_private`, `domain_resolver`; fully compatible with TUN, SOCKS5, and hybrid TUN+SOCKS5 modes

---

## [1.0.1] — 2026-04-25

### Bug Fixes

- **SOCKS5: fixed broken page loading for certain sites (Yandex, Gmail, Google Meet, etc.)**
In plain SOCKS5 mode, the fakeip DNS server was removed from the config but DNS rules referencing it (e.g. `{"query_type": ["A","AAAA"], "server": "fakeip"}`) were left intact. Sing-box attempted to route A/AAAA queries to the now-missing server, causing DNS resolution to fail. Sites that rely on many subdomains would not load or loaded only partially.

- **TUN+SOCKS5: fixed broken page loading in hybrid mode**
Chrome and Yandex Browser aggressively use QUIC/HTTP3 (UDP) for Google and Yandex services when no system proxy is detected. TUN captured this UDP traffic, but most proxy servers do not support UDP relay — connections were dropped. A routing rule is now injected that blocks UDP port 443 for selected processes, causing the browser to immediately fall back to TCP, which flows correctly through TUN → proxy.

---

## [1.0.0] — 2026-04-25

First public release — a macOS menu bar front-end for [sing-box](https://sing-box.sagernet.org/).

### Features

- **TUN mode** — full-system VPN via virtual network interface; all traffic intercepted at L3 level, DNS redirected to sing-box fake-ip stack
- **SOCKS5 mode** — sets macOS system proxy; or hybrid TUN+SOCKS5 when App Routing list is non-empty
- **App Routing** — route only specific apps through VPN while everything else goes direct
  - Auto-detection of all helper processes for `.app` bundles (Electron apps: Claude, ChatGPT, VS Code)
  - Support for plain executables (e.g. `claude` binary from Claude Code VS Code extension)
- **Profiles** — manage multiple sing-box JSON configs from `~/.singbox/profiles/`; live-reload via FSEvents; per-profile SOCKS5 port and routing overrides
- **Sudoers auto-install** — passwordless `sudo` rule installed once on first connect
- **External process detection** — automatically adopts a `sing-box` process started outside the app (Terminal, launchd, etc.)
- **Launch at Login** + **Auto-connect on launch**
- **Log viewer** — `~/Library/Logs/YurecClient/sing-box.log`; clear and size-limit controls in Settings
