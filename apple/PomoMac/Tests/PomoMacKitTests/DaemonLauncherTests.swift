import Foundation
import Network
import PomoUI
import Testing
@testable import PomoMacKit

/// Answers every request on a loopback port with a canned `/v1/status` body.
final class StatusServer: @unchecked Sendable {
    let listener: NWListener
    let port: Int

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { conn in
            conn.start(queue: .global())
            conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
                let body = #"{"now_ms":1,"timer":{"status":"idle","block":null,"remaining_ms":null,"next_kind":"focus"},"today":{"focus_ms":0,"completed_focus":0}}"#
                let resp = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
                conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })
            }
        }
        listener.start(queue: .global())
        ready.wait()
        port = Int(listener.port!.rawValue)
    }

    deinit { listener.cancel() }
}

private func tempDir() throws -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("pomo-launch-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

private func writeScript(_ url: URL, _ body: String) throws {
    try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

@Suite struct DaemonLauncherTests {
    @Test func attachesWithoutSpawningWhenDaemonIsAlive() async throws {
        let server = try StatusServer()
        let home = try tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        try #"{"port": \#(server.port), "pid": 1}"#.write(to: home.appendingPathComponent("daemon.json"), atomically: true, encoding: .utf8)
        try "tok\n".write(to: home.appendingPathComponent("token"), atomically: true, encoding: .utf8)
        let marker = home.appendingPathComponent("spawned")
        let script = home.appendingPathComponent("pomod")
        try writeScript(script, "touch '\(marker.path)'")
        let launcher = DaemonLauncher(home: home, binaryOverride: script, startupTimeout: .seconds(2))
        let client = try await launcher.connect()
        #expect(client.config.port == server.port)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func spawnsDetachedDaemonWhenDaemonJsonIsStaleAndLogsOutput() async throws {
        let server = try StatusServer()
        let home = try tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        // Stale: a port nobody listens on.
        try #"{"port": 1, "pid": 1}"#.write(to: home.appendingPathComponent("daemon.json"), atomically: true, encoding: .utf8)
        try "tok".write(to: home.appendingPathComponent("token"), atomically: true, encoding: .utf8)
        let script = home.appendingPathComponent("pomod")
        // Fake pomod: records its args and session leadership, prints to stderr, publishes the live port, then lingers.
        try writeScript(script, """
        echo "args: $@" >&2
        echo "home: $POMO_HOME" >&2
        echo '{"port": \(server.port), "pid": '$$'}' > "$POMO_HOME/daemon.json.tmp"
        mv "$POMO_HOME/daemon.json.tmp" "$POMO_HOME/daemon.json"
        sleep 1
        """)
        let launcher = DaemonLauncher(home: home, binaryOverride: script, startupTimeout: .seconds(10))
        let client = try await launcher.connect()
        #expect(client.config.port == server.port)
        let log = try String(contentsOf: launcher.logURL, encoding: .utf8)
        #expect(log.contains("args: --home \(home.path)"))
        #expect(log.contains("home: \(home.path)"))
        let attrs = try FileManager.default.attributesOfItem(atPath: launcher.logURL.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o600)
    }

    @Test func alreadyRunningExitIsSuccessWhenTheOtherDaemonBecomesLive() async throws {
        let server = try StatusServer()
        let home = try tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        // daemon.json is missing at first (so the launcher spawns), then the "other" daemon publishes it.
        try "tok".write(to: home.appendingPathComponent("token"), atomically: true, encoding: .utf8)
        let script = home.appendingPathComponent("pomod")
        // Fake pomod losing the lock race: prints the real message and exits 1 right away.
        try writeScript(script, """
        echo "Error: another pomod is already running on $POMO_HOME ($POMO_HOME/daemon.lock is locked)" >&2
        (sleep 0.6; echo '{"port": \(server.port), "pid": 1}' > "$POMO_HOME/daemon.json") &
        exit 1
        """)
        let launcher = DaemonLauncher(home: home, binaryOverride: script, startupTimeout: .seconds(10), exitGrace: .seconds(3))
        let client = try await launcher.connect()
        #expect(client.config.port == server.port)
        let log = try String(contentsOf: launcher.logURL, encoding: .utf8)
        #expect(log.contains("already running"))
    }

    @Test func daemonThatExitsWithoutAnyLiveDaemonFailsFastWithLogPath() async throws {
        let home = try tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        try "tok".write(to: home.appendingPathComponent("token"), atomically: true, encoding: .utf8)
        let script = home.appendingPathComponent("pomod")
        try writeScript(script, "echo boom >&2; exit 1")
        let launcher = DaemonLauncher(home: home, binaryOverride: script, startupTimeout: .seconds(20), exitGrace: .milliseconds(300))
        let t0 = ContinuousClock.now
        do {
            _ = try await launcher.connect()
            Issue.record("expected error")
        } catch let e as ConnectionError {
            #expect(e.localizedDescription.contains("exit code 1"))
            #expect(e.localizedDescription.contains(launcher.logURL.path))
        }
        #expect(ContinuousClock.now - t0 < .seconds(5))
    }

    @Test func missingBinaryReportsHowToFix() async throws {
        let home = try tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        let launcher = DaemonLauncher(home: home, startupTimeout: .seconds(1))
        let bogus = home.appendingPathComponent("nothing")
        #expect(launcher.locateBinary(bundleURL: bogus, executableURL: bogus, path: "") == nil)
        do {
            // No pomod anywhere on this path: connect must fail with a readable message rather than hang.
            let l = DaemonLauncher(home: home, binaryOverride: bogus.appendingPathComponent("pomod"), startupTimeout: .seconds(1))
            _ = try await l.connect()
            Issue.record("expected error")
        } catch let e as ConnectionError {
            #expect(e.localizedDescription.contains("Could not start pomod"))
        }
    }

    @Test func locateBinaryPrefersBundleHelpers() throws {
        let root = try tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Pomo.app")
        let helpers = app.appendingPathComponent("Contents/Helpers")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        try writeScript(helpers.appendingPathComponent("pomod"), "true")
        let onPath = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: onPath, withIntermediateDirectories: true)
        try writeScript(onPath.appendingPathComponent("pomod"), "true")
        let l = DaemonLauncher(home: root)
        #expect(l.locateBinary(bundleURL: app, executableURL: nil, path: onPath.path)?.path == helpers.appendingPathComponent("pomod").path)
        #expect(l.locateBinary(bundleURL: root.appendingPathComponent("x"), executableURL: nil, path: onPath.path)?.path == onPath.appendingPathComponent("pomod").path)
    }
}
