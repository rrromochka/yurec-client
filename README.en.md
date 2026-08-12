# YurecClient

A macOS menu bar application — a graphical front-end for [sing-box](https://sing-box.sagernet.org/). Lets you start sing-box in two modes (TUN and SOCKS5) with a single click from the status bar, manage configuration profiles, and configure per-process traffic routing.

---

## Table of Contents

- [Requirements](#requirements)
- [Architecture](#architecture)
- [TUN Mode](#tun-mode)
- [SOCKS5 Mode](#socks5-mode)
- [Profiles](#profiles)
- [Subscriptions](#subscriptions)
- [App Routing](#app-routing)
- [Practical Setup: ChatGPT, Claude, VS Code](#practical-setup)
- [Sudoers and Permissions](#sudoers-and-permissions)
- [Launch at Login and Auto-connect](#launch-at-login-and-auto-connect)
- [External Process Detection](#external-process-detection)
- [Logs](#logs)
- [Project Structure](#project-structure)

---

## Requirements

- macOS 13 Ventura or later
- [sing-box](https://sing-box.sagernet.org/) installed on the system:
  - `/usr/local/bin/sing-box` (auto-detected)
  - `/opt/homebrew/bin/sing-box` (auto-detected)
  - or any custom path set in Settings
- Xcode 15+ to build

---

## Architecture

```
YurecClient
├── AppDelegate                  — entry point, NSStatusItem initialisation
├── Managers/
│   ├── ProxyManager             — start/stop sing-box, process lifecycle management
│   ├── ProfileManager           — storage and observation of JSON configs, subscriptions
│   ├── SubscriptionParser       — proxy URI parsing and sing-box config assembly
│   ├── ConfigTransformer        — config transformation for SOCKS5 mode
│   ├── AppRoutingStore          — storage of per-app routing lists
│   ├── AppRoutingEntry          — model for a single app in the routing list
│   ├── ConnectionMode           — enum: .tun / .socks5(port:)
│   ├── SudoersManager           — manages the /etc/sudoers.d/yurec rule
│   └── LaunchAtLoginManager     — launch-at-login via ServiceManagement
├── Helpers/
│   ├── DNSHelper                — set/reset DNS via networksetup
│   └── SystemProxyHelper        — set/reset macOS system SOCKS5 proxy
└── UI/
    ├── StatusMenuController     — status bar menu, icon, animations
    └── Settings/
        ├── GeneralTabView       — general settings, global App Routing list
        └── ProfilesTabView      — profile management, per-profile settings, subscriptions
```

The central singleton is `ProxyManager`. All other components either call it directly or subscribe to its `@Published` properties (`isRunning`, `currentMode`) via Combine.

---

## TUN Mode

### What happens

TUN mode creates a virtual network interface at the kernel level. All outgoing system traffic is intercepted by sing-box at the L3 layer (IP packets), regardless of whether an application knows about a proxy or not. This is a true full-VPN mode — all traffic goes through the VPN.

### Start sequence

```
StatusMenuController.connectTun()
  └── beginConnect(to: .tun, profile:)
        └── ProxyManager.start(profilePath:, mode: .tun)
              1. killOrphanedSingBox()          — kill any orphaned sing-box processes
              2. configPath = profilePath       — TUN uses the profile directly, no transformation
              3. SudoersManager.isInstalled()   — check whether the sudoers rule exists
                  └── if not → SudoersManager.install() → password dialog (once ever)
              4. open/create log file           — ~/Library/Logs/YurecClient/sing-box.log
              5. Process() with sudo -n         — sudo -n /path/to/sing-box run -c config.json
              6. isRunning = true               — synchronously, before registering terminationHandler
              7. task.terminationHandler        — dispatched async on main queue → handleProcessTermination()
              8. DNSHelper.setDNS("172.19.0.1") — redirect DNS on all network interfaces
                                                  to sing-box's fake-ip stack
```

### DNS in TUN mode

After sing-box starts, `DNSHelper.setDNS("172.19.0.1")` runs for every enabled network service:

```sh
sudo -n /usr/sbin/networksetup -setdnsservers "Wi-Fi" 172.19.0.1
```

`172.19.0.1` is the fake-ip DNS server address inside sing-box's TUN interface. All DNS queries from applications are routed to sing-box, which returns synthetic IPs in the `198.18.x.x` range and maps them to real domains for subsequent routing decisions.

### Stopping TUN

```
ProxyManager.stop()
  1. SIGKILL all sing-box child processes (pgrepSingBox + forceKillPIDs)
  2. killProcess() — terminate() + SIGTERM by PID
  3. DNSHelper.resetDNS() — reset DNS back to "empty" (DHCP)
  4. cleanupMode() — clear state
  5. isRunning = false
  6. startLaunchDetectionLoop() — begin watching for sing-box to appear externally
```

### macOS sleep and wake

Before macOS sleeps, the client records the active profile and mode, stops its
owned sing-box session, and restores DNS. After wake, it waits for the physical
Wi-Fi/Ethernet interface to become stably usable and restores that same profile
and mode exactly once. This prevents a live sing-box process from retaining
stale TUN routes and DNS state across sleep.

---

## SOCKS5 Mode

SOCKS5 mode operates in two sub-modes depending on whether the App Routing list is populated:

### Sub-mode A: plain SOCKS5 (app list is empty)

sing-box starts without a TUN interface. An **HTTP/SOCKS5 proxy** (`mixed` inbound) is opened on `127.0.0.1:<port>`. YurecClient sets the **macOS system proxy** via `networksetup`, causing browsers, Electron apps, and any application that respects system proxy settings to automatically route traffic through sing-box. All proxied traffic goes through the VPN.

### Sub-mode B: hybrid TUN+SOCKS5 (app list is non-empty)

Both a **TUN interface** (intercepts all system traffic) and an **HTTP/SOCKS5 proxy** (`mixed` inbound, for apps with an explicit proxy setting, e.g. Telegram or CLI tools via `http_proxy`/`https_proxy`) are started. The macOS system proxy is **not set** — TUN already intercepts everything.

Process-level routing:
- Apps in the list → **through VPN** (`proxy` outbound)
- Traffic arriving on the mixed inbound (Telegram, CLI tools, and similar) → **through VPN** always
- Everything else → **direct**

This lets you route only specific apps (e.g. Claude, ChatGPT, VS Code) through the VPN while leaving the browser, mail client, and everything else on a direct connection.

### Start sequence

```
ProxyManager.start(profilePath:, mode: .socks5(port:))
  1. killOrphanedSingBox()
  2. ensurePortFreeForSocks5(port)     — verify the port is available
  3. AppRoutingStore.effectiveProcessNames(for: profile)
                                       — get process_name list (with helpers)
  4. ConfigTransformer.makeSocks5Config(...)
                                       — transform config (see below)
  5. SudoersManager.isInstalled()
  6. Process() with sudo -n
  7. isRunning = true

  If the list is empty (plain SOCKS5):
  8a. SystemProxyHelper.enableSOCKS5(port:) — set macOS system proxy

  If the list is non-empty (hybrid TUN+SOCKS5):
  8b. DNSHelper.setDNS("172.19.0.1")        — same as TUN mode
```

### Config transformation (ConfigTransformer)

`ConfigTransformer.makeSocks5Config()` produces a temporary JSON file at `/tmp/yurec-socks5-<UUID>.json`:

**Plain SOCKS5** (list empty):
1. Removes `tun` inbounds
2. Replaces `socks`/`mixed` inbounds with a fresh `mixed` inbound on the configured port
3. Removes `fakeip` DNS servers
4. `route.final` is left unchanged

**Hybrid TUN+SOCKS5** (list non-empty):
1. Keeps the `tun` inbound as-is
2. Replaces `socks`/`mixed` inbounds with a fresh `mixed` inbound on the configured port
3. Keeps `fakeip` DNS (required for TUN)
4. Prepends two rules to `route.rules`:
   ```json
   { "inbound": ["mixed-in"], "outbound": "proxy" }
   { "process_name": ["Claude", "Claude Helper (Renderer)", ...], "outbound": "proxy" }
   ```
5. Sets `route.final = "direct"` and `find_process = true`

### Stopping SOCKS5

```
ProxyManager.stop()
  1. SIGKILL all sing-box child processes
  2. killProcess()

  Plain SOCKS5:
  3a. SystemProxyHelper.disableSOCKS5()  — remove the system proxy

  Hybrid TUN+SOCKS5:
  3b. DNSHelper.resetDNS()               — reset DNS

  4. cleanupMode() — delete temp config, reset socks5UsesTun flag
  5. isRunning = false
  6. startLaunchDetectionLoop()
```

---

## Profiles

Profiles are sing-box JSON configuration files stored in `~/.singbox/profiles/`. The app watches this directory via **FSEvents** and automatically refreshes the profile list when files are added or removed.

### Ways to add a profile

| Button | Description |
|---|---|
| **Add...** | Import an existing sing-box JSON file from disk |
| **Add from URL...** | Create a profile from a subscription URL (see [Subscriptions](#subscriptions)) |
| **New Profile...** | Create a blank template profile for manual editing |

### Profile contents

A standard sing-box JSON with:
- `inbounds` — incoming transports (TUN, SOCKS5, etc.)
- `outbounds` — egress destinations (proxy, direct, block)
- `route.rules` — traffic routing rules
- `route.final` — default outbound (typically `"proxy"`)
- `dns` — DNS servers, including fake-ip for TUN

### Per-profile settings

- **SOCKS5 Port** — port for SOCKS5 mode (default 2080)
- **App Routing override** — flag and a profile-specific app list that replaces the global one
- **Subscription** — the subscription URL (shown for subscription-based profiles) and an **Update** button

---

## Subscriptions

A subscription is a URL that serves a list of proxy servers. When added, YurecClient downloads the configuration and automatically converts it into a complete sing-box JSON.

### How to add

Settings → Profiles → **Add from URL...**

- **Subscription URL** — the subscription link
- **Profile Name** — profile name (pre-filled from the URL hostname)

### Updating

The profile settings panel shows the subscription URL and an **Update** button — clicking it re-downloads and overwrites the config. Per-profile settings (SOCKS5 port, App Routing) are preserved.

### Supported response formats

| Format | Description |
|---|---|
| Base64 (standard and URL-safe) | Proxy URIs encoded in base64 — the most common subscription format |
| Plain text | Proxy URIs, one per line |
| sing-box JSON | A ready-made config — used as-is without conversion |

### Supported protocols

| Protocol | URI format |
|---|---|
| VLESS | `vless://uuid@host:port?params#name` — including XTLS Reality |
| VMess | `vmess://base64(JSON)` |
| Shadowsocks | `ss://base64(method:password)@host:port#name` (SIP002 and legacy) |
| Trojan | `trojan://password@host:port?params#name` |
| Hysteria2 | `hysteria2://password@host:port?params#name` and `hy2://...` |

### Generated config

The proxy URIs are assembled into a complete sing-box config compatible with all operating modes:

```
inbounds:
  - tun-in   (inet4_address: 172.19.0.1/30, auto_route, strict_route)
  - socks-in (127.0.0.1:2080, replaced by ConfigTransformer at start)

dns:
  - remote  → tls://1.1.1.1    (via proxy)
  - local   → 223.5.5.5        (direct, for outbound DNS queries)
  - fakeip  → 198.18.0.0/15    (for TUN)

outbounds:
  - selector "proxy"  (switch between servers when multiple are present)
  - <proxy outbounds> (VLESS / VMess / SS / Trojan / Hysteria2)
  - direct / block / dns-out

route:
  - DNS       → dns-out
  - private   → direct
  - everything else → proxy
```

When a subscription contains multiple servers, a `selector` outbound is created — the active server can be switched via the Clash API.

---

## App Routing

### Two-tier system

```
GlobalEntries (UserDefaults: appRouting.global.v1)
     └── applied to every profile where overridesGlobal = false

ProfileEntries (UserDefaults: appRouting.profile.entries.<path>)
     └── applied to the specific profile when overridesGlobal = true
```

### Automatic helper process detection

macOS apps — especially Electron-based ones (Claude, VS Code, ChatGPT) — spawn multiple child processes with names different from the main binary. For example:

| App | Main process | Processes that make network calls |
|---|---|---|
| Claude.app | `Claude` | `Claude Helper (Renderer)`, `Claude Helper (Plugin)` |
| VS Code | `Code` | `Code Helper (Plugin)` (extension host) |
| ChatGPT | `ChatGPT` | `ChatGPT`, `Updater`, `Downloader` (Sparkle) |

When a `.app` bundle is added, `AppRoutingEntry` recursively scans `Contents/` and automatically collects the executable names of all nested `.app`, `.xpc`, and `.appex` bundles. All of them are included in the `process_name` rule sent to sing-box. Nothing is stored — this is computed dynamically from the bundle on every start.

### Plain executable support

In addition to `.app` bundles, the file picker accepts plain executables. This is required for standalone binaries like the Claude Code VS Code extension's native binary, which lives outside the VS Code app bundle:

```
~/.vscode/extensions/anthropic.claude-code-*/resources/native-binary/claude
```

### How to add an app

In Settings (General or Profiles tab), click `+`. You can select:
- An `.app` bundle from `/Applications` — all helper processes are detected automatically
- A plain executable (e.g. `claude`) by pressing `Cmd+Shift+G` to navigate to the path

---

## Practical Setup

### Scenario: Claude desktop, ChatGPT, and the Claude Code VS Code plugin go through VPN; everything else is direct

Use **SOCKS5 mode** with a non-empty App Routing list (hybrid TUN+SOCKS5).

#### Step 1. Add Claude.app

Settings → `+` → `/Applications/Claude.app`

Automatically included processes:
- `Claude`
- `Claude Helper`
- `Claude Helper (GPU)`
- `Claude Helper (Plugin)`
- `Claude Helper (Renderer)`

#### Step 2. Add ChatGPT.app

Settings → `+` → `/Applications/ChatGPT.app`

Automatically included:
- `ChatGPT`
- `Widgets` (macOS widget)
- `Updater`, `Downloader`, `Installer` (Sparkle auto-updater also goes through VPN)

#### Step 3. Add VS Code

Settings → `+` → `/Applications/Visual Studio Code.app`

Automatically included:
- `Code`
- `Code Helper`
- `Code Helper (GPU)`
- `Code Helper (Plugin)` ← this is where extensions run
- `Code Helper (Renderer)`

> This covers the editor itself and all built-in extensions. However, the **Claude Code** plugin spawns a separate native binary outside the VS Code bundle — it must be added manually.

#### Step 4. Add the Claude Code native binary

Settings → `+` → press `Cmd+Shift+G` in the panel → paste:

```
~/.vscode/extensions
```

Navigate to `anthropic.claude-code-<version>-darwin-arm64/resources/native-binary/` and select the `claude` file.

Process name: `claude`

> The path changes when the plugin updates (the version in the folder name changes). If the plugin stops routing through VPN after an update, repeat this step.

#### Step 5. Connect in SOCKS5 mode

Click the menu bar icon → select a profile → **SOCKS5**.

After connecting:
- Claude desktop, ChatGPT, VS Code, and Claude Code plugin → through VPN
- Browser, mail client, and everything else → direct
- Telegram with an explicit proxy setting (`127.0.0.1:2080`) → through VPN via the SOCKS5 inbound

#### Telegram with an explicit proxy

If Telegram is configured to use proxy `127.0.0.1:2080`, it will work through the VPN automatically. You do not need to add Telegram to the App Routing list: traffic arriving on the SOCKS5 inbound is always sent to the `proxy` outbound by the first routing rule.

---

## Sudoers and Permissions

Both TUN and SOCKS5 are launched via `sudo -n` (passwordless). The rule is installed **once** — on first connect, the standard macOS administrator privileges dialog appears.

### The rule (`/etc/sudoers.d/yurec`)

```
# Managed by YurecClient — do not edit
%admin ALL=(root) NOPASSWD: /usr/local/bin/sing-box, /opt/homebrew/bin/sing-box, /bin/kill, /usr/sbin/networksetup
```

The rule is validated via `sudo -n -l <path>` before every start. If the binary path has changed (e.g. after a Homebrew update), the rule is reinstalled automatically.

---

## Launch at Login and Auto-connect

| Setting | Mechanism | Storage |
|---|---|---|
| **Launch at Login** | `SMAppService.mainApp` (ServiceManagement.framework) | system launchd registry |
| **Auto-connect on Launch** | checked in `AppDelegate.applicationDidFinishLaunching` | `UserDefaults: autoConnectOnLaunch` |

---

## External Process Detection

If sing-box was started outside YurecClient (manually in Terminal, by another app), the client will still adopt it.

On launch and after every stop, `ProxyManager` starts `startLaunchDetectionLoop()` — a background thread that scans for a `sing-box` process every 2 seconds using `sysctl(KERN_PROC_ALL)`. When found:

1. Reads the process arguments via `sysctl(KERN_PROCARGS2)` — looks for the `run` flag and config path (`-c <path>`)
2. Identifies the active profile from the config path
3. Calls `adoptProcess(pid:profilePath:)` — sets `isRunning = true` and begins watching

For adopted processes (no `Process` object, no `terminationHandler`), **kqueue** is used (`EVFILT_PROC / NOTE_EXIT`). Falls back to polling every 2 seconds if kqueue is unavailable.

---

## Logs

Log file: `~/Library/Logs/YurecClient/sing-box.log`

sing-box stdout and stderr are redirected to this file via `LogForwarder`. Each session start appends a separator:

```
--- YurecClient: starting SOCKS5 (port 2080) @ 2025-01-15 12:00:00 +0000 ---
```

Open from the menu: **Open Logs**.

### Log size management

In Settings (General → Logs):

- **Current size** — current file size
- **Clear Now** — truncates the file to zero immediately (works while sing-box is running)
- **Limit log file size** + **Max size** — automatic size enforcement in MB. When the limit is exceeded the file is zeroed and writing continues from the beginning — the file never exceeds the limit regardless of session length.

---

## Project Structure

```
YurecClient/
├── AppDelegate.swift
├── Managers/
│   ├── ConnectionMode.swift         — enum .tun / .socks5(port:), requiresRoot
│   ├── ProxyManager.swift           — core: start, stop, process lifecycle
│   ├── ProfileManager.swift         — profile CRUD, FSEvents, active profile, subscriptions
│   ├── SubscriptionParser.swift     — proxy URI parsing → sing-box JSON config
│   ├── ConfigTransformer.swift      — config transformation for SOCKS5
│   ├── AppRoutingEntry.swift        — app model, auto-detection of helper processes
│   ├── AppRoutingStore.swift        — two-tier global/per-profile storage
│   ├── SudoersManager.swift         — install /etc/sudoers.d/yurec
│   └── LaunchAtLoginManager.swift   — SMAppService wrapper
├── Helpers/
│   ├── DNSHelper.swift              — networksetup DNS
│   └── SystemProxyHelper.swift      — networksetup SOCKS5 proxy
└── UI/
    ├── StatusMenuController.swift   — NSStatusItem, menu, icon animations
    ├── StatusBarIconState.swift     — icon state model
    ├── StatusBarIconProvider.swift  — icon rendering from state
    └── Settings/
        ├── SettingsView.swift           — tab container
        ├── SettingsWindowController.swift
        ├── GeneralTabView.swift         — Launch at Login, binary path, App Routing (global)
        ├── ProfilesTabView.swift        — profile list, SOCKS5 port, App Routing (per-profile), subscriptions
        └── AppRoutingListView.swift     — reusable list with +/- toolbar
```
