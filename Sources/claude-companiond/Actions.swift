import AppKit

enum Actions {
    /// Switches the Claude desktop app to the session.
    static func openSession(_ id: String) {
        var c = URLComponents()
        c.scheme = "claude"
        c.host = "code"
        c.path = "/continue"
        c.queryItems = [URLQueryItem(name: "session", value: id), URLQueryItem(name: "source", value: "companion")]
        guard let url = c.url else { return }
        DispatchQueue.main.async { NSWorkspace.shared.open(url) }
    }

    /// Starts a blank Code session in `folder` (the deep link behind Finder's "New Claude Code Session Here").
    static func newSession(folder: String) {
        var c = URLComponents()
        c.scheme = "claude"
        c.host = "code"
        c.path = "/new"
        c.queryItems = [URLQueryItem(name: "folder", value: folder), URLQueryItem(name: "source", value: "companion")]
        guard let url = c.url else { return }
        DispatchQueue.main.async { NSWorkspace.shared.open(url) }
    }

    /// Brings the session forward and sends `text` from its message box: claude-companion-keys pastes it, presses
    /// Return, and puts the clipboard back.
    static func reply(sessionId: String, text: String) -> Bool {
        openSession(sessionId)
        Thread.sleep(forTimeInterval: 0.8)
        return keys(["op": "reply", "text": text], label: "reply")
    }

    /// Brings the session forward and presses Esc in Claude, which stops the running turn.
    /// Not SIGINT: in the stream-json mode desktop sessions use, SIGINT kills the CLI outright.
    static func interrupt(sessionId: String) -> Bool {
        openSession(sessionId)
        Thread.sleep(forTimeInterval: 0.8)
        return keys(["op": "esc"], label: "interrupt")
    }

    /// Asks claude-companion-keys, the helper that holds the Accessibility grant, to type into Claude.
    /// It runs as its own LaunchAgent so rebuilding the daemon doesn't cost the grant.
    private static func keys(_ request: [String: String], label: String) -> Bool {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/ClaudeCompanion/keys.sock").path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            _ = path.utf8CString.withUnsafeBytes { buf.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(buf.count - 1))) }
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0, let body = try? JSONSerialization.data(withJSONObject: request) else {
            logLine("\(label) failed: claude-companion-keys isn't running")
            return false
        }
        _ = body.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        shutdown(fd, SHUT_WR)
        var answer = Data()
        var buf = [UInt8](repeating: 0, count: 1024)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            answer.append(contentsOf: buf[0..<n])
        }
        let text = String(decoding: answer, as: UTF8.self)
        if text != "ok" { logLine("\(label) failed: \(text.isEmpty ? "no answer from claude-companion-keys" : text)") }
        return text == "ok"
    }
}
