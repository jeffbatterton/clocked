import Foundation

// clocked-mcp: the MCP server command Claude runs. It relays stdio to Clocked's socket and
// back, line for line, starting Clocked in the background if it isn't running. Everything
// else happens in the app.

signal(SIGPIPE, SIG_IGN)

let socketPath: String = {
    if let path = ProcessInfo.processInfo.environment["CLOCKED_SOCKET"] { return path }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Clocked/mcp.sock").path
}()

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("clocked-mcp: \(message)\n".utf8))
    exit(1)
}

func connectToClocked() -> Int32? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    guard socketPath.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { fail("socket path is too long") }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
        raw.copyBytes(from: socketPath.utf8)
        raw[socketPath.utf8.count] = 0
    }
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    if connected == 0 { return fd }
    close(fd)
    return nil
}

/// Opens the Clocked.app this helper lives in (Contents/Helpers/clocked-mcp), in the background.
func launchClocked() {
    let app = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = app.pathExtension == "app" ? ["-g", app.path] : ["-g", "-b", "com.jeffbatterton.Clocked"]
    try? open.run()
    open.waitUntilExit()
}

func connectOrLaunch() -> Int32 {
    if let fd = connectToClocked() { return fd }
    launchClocked()
    for _ in 0..<60 {
        usleep(250_000)
        if let fd = connectToClocked() { return fd }
    }
    fail("couldn't reach Clocked. Is it installed and allowed to open?")
}

/// Copies everything from one descriptor to another until the first one ends.
func pump(from source: Int32, to destination: Int32) {
    var buffer = [UInt8](repeating: 0, count: 65536)
    while true {
        let count = read(source, &buffer, buffer.count)
        if count <= 0 { return }
        var offset = 0
        while offset < count {
            let sent = buffer.withUnsafeBytes { write(destination, $0.baseAddress! + offset, count - offset) }
            if sent <= 0 { return }
            offset += sent
        }
    }
}

let fd = connectOrLaunch()

// Claude to Clocked. When Claude closes stdin, tell Clocked no more is coming.
Thread.detachNewThread {
    pump(from: STDIN_FILENO, to: fd)
    shutdown(fd, SHUT_WR)
}

// Clocked to Claude, until Clocked closes the connection (or quits).
pump(from: fd, to: STDOUT_FILENO)
exit(0)
