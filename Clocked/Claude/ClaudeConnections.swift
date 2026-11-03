import AppKit

/// Adding Clocked to Claude Desktop and Claude Code, and telling whether it's there. Both run
/// the `clocked-mcp` helper inside the app, which relays to the app's socket.
enum ClaudeConnections {
    static let serverName = "clocked"
    static let desktopBundleID = "com.anthropic.claudefordesktop"

    /// Clocked.app/Contents/Helpers/clocked-mcp
    static var helperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/clocked-mcp")
    }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    // MARK: Claude Desktop

    static var desktopConfigURL: URL {
        home.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }

    static var desktopAppURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: desktopBundleID)
    }

    static var isDesktopConnected: Bool {
        (readJSON(desktopConfigURL)?["mcpServers"] as? [String: Any])?[serverName] != nil
    }

    /// Adds Clocked to Claude Desktop's config, keeping everything else in it.
    static func connectDesktop() throws {
        // Never replace a config that's there but can't be read.
        if FileManager.default.fileExists(atPath: desktopConfigURL.path), readJSON(desktopConfigURL) == nil {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: desktopConfigURL.path])
        }
        var config = readJSON(desktopConfigURL) ?? [:]
        var servers = config["mcpServers"] as? [String: Any] ?? [:]
        servers[serverName] = ["command": helperURL.path]
        config["mcpServers"] = servers
        try writeJSON(config, to: desktopConfigURL)
    }

    static func disconnectDesktop() throws {
        guard var config = readJSON(desktopConfigURL), var servers = config["mcpServers"] as? [String: Any] else { return }
        servers[serverName] = nil
        config["mcpServers"] = servers
        try writeJSON(config, to: desktopConfigURL)
    }

    // MARK: Claude Code

    /// For Terminal: adds Clocked for every project, not just the folder it's run in.
    static var codeCommand: String {
        let path = helperURL.path
        let quoted = path.contains(" ") ? "'\(path)'" : path
        return "claude mcp add --scope user \(serverName) \(quoted)"
    }

    /// Whether ~/.claude.json has Clocked, for all projects or any one.
    static var isCodeConnected: Bool {
        guard let config = readJSON(home.appendingPathComponent(".claude.json")) else { return false }
        if (config["mcpServers"] as? [String: Any])?[serverName] != nil { return true }
        let projects = config["projects"] as? [String: Any] ?? [:]
        return projects.values.contains { (($0 as? [String: Any])?["mcpServers"] as? [String: Any])?[serverName] != nil }
    }

    // MARK: JSON files

    private static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func writeJSON(_ object: [String: Any], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }
}
