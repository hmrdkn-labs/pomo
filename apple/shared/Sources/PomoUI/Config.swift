import Foundation

/// Where the Daemon lives: port from `daemon.json`, token from `token`, both under `$POMO_HOME`.
public struct DaemonConfig: Equatable, Sendable {
    public var port: Int
    public var token: String

    public init(port: Int, token: String) { self.port = port; self.token = token }

    public var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    public static func homeDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let h = environment["POMO_HOME"], !h.isEmpty { return URL(fileURLWithPath: h, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pomo", isDirectory: true)
    }

    public static func load(home: URL) throws -> DaemonConfig {
        let jsonURL = home.appendingPathComponent("daemon.json")
        let tokenURL = home.appendingPathComponent("token")
        guard let jsonData = try? Data(contentsOf: jsonURL) else {
            throw ConnectionError.daemonNotConfigured("No daemon.json in \(home.path)")
        }
        struct Info: Decodable { var port: Int }
        guard let info = try? JSONDecoder().decode(Info.self, from: jsonData) else {
            throw ConnectionError.daemonNotConfigured("Unreadable daemon.json in \(home.path)")
        }
        guard let tokenRaw = try? String(contentsOf: tokenURL, encoding: .utf8) else {
            throw ConnectionError.daemonNotConfigured("No token file in \(home.path)")
        }
        let token = tokenRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw ConnectionError.daemonNotConfigured("Empty token file") }
        return DaemonConfig(port: info.port, token: token)
    }
}
