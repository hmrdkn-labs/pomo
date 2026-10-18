import Foundation

public struct SSEMessage: Equatable, Sendable {
    public var event: String
    public var data: String

    public init(event: String, data: String) {
        self.event = event; self.data = data
    }
}

/// Incremental parser for `text/event-stream`. Feed one line at a time (without the line terminator).
public struct SSEParser: Sendable {
    private var event = ""
    private var dataLines: [String] = []

    public init() {}

    /// Returns a message when `line` is the blank line that dispatches one.
    public mutating func feed(line: String) -> SSEMessage? {
        if line.isEmpty {
            defer { event = ""; dataLines = [] }
            guard !dataLines.isEmpty else { return nil }
            return SSEMessage(event: event.isEmpty ? "message" : event, data: dataLines.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil }
        let name: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            name = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            name = line[...]
            value = ""
        }
        switch name {
        case "event": event = String(value)
        case "data": dataLines.append(String(value))
        default: break
        }
        return nil
    }
}
