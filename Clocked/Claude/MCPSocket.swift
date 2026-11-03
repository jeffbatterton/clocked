import Foundation

/// Where the app listens and the `clocked-mcp` helper connects: a Unix socket next to the data,
/// readable only by you. The helper works the path out the same way.
enum MCPSocketPath {
    static var url: URL {
        if let path = ProcessInfo.processInfo.environment["CLOCKED_SOCKET"] {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Clocked", isDirectory: true)
            .appendingPathComponent("mcp.sock")
    }
}

/// Accepts the helper's connections and passes each line, a JSON-RPC message, to `handle` on
/// the main actor, writing back whatever it answers. Any number of clients can be connected.
final class MCPSocketServer: @unchecked Sendable {
    private let path: String
    private let handle: @MainActor (String) -> String?
    private let queue = DispatchQueue(label: "Clocked.mcp")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    /// Open connections, touched only on `queue`.
    private var connections: [Int32: Connection] = [:]

    private final class Connection {
        let fd: Int32
        let source: DispatchSourceRead
        var buffer = Data()
        /// Messages handed to the app whose replies haven't been written yet.
        var pending = 0
        /// The client has finished sending; close once the pending replies are written.
        var finished = false
        init(fd: Int32, source: DispatchSourceRead) { self.fd = fd; self.source = source }
    }

    init(url: URL = MCPSocketPath.url, handle: @escaping @MainActor (String) -> String?) {
        path = url.path
        self.handle = handle
    }

    func start() {
        queue.async { self.listen() }
    }

    /// Sends a message, such as a notification, to every connected client.
    func broadcast(_ line: String) {
        queue.async {
            for fd in self.connections.keys { Self.write(line, to: fd) }
        }
    }

    private func listen() {
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return NSLog("Clocked: couldn't make the MCP socket") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { close(fd); return NSLog("Clocked: MCP socket path is too long: \(path)") }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: path.utf8)
            raw[path.utf8.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 8) == 0 else {
            close(fd)
            return NSLog("Clocked: couldn't listen on \(path): \(String(cString: strerror(errno)))")
        }
        chmod(path, 0o600)
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.accept() }
        source.resume()
        acceptSource = source
    }

    private func accept() {
        let fd = Darwin.accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        // Writing to a client that has gone away mustn't kill the app.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let connection = Connection(fd: fd, source: source)
        source.setEventHandler { [weak self] in self?.read(connection) }
        connections[fd] = connection
        source.resume()
    }

    private func read(_ connection: Connection) {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let count = Darwin.read(connection.fd, &chunk, chunk.count)
        guard count > 0 else {
            // Stop reading, but keep the descriptor open for replies still on their way.
            connection.finished = true
            connection.source.cancel()
            closeIfDone(connection)
            return
        }
        connection.buffer.append(contentsOf: chunk[0..<count])
        while let newline = connection.buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: connection.buffer[connection.buffer.startIndex..<newline], as: UTF8.self)
            connection.buffer.removeSubrange(connection.buffer.startIndex...newline)
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            connection.pending += 1
            DispatchQueue.main.async { [self] in
                let reply = MainActor.assumeIsolated { handle(line) }
                queue.async {
                    if let reply { Self.write(reply, to: connection.fd) }
                    connection.pending -= 1
                    self.closeIfDone(connection)
                }
            }
        }
    }

    private func closeIfDone(_ connection: Connection) {
        guard connection.finished, connection.pending == 0, connections[connection.fd] != nil else { return }
        connections[connection.fd] = nil
        close(connection.fd)
    }

    private static func write(_ line: String, to fd: Int32) {
        var data = Data(line.utf8)
        data.append(0x0A)
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let sent = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if sent <= 0 { return }
                offset += sent
            }
        }
    }
}
