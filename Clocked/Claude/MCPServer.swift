import Foundation

/// Answers MCP's JSON-RPC messages, one line in and at most one line out. The transport is
/// the socket the `clocked-mcp` helper relays Claude's stdio to.
@MainActor
final class MCPServer {
    static let instructions = """
        Clocked is the user's Mac time tracker. Time is tracked per company as sessions (a start \
        and an end, with an optional note) and adjustments (time added to or taken off a day \
        without times). Each company has its own timer, and several can run at once. A session \
        counts toward the day it started on. Billed time rounds each day's total per company \
        using the user's own rounding rule; actual time is never rounded. Times are in the user's \
        local time zone. Use add_session when you know when the work happened, add_time when you \
        only know how long, and adjust_day to correct a day's total. Sessions for one company \
        can't overlap. Look companies up by name; you don't need their ids.
        """

    let tools: ClaudeTools

    init(tools: ClaudeTools) {
        self.tools = tools
    }

    /// The reply to one message, or nil for a notification.
    func handle(_ line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        guard let id = message["id"] else { return nil }
        let method = message["method"] as? String ?? ""
        let params = message["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
            return reply(id, [
                // Clocked only uses tools, which every version has, so it speaks the client's version.
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": ["listChanged": true]],
                "serverInfo": ["name": "clocked", "title": "Clocked", "version": version],
                "instructions": Self.instructions,
            ])
        case "ping":
            return reply(id, [:])
        case "tools/list":
            return reply(id, ["tools": tools.definitions])
        case "tools/call":
            guard let name = params["name"] as? String else {
                return error(id, -32602, "Missing tool name")
            }
            let arguments = params["arguments"] as? [String: Any] ?? [:]
            switch tools.call(name, arguments) {
            case .success(let result):
                return reply(id, ["content": [["type": "text", "text": encode(result, pretty: true)]], "isError": false])
            case .failure(let problem):
                return reply(id, ["content": [["type": "text", "text": problem.message]], "isError": true])
            case nil:
                return error(id, -32602, "Unknown tool: \(name)")
            }
        default:
            return error(id, -32601, "Method not found: \(method)")
        }
    }

    /// Tells clients the tools changed, such as when changing time is turned on or off.
    static let toolsChangedMessage = #"{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}"#

    private func reply(_ id: Any, _ result: [String: Any]) -> String {
        encode(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func error(_ id: Any, _ code: Int, _ message: String) -> String {
        encode(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    private func encode(_ object: Any, pretty: Bool = false) -> String {
        var options: JSONSerialization.WritingOptions = [.withoutEscapingSlashes, .sortedKeys]
        if pretty { options.insert(.prettyPrinted) }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: options) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
