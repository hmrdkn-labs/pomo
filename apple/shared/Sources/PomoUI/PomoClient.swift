import Foundation

public enum StreamEvent: Equatable, Sendable {
    /// The HTTP response arrived; the stream is live. Clients should resync state here.
    case opened
    case message(SSEMessage)
}

public enum StatsGroupBy: String, Sendable { case day, label, project }

/// The Daemon API as the view-model needs it. `PomoClient` is the real implementation.
public protocol PomoAPI: Sendable {
    func status() async throws -> Status
    func send(_ command: Command, source: String?) async throws -> CommandResult
    func stats(fromMs: Int64?, toMs: Int64?, tzOffsetMin: Int, groupBy: StatsGroupBy) async throws -> Stats
    func blocks(fromMs: Int64?, toMs: Int64?, limit: Int?) async throws -> [Block]
    func stream() -> AsyncThrowingStream<StreamEvent, Error>
}

public struct PomoClient: PomoAPI {
    public let config: DaemonConfig
    private let session: URLSession

    public init(config: DaemonConfig, session: URLSession? = nil) {
        self.config = config
        if let session {
            self.session = session
        } else {
            let c = URLSessionConfiguration.ephemeral
            c.timeoutIntervalForRequest = 30  // the stream sends a keepalive every 15 s
            c.waitsForConnectivity = false
            self.session = URLSession(configuration: c)
        }
    }

    private func request(_ path: String, query: [URLQueryItem] = [], method: String = "GET") -> URLRequest {
        var comps = URLComponents(url: config.baseURL, resolvingAgainstBaseURL: false)!
        comps.path = path
        if !query.isEmpty { comps.queryItems = query }
        var r = URLRequest(url: comps.url!)
        r.httpMethod = method
        r.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        return r
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    private func perform<T: Decodable>(_ req: URLRequest, as type: T.Type) async throws -> T {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ConnectionError.unreachable(error.localizedDescription)
        }
        try Self.check(response, data: data)
        do {
            return try Self.decoder.decode(T.self, from: data)
        } catch {
            throw ConnectionError.badResponse("Unexpected response from daemon: \(error.localizedDescription)")
        }
    }

    static func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw ConnectionError.badResponse("Not an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            struct Body: Decodable {
                struct E: Decodable { var code: String; var message: String }
                var error: E
            }
            if let b = try? JSONDecoder().decode(Body.self, from: data) {
                throw APIError(status: http.statusCode, code: b.error.code, message: b.error.message)
            }
            let code = http.statusCode == 401 ? "unauthorized" : "http_\(http.statusCode)"
            throw APIError(status: http.statusCode, code: code, message: "Daemon returned HTTP \(http.statusCode)")
        }
    }

    public func status() async throws -> Status {
        try await perform(request("/v1/status", query: [
            URLQueryItem(name: "tz_offset_min", value: String(TimeZone.current.secondsFromGMT() / 60))
        ]), as: Status.self)
    }

    public func send(_ command: Command, source: String? = nil) async throws -> CommandResult {
        var r = request("/v1/commands", method: "POST")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue(UUID().uuidString, forHTTPHeaderField: "Idempotency-Key")
        if let source { r.setValue(source, forHTTPHeaderField: "X-Pomo-Source") }
        r.httpBody = try JSONSerialization.data(withJSONObject: command.body)
        return try await perform(r, as: CommandResult.self)
    }

    public func stats(fromMs: Int64?, toMs: Int64?, tzOffsetMin: Int, groupBy: StatsGroupBy) async throws -> Stats {
        var q = [
            URLQueryItem(name: "tz_offset_min", value: String(tzOffsetMin)),
            URLQueryItem(name: "group_by", value: groupBy.rawValue),
        ]
        if let fromMs { q.append(URLQueryItem(name: "from_ms", value: String(fromMs))) }
        if let toMs { q.append(URLQueryItem(name: "to_ms", value: String(toMs))) }
        return try await perform(request("/v1/stats", query: q), as: Stats.self)
    }

    public func blocks(fromMs: Int64?, toMs: Int64?, limit: Int?) async throws -> [Block] {
        var q: [URLQueryItem] = []
        if let fromMs { q.append(URLQueryItem(name: "from_ms", value: String(fromMs))) }
        if let toMs { q.append(URLQueryItem(name: "to_ms", value: String(toMs))) }
        if let limit { q.append(URLQueryItem(name: "limit", value: String(limit))) }
        return try await perform(request("/v1/blocks", query: q), as: BlocksResponse.self).blocks
    }

    public func stream() -> AsyncThrowingStream<StreamEvent, Error> {
        var r = request("/v1/stream")
        r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let req = r
        let session = self.session
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: req)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw APIError(
                            status: http.statusCode,
                            code: http.statusCode == 401 ? "unauthorized" : "http_\(http.statusCode)",
                            message: "Daemon returned HTTP \(http.statusCode)")
                    }
                    continuation.yield(.opened)
                    var parser = SSEParser()
                    var line: [UInt8] = []
                    for try await byte in bytes {
                        if byte == UInt8(ascii: "\n") {
                            if line.last == UInt8(ascii: "\r") { line.removeLast() }
                            if let msg = parser.feed(line: String(decoding: line, as: UTF8.self)) {
                                continuation.yield(.message(msg))
                            }
                            line.removeAll(keepingCapacity: true)
                        } else {
                            line.append(byte)
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch let e as APIError {
                    continuation.finish(throwing: e)
                } catch {
                    continuation.finish(throwing: ConnectionError.unreachable(error.localizedDescription))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
