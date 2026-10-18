import Darwin
import Foundation
import PomoUI

/// Finds or starts `pomod` and returns a client for it.
public struct DaemonLauncher: Sendable {
    public let home: URL
    public let binaryOverride: URL?
    public let startupTimeout: Duration
    /// How long to keep looking for a live daemon after the spawned `pomod` has exited.
    public let exitGrace: Duration

    public init(
        home: URL = DaemonConfig.homeDirectory(), binaryOverride: URL? = nil,
        startupTimeout: Duration = .seconds(15), exitGrace: Duration = .seconds(3)
    ) {
        self.home = home
        self.binaryOverride = binaryOverride
        self.startupTimeout = startupTimeout
        self.exitGrace = exitGrace
    }

    public var logURL: URL { home.appendingPathComponent("pomod.log") }

    /// Looks for `pomod` in the app bundle's Helpers folder, then next to the executable, then `$PATH`.
    public func locateBinary(
        bundleURL: URL = Bundle.main.bundleURL,
        executableURL: URL? = Bundle.main.executableURL,
        path: String = ProcessInfo.processInfo.environment["PATH"] ?? ""
    ) -> URL? {
        if let o = binaryOverride { return o }
        let fm = FileManager.default
        var candidates = [bundleURL.appendingPathComponent("Contents/Helpers/pomod")]
        if let e = executableURL { candidates.append(e.deletingLastPathComponent().appendingPathComponent("pomod")) }
        candidates += path.split(separator: ":").map { URL(fileURLWithPath: String($0)).appendingPathComponent("pomod") }
        return candidates.first { fm.isExecutableFile(atPath: $0.path) }
    }

    /// A client for a live daemon, starting `pomod` first when `daemon.json` is missing or points at a dead port.
    public func connect() async throws -> PomoClient {
        if let client = await liveClient() { return client }
        let child = try launch()
        let deadline = ContinuousClock.now + startupTimeout
        var exitedAt: ContinuousClock.Instant?
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(150))
            if let client = await liveClient() { return client }
            // The child may exit because another pomod holds `daemon.lock` ("already running"). That other
            // daemon may still be writing `daemon.json`, so keep looking for a short grace period, then give up.
            if let status = child.exitStatus {
                let first = exitedAt ?? ContinuousClock.now
                exitedAt = first
                if ContinuousClock.now - first > exitGrace {
                    throw ConnectionError.unreachable(
                        "pomod exited (\(status.description)) and no daemon is reachable. See \(logURL.path).")
                }
            }
        }
        throw ConnectionError.unreachable(
            "pomod did not start within \(startupTimeout.components.seconds) s. See \(logURL.path).")
    }

    func liveClient() async -> PomoClient? {
        guard let cfg = try? DaemonConfig.load(home: home) else { return nil }
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 2
        let client = PomoClient(config: cfg, session: URLSession(configuration: c))
        return (try? await client.status()) != nil ? PomoClient(config: cfg) : nil
    }

    /// Starts `pomod` in its own session so it outlives this app. stdout and stderr go to `pomod.log`.
    func launch() throws -> SpawnedProcess {
        guard let binary = locateBinary() else {
            throw ConnectionError.daemonNotConfigured("pomod is not installed. Reinstall Pomo or put pomod on your PATH.")
        }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, logURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o600)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        // Do not inherit this app's blocked or ignored signals: pomod must see SIGTERM.
        var none = sigset_t(), all = sigset_t()
        sigemptyset(&none)
        sigfillset(&all)
        posix_spawnattr_setsigmask(&attr, &none)
        posix_spawnattr_setsigdefault(&attr, &all)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))

        var env = ProcessInfo.processInfo.environment
        env["POMO_HOME"] = home.path
        // POMOD_ARGS (whitespace separated) lets a developer pass flags such as `--port 0 --sync off`.
        let extra = (env["POMOD_ARGS"] ?? "").split(separator: " ").map(String.init)
        let args = [binary.path, "--home", home.path] + extra
        let cArgs = args.map { strdup($0) } + [nil]
        let cEnv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { cArgs.forEach { free($0) }; cEnv.forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, binary.path, &actions, &attr, cArgs, cEnv)
        guard rc == 0 else {
            throw ConnectionError.unreachable("Could not start pomod: \(String(cString: strerror(rc)))")
        }
        // Reap quietly if it exits while the app is still running; the app never signals it.
        let spawned = pid
        let child = SpawnedProcess()
        DispatchQueue.global(qos: .utility).async {
            var st: Int32 = 0
            waitpid(spawned, &st, 0)
            child.finish(ExitStatus(raw: st))
        }
        return child
    }
}

/// How a spawned process ended, from `waitpid`.
struct ExitStatus: Sendable, CustomStringConvertible {
    let raw: Int32
    var description: String {
        if raw & 0x7f == 0 { return "exit code \((raw >> 8) & 0xff)" }
        return "signal \(raw & 0x7f)"
    }
}

/// Exit state of the process `launch()` spawned; set by the reaper thread.
final class SpawnedProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var status: ExitStatus?
    var exitStatus: ExitStatus? { lock.withLock { status } }
    func finish(_ s: ExitStatus) { lock.withLock { status = s } }
}
