import Foundation
import XCTest

/// A real `pomod` started by the person running the suite (see README, "End-to-end UI tests").
/// The simulator shares the host's loopback and file system, so the runner reads the daemon's port and token
/// from its data directory and speaks the Agent API over HTTP, exactly as `pomo` does.
struct Daemon {
    let port: Int
    let token: String

    /// `POMO_E2E_HOME` (pass it as `TEST_RUNNER_POMO_E2E_HOME` to xcodebuild), default `/tmp/pomo-ios-e2e`.
    static func connect() throws -> Daemon {
        let home = ProcessInfo.processInfo.environment["POMO_E2E_HOME"] ?? "/tmp/pomo-ios-e2e"
        let info = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: home + "/daemon.json")))
        guard let port = (info as? [String: Any])?["port"] as? Int else { throw Failure("no port in \(home)/daemon.json") }
        let token = try String(contentsOfFile: home + "/token", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return Daemon(port: port, token: token)
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    @discardableResult
    func call(_ method: String, _ path: String, body: [String: Any]? = nil, source: String? = nil) throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        req.httpMethod = method
        req.timeoutInterval = 15
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let source { req.setValue(source, forHTTPHeaderField: "X-Pomo-Source") }
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<(Data, Int), Error> = .failure(Failure("no response"))
        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error { result = .failure(error) } else {
                result = .success((data ?? Data(), (response as? HTTPURLResponse)?.statusCode ?? 0))
            }
            done.signal()
        }.resume()
        done.wait()
        let (data, code) = try result.get()
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(code) else { throw Failure("\(method) \(path) -> \(code) \(String(data: data, encoding: .utf8) ?? "")") }
        return json
    }

    // MARK: Agent API

    func status() throws -> [String: Any] { try call("GET", "/v1/status") }

    /// `idle`, `running` or `paused`.
    func timerStatus() throws -> String {
        ((try status())["timer"] as? [String: Any])?["status"] as? String ?? "?"
    }

    func blockLabel() throws -> String? {
        (((try status())["timer"] as? [String: Any])?["block"] as? [String: Any])?["label"] as? String
    }

    /// Same as `pomo start --minutes <minutes> --label <label>`.
    func start(minutes: Double, label: String, kind: String = "focus", source: String? = nil) throws {
        try call("POST", "/v1/commands", body: [
            "type": "start", "kind": kind, "planned_ms": Int(minutes * 60_000), "label": label,
        ], source: source)
    }

    func command(_ type: String) throws { try call("POST", "/v1/commands", body: ["type": type]) }

    func stopIfLive() throws {
        if try timerStatus() != "idle" { try command("stop") }
    }

    func offerTicket() throws -> String {
        guard let t = try call("POST", "/v1/pair/offer")["ticket"] as? String else { throw Failure("no ticket") }
        return t
    }

    /// `[(device_id, name, paired, revoked)]` as the daemon sees its peers.
    func peers() throws -> [[String: Any]] { (try call("GET", "/v1/devices"))["devices"] as? [[String: Any]] ?? [] }
}
