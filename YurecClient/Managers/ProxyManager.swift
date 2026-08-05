import Foundation
import Combine
import Darwin

class ProxyManager: ObservableObject {
    static let shared = ProxyManager()

    @Published var isRunning: Bool = false {
        didSet { print("\(ProductIdentity.logPrefix) isRunning changed: \(oldValue) → \(isRunning)") }
    }
    @Published var currentMode: ConnectionMode?
    @Published private(set) var lastStartFailure: String?

    private var runningPID: Int32?
    private var runningProcess: Process?  // strong ref so process isn't deallocated
    private var binaryPath: String = ""
    private var tempConfigURL: URL?   // temp file written by ConfigTransformer (SOCKS5 or TUN sanitized)
    private var logForwarder: LogForwarder?
    /// True when the current SOCKS5 session uses the TUN+SOCKS hybrid mode
    /// (i.e. at least one app is selected for routing). Used to decide which
    /// network state to restore on stop.
    private var socks5UsesTun: Bool = false

    private init() {
        print("\(ProductIdentity.logPrefix) ProxyManager.init: start")
        binaryPath = resolveBinaryPath()
        print("\(ProductIdentity.logPrefix) ProxyManager.init: binaryPath=\(binaryPath)")
        setupSignalHandlers()
        setupAtExit()
        DispatchQueue.global(qos: .utility).async { self.fetchSingBoxVersion() }
        print("\(ProductIdentity.logPrefix) ProxyManager.init: done")
    }

    // MARK: - Binary Resolution

    private func resolveBinaryPath() -> String {
        if let override = UserDefaults.standard.string(
            forKey: ProductIdentity.binaryPathDefaultsKey
        ), !override.isEmpty {
            return override
        }
        let candidates = [
            "/usr/local/bin/sing-box",
            "/opt/homebrew/bin/sing-box"
        ]
        for path in candidates {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        let task = Process()
        task.launchPath = "/usr/bin/which"
        task.arguments = ["sing-box"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        try? task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let result = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return result.isEmpty ? "/usr/local/bin/sing-box" : result
    }

    func updateBinaryPath(_ path: String) {
        UserDefaults.standard.set(path, forKey: ProductIdentity.binaryPathDefaultsKey)
        binaryPath = path.isEmpty ? resolveBinaryPath() : path
        singBoxVersion = ""
        DispatchQueue.global(qos: .utility).async { self.fetchSingBoxVersion() }
    }

    var currentBinaryPath: String { binaryPath }

    /// Cached sing-box version string, e.g. "1.13.12". Empty if binary not found or not yet queried.
    @Published private(set) var singBoxVersion: String = ""

    /// Runs `sing-box version` once and caches the result in `singBoxVersion`.
    func fetchSingBoxVersion() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: binaryPath)
        task.arguments = ["version"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return }
        task.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        // First line: "sing-box version 1.13.12"
        if let firstLine = out.split(separator: "\n").first,
           let ver = firstLine.split(separator: " ").last {
            DispatchQueue.main.async { self.singBoxVersion = String(ver) }
        }
    }

    /// Path for sing-box stdout/stderr log. User-owned so the shell can create it.
    static var singBoxLogURL: URL = {
        let dir = ProductIdentity.logsDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir.appendingPathComponent("sing-box.log")
    }()

    // MARK: - Process Lifecycle

    @discardableResult
    func start(profilePath: String, mode: ConnectionMode = .tun) -> Bool {
        guard !isRunning else { return false }
        lastStartFailure = nil
        // A system-level TUN/proxy session cannot safely be shared. Never kill or
        // adopt a sing-box process launched by upstream YurecClient or another app.
        let existingPIDs = pgrepSingBox()
        guard existingPIDs.isEmpty else {
            return failStart(
                "Another sing-box session is already running. Disconnect it before connecting "
                    + "\(ProductIdentity.displayName). No external process was stopped."
            )
        }

        // Resolve the actual config path
        let configPath: String
        let profileURL = URL(fileURLWithPath: profilePath)
        let selectorDefaults = RouteSelectorStore.shared.resolvedDefaults(for: profileURL)
        switch mode {
        case .tun:
            // Strip legacy sing-box < 1.13 inbound fields (sniff, sniff_override_destination, …)
            // if present. socks-in inbound is kept so Telegram and other apps configured to use
            // the local SOCKS proxy continue to work in TUN mode.
            if let sanitizedURL = try? ConfigTransformer.makeTunConfig(
                from: profilePath,
                selectorDefaults: selectorDefaults
            ) {
                tempConfigURL = sanitizedURL
                configPath = sanitizedURL.path
            } else {
                configPath = profilePath
            }

        case .socks5(let port):
            // A local listener may belong to another client or unrelated process.
            if !ensurePortFreeForSocks5(port) {
                return failStart("SOCKS5 port \(port) is already in use. Choose another port in Settings.")
            }
            let activeProfile = ProfileManager.shared.profiles.first { $0.path.path == profilePath }
            let routedNames = AppRoutingStore.shared.effectiveProcessNames(for: activeProfile)
            guard let tmpURL = try? ConfigTransformer.makeSocks5Config(
                from: profilePath,
                port: port,
                routedProcessNames: routedNames,
                selectorDefaults: selectorDefaults
            ) else {
                return failStart("The selected profile could not be transformed for SOCKS5 mode.")
            }
            tempConfigURL = tmpURL
            configPath = tmpURL.path
            socks5UsesTun = !routedNames.isEmpty
        }

        // Development compatibility only: use an already installed upstream
        // rule read-only. This downstream never creates or changes that broad
        // shared rule; public releases require the constrained helper.
        if mode.requiresRoot {
            guard SudoersManager.isInstalled(for: binaryPath),
                  SudoersManager.isInstalled(for: "/usr/sbin/networksetup") else {
                return failStart(
                    "The constrained privileged helper is not installed. This development build "
                        + "does not create or modify the legacy YurecClient sudoers rule."
                )
            }
        }

        // Prepare the log file. If the size limit is configured and already exceeded,
        // clear it now so this session starts in a clean file.
        let logURL = ProxyManager.singBoxLogURL
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
        truncateLogIfNeeded(at: logURL)

        // Write a timestamped session separator directly to the file before the
        // forwarder takes over writes. The forwarder will initialise its byte counter
        // from the current file size, so the separator counts toward the limit.
        guard let headerHandle = FileHandle(forWritingAtPath: logURL.path) else {
            return failStart("The application log file could not be opened.")
        }
        headerHandle.seekToEndOfFile()
        headerHandle.write(Data("\n\n--- \(ProductIdentity.displayName): starting \(mode) @ \(Date()) ---\n\n".utf8))
        headerHandle.closeFile()

        // Route sing-box stdout/stderr through Pipes so LogForwarder controls all
        // writes. This lets it enforce the size limit in real time: when bytes written
        // exceed the limit it truncates the file and seeks back to 0, so the file
        // never grows beyond the configured cap regardless of session length.
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        // Build the process directly — no sh wrapper, no pipe dance, no PID parsing.
        // Process.processIdentifier gives us a reliable PID, terminationHandler fires on exit.
        let task = Process()
        if mode.requiresRoot {
            task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            task.arguments = ["-n", binaryPath, "run", "-c", configPath]
        } else {
            task.executableURL = URL(fileURLWithPath: binaryPath)
            task.arguments = ["run", "-c", configPath]
        }
        task.standardOutput = stdoutPipe
        task.standardError = stderrPipe

        guard (try? task.run()) != nil else {
            return failStart("sing-box could not be launched.")
        }

        // Attach the forwarder after a successful launch.
        let forwarder = LogForwarder(logURL: logURL)
        logForwarder = forwarder
        forwarder?.forward(stdoutPipe.fileHandleForReading)
        forwarder?.forward(stderrPipe.fileHandleForReading)

        let pid = task.processIdentifier
        print("\(ProductIdentity.logPrefix) start: launched PID=\(pid) mode=\(mode)")

        runningProcess = task
        runningPID = pid
        currentMode = mode

        // Set isRunning SYNCHRONOUSLY before registering the terminationHandler.
        // If the process dies instantly (e.g. SOCKS5 port TIME_WAIT), the handler
        // is dispatched immediately upon assignment — if isRunning were set async,
        // handleProcessTermination() would see isRunning=false and bail before retry.
        // start() is always called on the main thread, so this is safe.
        isRunning = true

        // terminationHandler is called on an arbitrary thread when the process exits
        task.terminationHandler = { [weak self] proc in
            print("\(ProductIdentity.logPrefix) terminationHandler: PID=\(proc.processIdentifier) status=\(proc.terminationStatus)")
            DispatchQueue.main.async { self?.handleProcessTermination() }
        }

        // Apply mode-specific system networking:
        //   TUN          → override DNS for fake-ip resolution.
        //   SOCKS5+TUN   → same DNS override (TUN is active, apps selected).
        //   SOCKS5 plain → set macOS system proxy; no DNS change needed.
        switch mode {
        case .tun:
            DNSHelper.setDNS("172.19.0.1")
        case .socks5(let port):
            if socks5UsesTun {
                DNSHelper.setDNS("172.19.0.1")
            } else {
                SystemProxyHelper.enableSOCKS5(port: port)
            }
        }
        return true
    }

    func stop() {
        guard isRunning else { return }
        // Stop only the process launched and tracked by this application.
        // Never enumerate and terminate every sing-box process on the host.
        killProcess()
        switch currentMode {
        case .tun:
            DNSHelper.resetDNS()
        case .socks5:
            if socks5UsesTun { DNSHelper.resetDNS() } else { SystemProxyHelper.disableSOCKS5() }
        case nil:
            break
        }
        cleanupMode()
        isRunning = false
    }

    private func cleanupMode() {
        logForwarder?.stop()
        logForwarder = nil
        if let url = tempConfigURL {
            try? FileManager.default.removeItem(at: url)
            tempConfigURL = nil
        }
        currentMode = nil
        runningProcess = nil
        runningPID = nil
        socks5UsesTun = false
    }

    private func killProcess() {
        // Terminate our direct Process reference
        if let proc = runningProcess, proc.isRunning {
            proc.terminate()
        }
        // Also kill by PID in case proc.terminate() didn't reach the root child
        if let pid = runningPID {
            if kill(pid, SIGTERM) != 0 && errno == EPERM {
                sudoKill(pid: pid)
            }
        }
    }

    /// Returns PIDs of all running sing-box processes via pgrep.
    /// More reliable than sysctl from a GUI app context.
    private func pgrepSingBox() -> [Int32] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-x", "sing-box"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        try? task.run()
        task.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Returns true if something is actively listening on 127.0.0.1:port.
    ///
    /// Uses connect() instead of bind() — this is the semantically correct check:
    ///   connect() → 0          : a process accepted our connection → listener exists
    ///   connect() → ECONNREFUSED: nobody is listening → port is free
    ///
    /// bind() is NOT used because it returns EADDRINUSE for TIME_WAIT / CLOSE_WAIT
    /// residue even after the process is dead, causing false positives.
    private func hasListenerOnPort(_ port: Int) -> Bool {
        let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        // RST on close so the server-side (if any) isn't left with a dangling connection
        var lg = linger(l_onoff: 1, l_linger: 0)
        setsockopt(sock, SOL_SOCKET, SO_LINGER, &lg, socklen_t(MemoryLayout<linger>.size))
        defer { Darwin.close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 {
            // Connected — someone is listening
            return true
        }
        let err = errno
        if err == ECONNREFUSED {
            return false   // no listener
        }
        // Any other error (ETIMEDOUT, etc.) — assume no listener to avoid false positives
        print("\(ProductIdentity.logPrefix) hasListenerOnPort(\(port)): unexpected errno=\(err) (\(String(cString: strerror(err))))")
        return false
    }

    /// Checks whether port is safe to hand to SOCKS5 sing-box.
    ///
    /// Decision tree:
    ///   1. No listener detected (connect → ECONNREFUSED) : proceed immediately.
    ///   2. Listener found                                  : diagnose + abort.
    ///
    /// This downstream never terminates the process that owns the port.
    @discardableResult
    private func ensurePortFreeForSocks5(_ port: Int) -> Bool {
        guard hasListenerOnPort(port) else { return true }

        let singBoxPIDs = pgrepSingBox()
        if !singBoxPIDs.isEmpty {
            print("\(ProductIdentity.logPrefix) ensurePortFreeForSocks5: port \(port) is held by sing-box PIDs=\(singBoxPIDs); refusing to stop an external session")
            return false
        }

        // A non-sing-box process is listening. Log and abort.
        let listenInfo = diagnosticForPort(port)
        let detail = listenInfo.isEmpty ? "(root process — lsof requires sudo to identify)" : listenInfo
        print("\(ProductIdentity.logPrefix) ensurePortFreeForSocks5: port \(port) is held by a non-sing-box process: \(detail)")
        print("\(ProductIdentity.logPrefix)   → Change the SOCKS5 port in Settings.")
        return false
    }

    /// Runs lsof to identify which process(es) are listening on the given port.
    /// Returns a human-readable string suitable for log output, or empty string on failure.
    private func diagnosticForPort(_ port: Int) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return "" }
        task.waitUntilExit()
        let out = (String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // lsof header line + process line(s); strip ANSI just in case
        guard !out.isEmpty else { return "" }  // lsof found nothing (may lack root visibility)
        // Return the non-header lines as compact info
        let lines = out.split(separator: "\n").dropFirst()  // skip "COMMAND PID USER..." header
        let info = lines.map { String($0) }.joined(separator: "; ")
        return info.isEmpty ? "" : ": \(info)"
    }

    private func sudoKill(pid: Int32) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        task.arguments = ["-n", "/bin/kill", "-TERM", String(pid)]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        try? task.run()
        task.waitUntilExit()
    }

    private func handleProcessTermination() {
        // If stop() already cleaned up (set isRunning=false), do nothing.
        // This prevents the terminationHandler from clobbering state when
        // stop() is immediately followed by start() for mode-switching.
        guard isRunning else { return }
        switch currentMode {
        case .tun:
            DNSHelper.resetDNS()
        case .socks5:
            if socks5UsesTun { DNSHelper.resetDNS() } else { SystemProxyHelper.disableSOCKS5() }
        case nil:
            break
        }
        cleanupMode()
        isRunning = false
    }

    // MARK: - Process Detection

    /// Reports an existing session without adopting or modifying it.
    /// A second system VPN session must be disconnected explicitly by its owner.
    func detectExistingProcess() {
        guard !isRunning else { return }
        let pids = pgrepSingBox()
        if pids.isEmpty {
            print("\(ProductIdentity.logPrefix) detectExistingProcess: no external session")
        } else {
            print("\(ProductIdentity.logPrefix) detectExistingProcess: external sing-box PIDs=\(pids); not adopting")
        }
    }

    // MARK: - Signal Handlers

    private func setupSignalHandlers() {
        signal(SIGTERM) { _ in ProxyManager.shared.forceCleanup() }
        signal(SIGINT)  { _ in ProxyManager.shared.forceCleanup() }
    }

    private func setupAtExit() {
        atexit { ProxyManager.shared.forceCleanup() }
    }

    func forceCleanup() {
        logForwarder?.stop()
        logForwarder = nil
        if let proc = runningProcess, proc.isRunning { proc.terminate() }
        if let pid = runningPID {
            if kill(pid, SIGTERM) != 0 && errno == EPERM {
                sudoKill(pid: pid)
            }
        }
        switch currentMode {
        case .tun:
            DNSHelper.resetDNS()
        case .socks5:
            if socks5UsesTun { DNSHelper.resetDNS() } else { SystemProxyHelper.disableSOCKS5() }
        case nil:
            break
        }
        if let url = tempConfigURL { try? FileManager.default.removeItem(at: url) }
        runningPID = nil
        runningProcess = nil
    }

    // MARK: - Log management

    /// Truncates the log file to zero bytes if a size limit is configured and exceeded.
    /// Called at the start of every session so the new session always has room.
    private func truncateLogIfNeeded(at url: URL) {
        guard UserDefaults.standard.bool(forKey: "logSizeLimitEnabled") else { return }
        let limitMB = UserDefaults.standard.integer(forKey: "logSizeLimitMB")
        guard limitMB > 0 else { return }
        let limitBytes = limitMB * 1024 * 1024
        guard
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
            let fileSize = attrs[.size] as? Int,
            fileSize > limitBytes
        else { return }
        try? FileManager.default.removeItem(at: url)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        print("\(ProductIdentity.logPrefix) log truncated: was \(fileSize / 1024) KB, limit \(limitMB) MB")
    }

    /// Clears the log file immediately (called from Settings).
    ///
    /// If sing-box is running, delegates to LogForwarder.rotate() which truncates
    /// the file and resets the write position to 0 — all subsequent output from
    /// sing-box is written from the start of the file with no gap or data loss.
    /// If sing-box is not running, deletes and recreates the file.
    func clearLog() {
        if let forwarder = logForwarder {
            forwarder.rotate()
        } else {
            let url = ProxyManager.singBoxLogURL
            try? FileManager.default.removeItem(at: url)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        print("\(ProductIdentity.logPrefix) log cleared manually")
    }

    // MARK: - Helpers

    @discardableResult
    private func failStart(_ message: String) -> Bool {
        lastStartFailure = message
        print("\(ProductIdentity.logPrefix) start blocked: \(message)")
        return false
    }

}

// MARK: - LogForwarder

/// Reads from sing-box's stdout/stderr pipes on a background queue and writes
/// to the log file, enforcing the configured size limit in real time.
///
/// When accumulated bytes exceed the limit, the file is truncated to zero and
/// the write position resets to the beginning — subsequent output overwrites
/// old content so the file never grows beyond the cap regardless of how long
/// sing-box runs. rotate() does the same on demand (Clear Now button).
final class LogForwarder {

    private let fileHandle: FileHandle
    private let logURL: URL
    private let queue = DispatchQueue(
        label: "ru.rom-gorodnichev.cambodgia.yurecclient.logforwarder",
        qos: .utility
    )
    private var bytesWritten: Int = 0

    init?(logURL: URL) {
        guard let fh = FileHandle(forWritingAtPath: logURL.path) else { return nil }
        fh.seekToEndOfFile()
        self.fileHandle = fh
        self.logURL = logURL
        // Seed the counter from the current file size so the pre-existing separator
        // line counts toward the limit.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
           let size = attrs[.size] as? Int {
            bytesWritten = size
        }
    }

    /// Attaches a readabilityHandler to `handle` that feeds incoming data to write(_:).
    func forward(_ handle: FileHandle) {
        handle.readabilityHandler = { [weak self] src in
            let data = src.availableData
            guard !data.isEmpty else {
                src.readabilityHandler = nil   // EOF — pipe closed (process exited)
                return
            }
            self?.write(data)
        }
    }

    /// Truncates the file to zero and resets the write position.
    /// Safe to call from any thread; serialised on the forwarder queue.
    func rotate() {
        queue.async { [weak self] in
            guard let self else { return }
            self.fileHandle.truncateFile(atOffset: 0)
            self.fileHandle.seek(toFileOffset: 0)
            self.bytesWritten = 0
            print("\(ProductIdentity.logPrefix) LogForwarder: rotated log file")
        }
    }

    func stop() {
        fileHandle.closeFile()
    }

    // MARK: - Private

    private func write(_ data: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            let limitEnabled = UserDefaults.standard.bool(forKey: "logSizeLimitEnabled")
            let limitMB = UserDefaults.standard.integer(forKey: "logSizeLimitMB")
            if limitEnabled && limitMB > 0 {
                let limitBytes = limitMB * 1024 * 1024
                if self.bytesWritten + data.count > limitBytes {
                    self.fileHandle.truncateFile(atOffset: 0)
                    self.fileHandle.seek(toFileOffset: 0)
                    self.bytesWritten = 0
                    print("\(ProductIdentity.logPrefix) LogForwarder: size limit reached (\(limitMB) MB), rotated")
                }
            }
            self.fileHandle.write(data)
            self.bytesWritten += data.count
        }
    }
}
