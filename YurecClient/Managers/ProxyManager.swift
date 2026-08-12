import Foundation
import Combine
import Darwin

class ProxyManager: ObservableObject {
    static let shared = ProxyManager()

    @Published var isRunning: Bool = false {
        didSet { print("[YurecClient] isRunning changed: \(oldValue) → \(isRunning)") }
    }
    @Published var currentMode: ConnectionMode?

    private var runningPID: Int32?
    private var runningProcess: Process?  // strong ref so process isn't deallocated
    private var statusTimer: Timer?
    private var binaryPath: String = ""
    private var tempConfigURL: URL?   // temp file written by ConfigTransformer (SOCKS5 or TUN sanitized)
    private var logForwarder: LogForwarder?
    /// True when the current SOCKS5 session uses the TUN+SOCKS hybrid mode
    /// (i.e. at least one app is selected for routing). Used to decide which
    /// network state to restore on stop.
    private var socks5UsesTun: Bool = false

    private init() {
        print("[YurecClient] ProxyManager.init: start")
        binaryPath = resolveBinaryPath()
        print("[YurecClient] ProxyManager.init: binaryPath=\(binaryPath)")
        setupSignalHandlers()
        setupAtExit()
        DispatchQueue.global(qos: .utility).async { self.fetchSingBoxVersion() }
        print("[YurecClient] ProxyManager.init: done")
    }

    // MARK: - Binary Resolution

    private func resolveBinaryPath() -> String {
        if let override = UserDefaults.standard.string(forKey: "yurecBinaryPath"), !override.isEmpty {
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
        UserDefaults.standard.set(path, forKey: "yurecBinaryPath")
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
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/YurecClient")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sing-box.log")
    }()

    // MARK: - Process Lifecycle

    func start(profilePath: String, mode: ConnectionMode = .tun) {
        guard !isRunning else { return }
        stopLaunchDetectionLoop()

        // Kill any orphaned sing-box process that may be running but not tracked by this app
        // (e.g. a previous session's process that left isRunning=false)
        killOrphanedSingBox(forMode: mode)

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
            // Second-pass port check: even if killOrphanedSingBox ran, something may still
            // hold the port (orphan that pgrep missed, or an unrelated process).
            if !ensurePortFreeForSocks5(port) {
                // Port held by a non-sing-box process — already logged, abort cleanly.
                return
            }
            let activeProfile = ProfileManager.shared.profiles.first { $0.path.path == profilePath }
            let routedNames = AppRoutingStore.shared.effectiveProcessNames(for: activeProfile)
            guard let tmpURL = try? ConfigTransformer.makeSocks5Config(
                from: profilePath,
                port: port,
                routedProcessNames: routedNames,
                selectorDefaults: selectorDefaults
            ) else {
                print("[YurecClient] start: failed to transform config for SOCKS5")
                return
            }
            tempConfigURL = tmpURL
            configPath = tmpURL.path
            socks5UsesTun = !routedNames.isEmpty
        }

        // Both modes require root. Also ensure networksetup is covered so the
        // SOCKS5 system proxy helper can run without a password.
        if mode.requiresRoot {
            let needsInstall = !SudoersManager.isInstalled(for: binaryPath)
                || !SudoersManager.isInstalled(for: "/usr/sbin/networksetup")
            if needsInstall {
                guard SudoersManager.install(binaryPath: binaryPath) else {
                    print("[YurecClient] start: sudoers install failed, aborting")
                    return
                }
            }
        }

        // Prepare the log file. If the size limit is configured and already exceeded,
        // clear it now so this session starts in a clean file.
        let logURL = ProxyManager.singBoxLogURL
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        truncateLogIfNeeded(at: logURL)

        // Write a timestamped session separator directly to the file before the
        // forwarder takes over writes. The forwarder will initialise its byte counter
        // from the current file size, so the separator counts toward the limit.
        guard let headerHandle = FileHandle(forWritingAtPath: logURL.path) else {
            print("[YurecClient] start: cannot open log file at \(logURL.path)")
            return
        }
        headerHandle.seekToEndOfFile()
        headerHandle.write(Data("\n\n--- YurecClient: starting \(mode) @ \(Date()) ---\n\n".utf8))
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
            print("[YurecClient] start: failed to launch process")
            return
        }

        // Attach the forwarder after a successful launch.
        let forwarder = LogForwarder(logURL: logURL)
        logForwarder = forwarder
        forwarder?.forward(stdoutPipe.fileHandleForReading)
        forwarder?.forward(stderrPipe.fileHandleForReading)

        let pid = task.processIdentifier
        print("[YurecClient] start: launched PID=\(pid) mode=\(mode)")

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
            print("[YurecClient] terminationHandler: PID=\(proc.processIdentifier) status=\(proc.terminationStatus)")
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
    }

    func stop() {
        guard isRunning else { return }
        stopKqueueWatch()
        // SIGKILL any root sing-box child processes. Both TUN and SOCKS5 now run as
        // root, so we kill them the same way regardless of mode.
        let sbPids = pgrepSingBox()
        if !sbPids.isEmpty {
            print("[YurecClient] stop: SIGKILL sing-box child PIDs=\(sbPids)")
            forceKillPIDs(sbPids, label: "stop")
        }
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
        // Start watching for sing-box to appear again (user may start it externally).
        // If start() is called right after (mode-switch), it cancels this loop immediately.
        startLaunchDetectionLoop()
    }

    /// Stops the current session and waits briefly for the process launched by
    /// this app to exit before a replacement session is started.
    ///
    /// Route/profile changes and subscription refreshes are synchronous UI
    /// actions. A plain `stop()` only sends the termination signal; starting
    /// immediately afterwards can race the old `sudo`/`sing-box` process and
    /// leave the new session unable to acquire the TUN interface. Waiting is
    /// deliberately bounded and tied to our tracked Process reference.
    @discardableResult
    func stopAndWaitForRestart(timeout: TimeInterval = 2.0) -> Bool {
        guard isRunning else { return true }
        let process = runningProcess
        stop()

        guard let process else { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while (process.isRunning || !pgrepSingBox().isEmpty), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        if process.isRunning || !pgrepSingBox().isEmpty {
            print("[YurecClient] restart blocked: previous session did not exit within \(timeout)s")
            return false
        }
        return true
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

    /// Kills any running sing-box processes (orphaned from a previous session) and waits
    /// until they are gone before returning. Uses SIGKILL to avoid leaving TIME_WAIT
    /// entries on the port — critical so the next start() can bind immediately.
    private func killOrphanedSingBox(forMode mode: ConnectionMode? = nil) {
        let pids = pgrepSingBox()
        guard !pids.isEmpty else { return }
        print("[YurecClient] killOrphanedSingBox: found PIDs=\(pids), SIGKILL")
        forceKillPIDs(pids, label: "killOrphanedSingBox")
    }

    /// Sends SIGKILL to each PID (using sudo for root processes), then polls until
    /// all are confirmed dead (max 2 s). SIGKILL causes the kernel to RST open TCP
    /// connections — no TIME_WAIT, so the port is usable immediately after return.
    private func forceKillPIDs(_ pids: [Int32], label: String) {
        for pid in pids {
            if kill(pid, SIGKILL) != 0 && errno == EPERM {
                // Root process — need sudo
                let t = Process()
                t.executableURL = URL(fileURLWithPath: "/bin/sh")
                t.arguments = ["-c", "sudo -n /bin/kill -9 \(pid) 2>/dev/null"]
                t.standardOutput = Pipe(); t.standardError = Pipe()
                try? t.run(); t.waitUntilExit()
            }
        }
        // Poll until all are gone (max 2 s — SIGKILL is near-instant)
        for i in 1...20 {
            Thread.sleep(forTimeInterval: 0.1)
            let alive = pids.filter { kill($0, 0) == 0 || errno == EPERM }
            if alive.isEmpty {
                print("[YurecClient] \(label): all PIDs gone after \(i * 100)ms")
                return
            }
        }
        print("[YurecClient] \(label): some PIDs still alive after 2s (unexpected)")
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
        print("[YurecClient] hasListenerOnPort(\(port)): unexpected errno=\(err) (\(String(cString: strerror(err))))")
        return false
    }

    /// Checks whether port is safe to hand to SOCKS5 sing-box.
    ///
    /// Decision tree:
    ///   1. No listener detected (connect → ECONNREFUSED) : proceed immediately.
    ///   2. Listener found, pgrep finds sing-box           : SIGKILL it, proceed.
    ///   3. Listener found, pgrep finds nothing            :
    ///        a. lsof identifies a non-sing-box process    → warn + abort.
    ///        b. lsof finds nothing (root process?)        → warn + abort (unknown holder).
    ///
    /// Returns false only when a foreign listener is detected and we cannot remove it.
    @discardableResult
    private func ensurePortFreeForSocks5(_ port: Int) -> Bool {
        guard hasListenerOnPort(port) else { return true }

        // Something is listening. Is it sing-box?
        let singBoxPIDs = pgrepSingBox()
        if !singBoxPIDs.isEmpty {
            print("[YurecClient] ensurePortFreeForSocks5: port \(port) held by sing-box PIDs=\(singBoxPIDs), SIGKILL")
            forceKillPIDs(singBoxPIDs, label: "ensurePortFreeForSocks5")
            return true
        }

        // A non-sing-box process is listening. Log and abort.
        let listenInfo = diagnosticForPort(port)
        let detail = listenInfo.isEmpty ? "(root process — lsof requires sudo to identify)" : listenInfo
        print("[YurecClient] ensurePortFreeForSocks5: port \(port) is held by a non-sing-box process: \(detail)")
        print("[YurecClient]   → Change the SOCKS5 port in Settings.")
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
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sudo -n /bin/kill -TERM \(pid) 2>/dev/null"]
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
        startLaunchDetectionLoop()
    }

    /// Adopts a sing-box process found externally (detection loop / app launch).
    /// We don't have a Process reference so we poll via kqueue.
    private func adoptProcess(pid: Int32, profilePath: String?) {
        stopLaunchDetectionLoop()
        runningPID = pid
        isRunning = true
        if let path = profilePath {
            ProfileManager.shared.activateProfileByPath(path)
        }
        // Watch the adopted process with kqueue (we have no Process ref for terminationHandler)
        startKqueueWatchAsync(pid: pid)
    }

    // MARK: - kqueue watch for adopted processes

    private var watchingProcess = false

    private func startKqueueWatchAsync(pid: Int32) {
        watchingProcess = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            if self.startKqueueWatch(pid: pid) {
                print("[YurecClient] watching adopted PID \(pid) via kqueue")
            } else {
                print("[YurecClient] kqueue unavailable for PID \(pid), falling back to polling")
                self.runPollingLoop(pid: pid)
            }
        }
    }

    private func stopKqueueWatch() {
        watchingProcess = false
    }

    /// Blocks a background thread until the process exits (kqueue EVFILT_PROC).
    /// Returns true if we successfully registered; false if no access (use polling instead).
    private func startKqueueWatch(pid: Int32) -> Bool {
        let kq = kqueue()
        guard kq != -1 else { return false }
        defer { close(kq) }

        var change = kevent(
            ident: UInt(pid),
            filter: Int16(EVFILT_PROC),
            flags: UInt16(EV_ADD | EV_ONESHOT),
            fflags: UInt32(NOTE_EXIT),
            data: 0,
            udata: nil
        )
        guard kevent(kq, &change, 1, nil, 0, nil) == 0 else { return false }

        var event = kevent()
        while watchingProcess {
            var timeout = timespec(tv_sec: 1, tv_nsec: 0)
            let n = kevent(kq, nil, 0, &event, 1, &timeout)
            if n > 0 {
                print("[YurecClient] kqueue: adopted PID \(pid) exited")
                if watchingProcess {
                    DispatchQueue.main.async { [weak self] in self?.handleProcessTermination() }
                }
                return true
            }
        }
        return true
    }

    private func runPollingLoop(pid: Int32) {
        while watchingProcess {
            Thread.sleep(forTimeInterval: 2.0)
            guard watchingProcess else { break }
            if kill(pid, 0) != 0 && errno == ESRCH {
                print("[YurecClient] polling: adopted PID \(pid) no longer exists")
                DispatchQueue.main.async { [weak self] in self?.handleProcessTermination() }
                return
            }
        }
    }

    // MARK: - Process Detection

    /// При старте: если sing-box уже запущен — подхватываем, иначе — начинаем следить за запуском.
    func detectExistingProcess() {
        guard !isRunning else { return }
        print("[YurecClient] detectExistingProcess: start")

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }

            if let pid = self.findSingBoxPID() {
                let profilePath = self.readProfilePath(pid: pid)
                print("[YurecClient] detectExistingProcess: found PID=\(pid) profile=\(profilePath ?? "unknown")")
                DispatchQueue.main.async { self.adoptProcess(pid: pid, profilePath: profilePath) }
            } else {
                print("[YurecClient] detectExistingProcess: not running, watching for launch...")
                self.startLaunchDetectionLoop()
            }
        }
    }

    // MARK: - Launch Detection

    private var detectingLaunch = false

    /// Polling-петля: ждём когда sing-box появится в системе (запущен вручную или другим способом).
    /// Работает только когда isRunning = false. Останавливается сразу при обнаружении.
    private func startLaunchDetectionLoop() {
        guard !detectingLaunch else { return }
        detectingLaunch = true
        print("[YurecClient] launch detection: watching for sing-box to start...")

        DispatchQueue.global(qos: .utility).async { [weak self] in
            var checkCount = 0
            while let self, self.detectingLaunch, !self.isRunning {
                Thread.sleep(forTimeInterval: 2.0)
                guard self.detectingLaunch, !self.isRunning else { break }
                checkCount += 1

                if let pid = self.findSingBoxPID(silent: true) {
                    let profilePath = self.readProfilePath(pid: pid)
                    print("[YurecClient] launch detection: sing-box appeared, PID=\(pid) profile=\(profilePath ?? "unknown")")
                    DispatchQueue.main.async { self.adoptProcess(pid: pid, profilePath: profilePath) }
                    return
                }

                // Log only on first check and then every 30 seconds to avoid spam
                if checkCount == 1 || checkCount % 15 == 0 {
                    print("[YurecClient] launch detection: waiting... (\(checkCount * 2)s)")
                }
            }
            print("[YurecClient] launch detection: stopped")
        }
    }

    private func stopLaunchDetectionLoop() {
        detectingLaunch = false
    }

    /// Возвращает PID процесса sing-box через sysctl (без fork/exec).
    /// Сканирует таблицу процессов ядра, ищет p_comm == "sing-box",
    /// затем проверяет аргументы (KERN_PROCARGS2) на наличие "run".
    /// `silent`: suppress the "not found" log line (used in tight polling loops).
    private func findSingBoxPID(silent: Bool = false) -> Int32? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        // Первый вызов — узнаём нужный размер буфера
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else {
            print("[YurecClient] sysctl: size query failed, errno=\(errno)")
            return nil
        }

        let count = size / MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: count)
        // Второй вызов — заполняем буфер (размер мог чуть вырасти)
        var actualSize = size
        guard sysctl(&mib, 4, &procs, &actualSize, nil, 0) == 0 else {
            print("[YurecClient] sysctl: proc list fetch failed, errno=\(errno)")
            return nil
        }

        let actualCount = actualSize / MemoryLayout<kinfo_proc>.stride

        // kp_proc.p_comm — массив CChar, максимум MAXCOMLEN (16) символов
        var candidates: [Int32] = []
        var singLike: [String] = []   // для диагностики — имена близкие к "sing"
        for i in 0 ..< actualCount {
            let name = withUnsafeBytes(of: procs[i].kp_proc.p_comm) { raw -> String in
                let ptr = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
                return String(cString: ptr)
            }
            if name == "sing-box" {
                candidates.append(procs[i].kp_proc.p_pid)
            } else if name.hasPrefix("sing") || name.contains("box") {
                singLike.append("\(name)[\(procs[i].kp_proc.p_pid)]")
            }
        }

        if candidates.isEmpty {
            if !silent {
                let hint = singLike.isEmpty ? "no similar names found" : "similar: \(singLike)"
                print("[YurecClient] sysctl: sing-box not found (\(actualCount) procs scanned, \(hint))")
            }
            return nil
        }
        print("[YurecClient] sysctl: sing-box candidates: \(candidates)")

        // Если несколько PIDs — фильтруем по наличию "run" в аргументах,
        // чтобы не подхватить sing-box version / sing-box help и т.п.
        let running = candidates.filter { hasRunArg(pid: $0) }
        let result = (running.isEmpty ? candidates : running).max()
        print("[YurecClient] sysctl: selected PID \(result as Any)")
        return result
    }

    /// Возвращает путь к конфигу из аргументов процесса через KERN_PROCARGS2.
    private func readProfilePath(pid: Int32) -> String? {
        guard let args = readProcArgs(pid: pid) else { return nil }
        print("[YurecClient] KERN_PROCARGS2 args for PID \(pid): \(args)")
        guard let idx = args.firstIndex(of: "-c"), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }

    /// true если аргументы процесса содержат "run" (sing-box run -c …)
    private func hasRunArg(pid: Int32) -> Bool {
        readProcArgs(pid: pid)?.contains("run") ?? false
    }

    /// Читает argv процесса через sysctl KERN_PROCARGS2.
    /// Формат буфера: Int32 argc | exec_path\0 | padding\0… | arg0\0 | arg1\0 | …
    private func readProcArgs(pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }

        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }

        // Первые 4 байта — argc (Int32 little-endian)
        guard size >= 4 else { return nil }
        let argc = Int(buf[0]) | Int(buf[1]) << 8 | Int(buf[2]) << 16 | Int(buf[3]) << 24

        // Пропускаем exec_path (строка до первого \0) и padding (нули до следующей строки)
        var offset = 4
        while offset < size, buf[offset] != 0 { offset += 1 } // конец exec_path
        while offset < size, buf[offset] == 0 { offset += 1 } // паддинг

        // Читаем argc аргументов
        var args: [String] = []
        for _ in 0 ..< argc {
            guard offset < size else { break }
            var end = offset
            while end < size, buf[end] != 0 { end += 1 }
            if let s = String(bytes: buf[offset ..< end], encoding: .utf8) {
                args.append(s)
            }
            offset = end + 1
        }
        return args
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
        stopLaunchDetectionLoop()
        stopKqueueWatch()
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
        print("[YurecClient] log truncated: was \(fileSize / 1024) KB, limit \(limitMB) MB")
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
        }
        print("[YurecClient] log cleared manually")
    }

    // MARK: - Helpers

    /// Single-quotes a string for safe use in a POSIX shell command.
    private func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
    private let queue = DispatchQueue(label: "com.yurec.logforwarder", qos: .utility)
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
            print("[YurecClient] LogForwarder: rotated log file")
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
                    print("[YurecClient] LogForwarder: size limit reached (\(limitMB) MB), rotated")
                }
            }
            self.fileHandle.write(data)
            self.bytesWritten += data.count
        }
    }
}
