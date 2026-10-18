import Foundation
import Testing
@testable import PomoUI

/// Serves canned responses per port so tests can run in parallel.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Reply {
        var status = 200
        var body = Data()
        var chunks: [Data] = []
        var headers: [String: String] = [:]
        var failWith: URLError.Code?
    }
    typealias Handler = @Sendable (URLRequest) -> Reply

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [Int: Handler] = [:]

    static func register(port: Int, _ h: @escaping Handler) {
        lock.lock(); handlers[port] = h; lock.unlock()
    }

    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: c)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let h = Self.handlers[request.url?.port ?? 0]
        Self.lock.unlock()
        guard let h else { client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return }
        let reply = h(request)
        if let code = reply.failWith {
            client?.urlProtocol(self, didFailWithError: URLError(code)); return
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        if !reply.body.isEmpty { client?.urlProtocol(self, didLoad: reply.body) }
        for c in reply.chunks { client?.urlProtocol(self, didLoad: c) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension URLRequest {
    /// Body of the request; `URLProtocol` receives it as a stream.
    var bodyData: Data? {
        if let httpBody { return httpBody }
        guard let s = httpBodyStream else { return nil }
        s.open(); defer { s.close() }
        var d = Data()
        var buf = [UInt8](repeating: 0, count: 1024)
        while s.hasBytesAvailable {
            let n = s.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            d.append(buf, count: n)
        }
        return d
    }
}

private func json(_ s: String) -> Data { Data(s.utf8) }

private let statusJSON = """
{"now_ms": 1000, "timer": {"status": "running", "remaining_ms": 60000, "next_kind": "short_break",
 "block": {"id": "b1", "kind": "focus", "label": "write", "project": null, "source": "agent:claude",
  "device_id": "d", "started_ms": 900, "planned_ms": 1500000, "elapsed_ms": 100, "phase": "running",
  "outcome": null, "ended_ms": null}},
 "today": {"focus_ms": 3600000, "completed_focus": 2}}
"""

@Suite struct PomoClientTests {
    private func client(port: Int, token: String = "tok", _ h: @escaping StubProtocol.Handler) -> PomoClient {
        StubProtocol.register(port: port, h)
        return PomoClient(config: DaemonConfig(port: port, token: token), session: StubProtocol.session())
    }

    @Test func statusDecodesAndSendsBearerToken() async throws {
        let c = client(port: 50001, token: "secret") { req in
            #expect(req.url?.path == "/v1/status")
            #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer secret")
            return .init(body: json(statusJSON))
        }
        let s = try await c.status()
        #expect(s.nowMs == 1000)
        #expect(s.timer.status == .running)
        #expect(s.timer.remainingMs == 60_000)
        #expect(s.timer.nextKind == .shortBreak)
        #expect(s.timer.block?.source == "agent:claude")
        #expect(s.timer.block?.deviceId == "d")
        #expect(s.today == Today(focusMs: 3_600_000, completedFocus: 2))
    }

    @Test func commandPostsBodyIdempotencyKeyAndSource() async throws {
        let c = client(port: 50002) { req in
            #expect(req.httpMethod == "POST")
            #expect(req.url?.path == "/v1/commands")
            #expect(req.value(forHTTPHeaderField: "Idempotency-Key")?.isEmpty == false)
            #expect(req.value(forHTTPHeaderField: "X-Pomo-Source") == "agent:test")
            let body = try? JSONSerialization.jsonObject(with: req.bodyData ?? Data()) as? [String: Any]
            #expect(body?["type"] as? String == "start")
            #expect(body?["kind"] as? String == "short_break")
            #expect(body?["planned_ms"] as? Int == 300_000)
            #expect(body?["label"] as? String == "tea")
            #expect(body?["project"] == nil)
            return .init(body: json(#"{"event": {}, "timer": {"status": "running", "remaining_ms": 300000, "next_kind": "focus", "block": null}, "replayed": false}"#))
        }
        let r = try await c.send(.start(kind: .shortBreak, plannedMs: 300_000, label: "tea", project: nil), source: "agent:test")
        #expect(r.timer.status == .running)
        #expect(r.replayed == false)
    }

    @Test func commandBodies() {
        #expect(Command.extend(addMs: 300_000).body["add_ms"] as? Int64 == 300_000)
        #expect(Command.pause.body["type"] as? String == "pause")
        #expect(Command.start(kind: .focus, plannedMs: 1, label: "", project: nil).body["label"] == nil)
        let l = Command.label(blockId: "x", label: "y").body
        #expect(l["block_id"] as? String == "x" && l["label"] as? String == "y")
    }

    @Test func apiErrorsCarryDaemonMessage() async {
        let c = client(port: 50003) { _ in
            .init(status: 409, body: json(#"{"error": {"code": "invalid_state", "message": "no block is running"}}"#))
        }
        do {
            _ = try await c.send(.pause)
            Issue.record("expected error")
        } catch let e as APIError {
            #expect(e.status == 409 && e.code == "invalid_state" && e.message == "no block is running")
        } catch { Issue.record("wrong error \(error)") }
    }

    @Test func unauthorizedWithoutBody() async {
        let c = client(port: 50004) { _ in .init(status: 401) }
        do { _ = try await c.status(); Issue.record("expected error") }
        catch let e as APIError { #expect(e.code == "unauthorized") }
        catch { Issue.record("wrong error \(error)") }
    }

    @Test func transportFailureIsUnreachable() async {
        let c = client(port: 50005) { _ in .init(failWith: .cannotConnectToHost) }
        do { _ = try await c.status(); Issue.record("expected error") }
        catch let e as ConnectionError { if case .unreachable = e {} else { Issue.record("wrong case") } }
        catch { Issue.record("wrong error \(error)") }
    }

    @Test func statsAndBlocksQueries() async throws {
        let c = client(port: 50006) { req in
            let q = URLComponents(url: req.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
            func v(_ n: String) -> String? { q.first { $0.name == n }?.value }
            if req.url?.path == "/v1/stats" {
                #expect(v("group_by") == "label" && v("from_ms") == "10" && v("to_ms") == "20" && v("tz_offset_min") == "120")
                return .init(body: json(#"{"from_ms":10,"to_ms":20,"tz_offset_min":120,"focus_ms":5,"completed_focus":1,"streak_days":3,"groups":[{"key":"a","focus_ms":5,"completed_focus":1}]}"#))
            }
            #expect(v("limit") == "1")
            return .init(body: json(#"{"blocks": [{"id":"b","kind":"long_break","label":null,"project":null,"source":"user","device_id":"d","started_ms":1,"planned_ms":2,"elapsed_ms":2,"phase":"ended","outcome":"completed","ended_ms":3}]}"#))
        }
        let s = try await c.stats(fromMs: 10, toMs: 20, tzOffsetMin: 120, groupBy: .label)
        #expect(s.streakDays == 3 && s.groups.first?.key == "a")
        let b = try await c.blocks(fromMs: nil, toMs: nil, limit: 1)
        #expect(b.first?.kind == .longBreak && b.first?.outcome == "completed")
    }

    @Test func streamYieldsOpenedThenMessagesSkippingKeepalives() async throws {
        let sse = ": keepalive\n\nevent: pomo.event\ndata: {\"x\":1}\n\r\nevent: pomo.block_end\r\ndata: {\"block_id\":\"b\"}\r\n\r\n"
        let c = client(port: 50007) { req in
            #expect(req.url?.path == "/v1/stream")
            #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
            return .init(chunks: [json(String(sse.prefix(20))), json(String(sse.dropFirst(20)))], headers: ["Content-Type": "text/event-stream"])
        }
        var got: [StreamEvent] = []
        for try await e in c.stream() { got.append(e) }
        #expect(got == [
            .opened,
            .message(SSEMessage(event: "pomo.event", data: "{\"x\":1}")),
            .message(SSEMessage(event: "pomo.block_end", data: "{\"block_id\":\"b\"}")),
        ])
    }

    @Test func streamRejectedWith401Throws() async {
        let c = client(port: 50008) { _ in .init(status: 401) }
        do {
            for try await _ in c.stream() {}
            Issue.record("expected error")
        } catch let e as APIError { #expect(e.status == 401) }
        catch { Issue.record("wrong error \(error)") }
    }

    @Test func configLoadsPortAndTrimmedToken() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pomo-cfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(throws: ConnectionError.self) { try DaemonConfig.load(home: dir) }
        try #"{"port": 47831, "pid": 4}"#.write(to: dir.appendingPathComponent("daemon.json"), atomically: true, encoding: .utf8)
        #expect(throws: ConnectionError.self) { try DaemonConfig.load(home: dir) }
        try "abc_-123\n".write(to: dir.appendingPathComponent("token"), atomically: true, encoding: .utf8)
        let cfg = try DaemonConfig.load(home: dir)
        #expect(cfg == DaemonConfig(port: 47831, token: "abc_-123"))
        #expect(cfg.baseURL.absoluteString == "http://127.0.0.1:47831")
        #expect(DaemonConfig.homeDirectory(environment: ["POMO_HOME": "/tmp/x"]).path == "/tmp/x")
    }
}
